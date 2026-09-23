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

class ModelSpecTests(unittest.TestCase):
    def test_spec_is_well_formed(self):
        self.assertTrue(SPEC['whisper']['url'].startswith('https://'))
        self.assertRegex(SPEC['whisper']['sha256'], r'^[0-9a-f]{64}$')
        self.assertGreater(SPEC['whisper']['bytes'], 100_000_000)
        self.assertGreater(SPEC['cleanup']['bytes'], 1_000_000_000)
        self.assertTrue(SPEC['cleanup']['digests'])
        for digest in SPEC['cleanup']['digests']: self.assertRegex(digest, r'^sha256:[0-9a-f]{64}$')
        self.assertEqual(len(set(SPEC['cleanup']['digests'])), len(SPEC['cleanup']['digests']))

    def test_modelfile_builds_on_the_pinned_base_model(self):
        base = re.search(r'^FROM\s+(\S+)', (ROOT / 'Resources/Modelfile').read_text(), re.M).group(1)
        self.assertEqual(base, SPEC['cleanup']['model'])
        self.assertNotEqual(SPEC['cleanup']['wrapper'], SPEC['cleanup']['model'])

    def fixture(self, root):
        (root / 'blobs').mkdir()
        blob = b'fixture model bytes'
        digest = 'sha256:' + hashlib.sha256(blob).hexdigest()
        path = root / 'blobs' / digest.replace(':', '-')
        path.write_bytes(blob)
        name, _, tag = SPEC['cleanup']['model'].partition(':')
        manifest = root / 'manifests/registry.ollama.ai/library' / name / tag
        manifest.parent.mkdir(parents=True)
        manifest.write_text(json.dumps({'config': {'digest': digest, 'size': 19}, 'layers': [{'digest': digest, 'size': 19}]}))
        whisper = root / 'whisper.bin'; whisper.write_bytes(b'whisper weights')
        return path, whisper, digest

    def test_pin_rehashes_blobs_and_whisper(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp); _, whisper, digest = self.fixture(root)
            pinned = pinner.pin(root, whisper, SPEC)
            self.assertEqual(pinned['cleanup']['digests'], [digest, digest])
            self.assertEqual(pinned['cleanup']['bytes'], 38)
            self.assertEqual(pinned['whisper']['sha256'], hashlib.sha256(b'whisper weights').hexdigest())
            self.assertEqual(pinned['whisper']['bytes'], 15)
            self.assertEqual(pinned['whisper']['url'], SPEC['whisper']['url'])

    def test_pin_rejects_corrupt_blob(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp); blob, whisper, _ = self.fixture(root); blob.write_bytes(b'corrupted download')
            with self.assertRaisesRegex(ValueError, 'Corrupt blob'): pinner.pin(root, whisper, SPEC)

    def test_pin_rejects_digest_path_traversal(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp); _, whisper, _ = self.fixture(root)
            name, _, tag = SPEC['cleanup']['model'].partition(':')
            (root / 'manifests/registry.ollama.ai/library' / name / tag).write_text(json.dumps({'config': {'digest': '../../etc/passwd', 'size': 1}, 'layers': []}))
            with self.assertRaises(ValueError): pinner.pin(root, whisper, SPEC)
