"""Resources/models.json pins exactly what the app downloads; keep it consistent with the Modelfile."""
import hashlib
import importlib.util
import json
import pathlib
import re
import tempfile
import unittest
ROOT = pathlib.Path(__file__).resolve().parents[1]
SPEC = json.loads((ROOT / 'Resources/models.json').read_text())
spec = importlib.util.spec_from_file_location('pinner', ROOT / 'scripts/pin-models.py')
pinner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pinner)

PINNED = [t for t in SPEC['tiers'] if t.get('cleanup')]
HIGH = SPEC['tiers'][0]['cleanup']

class ModelSpecTests(unittest.TestCase):
    def test_spec_is_well_formed(self):
        self.assertTrue(SPEC['whisper']['url'].startswith('https://'))
        self.assertRegex(SPEC['whisper']['sha256'], r'^[0-9a-f]{64}$')
        self.assertGreater(SPEC['whisper']['bytes'], 100_000_000)
        self.assertTrue(PINNED)
        for tier in PINNED:
            cleanup = tier['cleanup']
            self.assertTrue(cleanup['url'].startswith('https://huggingface.co/') and cleanup['url'].endswith('.gguf'))
            self.assertRegex(cleanup['sha256'], r'^[0-9a-f]{64}$')
            self.assertGreater(cleanup['bytes'], 100_000_000)
            self.assertEqual(cleanup['wrapper'], 'voxtype-llm-wrapper')

    def test_tiers_are_ordered_largest_first_with_sane_budgets(self):
        self.assertEqual([t['name'] for t in SPEC['tiers']], ['max', 'standard'])
        starts = [t['startsAtGiB'] for t in SPEC['tiers']]
        self.assertEqual(starts, sorted(starts, reverse=True))
        self.assertGreaterEqual(starts[-1], 8)
        self.assertIsNotNone(SPEC['tiers'][0]['cleanup'], 'the highest tier is the shipped setup and must stay pinned')
        for tier in PINNED:
            cleanup = tier['cleanup']
            # A model's floor never exceeds its own tier, and the admission estimate must fit under that floor.
            self.assertLessEqual(cleanup['needsGiB'], tier['startsAtGiB'])
            self.assertLess(cleanup['workingSetGiB'] + cleanup['reserveGiB'], cleanup['needsGiB'])

    def test_tiers_carry_plain_language_labels(self):
        labels = [t['label'] for t in SPEC['tiers']]
        self.assertEqual(labels, ['Max', 'Standard'])
        for tier in SPEC['tiers']:
            self.assertTrue(tier['summary'].endswith('.'), tier['name'])
            self.assertLess(len(tier['summary']), 200, 'keep the setup sheet short')

    def test_each_pinned_tier_has_a_modelfile_on_its_weights(self):
        """The Modelfile's FROM, download URL, and checksum lines all agree with models.json."""
        for tier in PINNED:
            cleanup = tier['cleanup']
            modelfile = ROOT / 'Resources' / cleanup['modelfile']
            self.assertTrue(modelfile.is_file(), f'{cleanup["modelfile"]} missing for the {tier["name"]} tier')
            text = modelfile.read_text()
            self.assertEqual(re.search(r'^FROM\s+(\S+)', text, re.M).group(1), 'models/' + cleanup['url'].rsplit('/', 1)[1])
            self.assertEqual(re.search(r'^# gguf:\s+(\S+)', text, re.M).group(1), cleanup['url'])
            self.assertEqual(re.search(r'^# sha256:\s+(\S+)', text, re.M).group(1), cleanup['sha256'])
            # A raw GGUF import must not leave the model free to think out loud into the transcript.
            self.assertIn('<think>', text)

    def test_modelfiles_are_byte_identical_to_the_wrapper_repository_when_present(self):
        upstream = pathlib.Path.home() / 'Development/voxtype-llm-wrapper'
        if not upstream.is_dir(): self.skipTest('voxtype-llm-wrapper clone not present')
        for tier in PINNED:
            name = tier['cleanup']['modelfile']
            self.assertEqual((ROOT / 'Resources' / name).read_bytes(), (upstream / name).read_bytes(), name)

    def test_requests_switch_thinking_off(self):
        """Ollama applies the GGUF's own chat template (thinking on) rather than the Modelfile's; every request must say think: false."""
        helper = (ROOT / 'Sources/VoxClean/main.swift').read_text()
        self.assertIn('"think": false', helper)
        self.assertIn(f'?? "{HIGH["wrapper"]}"', helper)
        app = (ROOT / 'Sources/Bellow/main.swift').read_text()
        self.assertIn('"think": false', app)

    def fixture(self, root):
        weights = root / 'weights.gguf'; weights.write_bytes(b'fixture model bytes')
        digest = hashlib.sha256(b'fixture model bytes').hexdigest()
        resources = root / 'Resources'; resources.mkdir()
        (resources / HIGH['modelfile']).write_text(f'# Profile: max\n# gguf: {HIGH["url"]}\n# sha256: {digest}\nFROM models/{HIGH["url"].rsplit("/", 1)[1]}\n')
        whisper = root / 'whisper.bin'; whisper.write_bytes(b'whisper weights')
        return weights, whisper, digest, resources

    def test_pin_rehashes_weights_and_whisper(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp); weights, whisper, digest, resources = self.fixture(root)
            pinned = pinner.pin('max', weights, whisper, SPEC, resources)
            self.assertEqual(pinned['tiers'][0]['cleanup']['sha256'], digest)
            self.assertEqual(pinned['tiers'][0]['cleanup']['bytes'], 19)
            self.assertEqual(pinned['tiers'][0]['cleanup']['url'], HIGH['url'])
            self.assertEqual(pinned['tiers'][1], SPEC['tiers'][1], 'other tiers are left alone')
            self.assertEqual(pinned['whisper']['sha256'], hashlib.sha256(b'whisper weights').hexdigest())
            self.assertEqual(pinned['whisper']['bytes'], 15)

    def test_pin_rejects_weights_that_do_not_match_the_modelfile(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp); weights, whisper, _, resources = self.fixture(root); weights.write_bytes(b'corrupted download')
            with self.assertRaisesRegex(ValueError, 'Corrupt weights'): pinner.pin('max', weights, whisper, SPEC, resources)

    def test_pin_refuses_a_tier_without_a_cleanup_entry(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp); weights, whisper, _, resources = self.fixture(root)
            staged = json.loads(json.dumps(SPEC)); staged['tiers'][1]['cleanup'] = None
            with self.assertRaisesRegex(ValueError, 'no cleanup entry'): pinner.pin('standard', weights, whisper, staged, resources)

    def test_pin_verifies_the_real_downloads_when_cached(self):
        """With the build cache populated, pinning reproduces the shipped models.json exactly."""
        cache = ROOT / '.cache'
        for tier in PINNED:
            gguf = cache / 'gguf' / tier['cleanup']['url'].rsplit('/', 1)[1]
            if not gguf.is_file() or not (cache / 'whisper.bin').is_file(): self.skipTest('build cache not populated')
            self.assertEqual(pinner.pin(tier['name'], gguf, cache / 'whisper.bin', SPEC), SPEC)
