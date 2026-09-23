import hashlib
import importlib.util
import json
import pathlib
import tempfile
import unittest
ROOT = pathlib.Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('packager', ROOT / 'scripts/package-models.py')
packager = importlib.util.module_from_spec(spec)
spec.loader.exec_module(packager)

class PackageTests(unittest.TestCase):
    def fixture(self, root):
        (root / 'blobs').mkdir()
        blob = b'fixture model bytes'
        digest = 'sha256:' + hashlib.sha256(blob).hexdigest()
        path = root / 'blobs' / digest.replace(':', '-')
        path.write_bytes(blob)
        for name, tag in [('qwen2.5', '7b'), ('voxtype-llm-wrapper', 'latest')]:
            manifest = root / 'manifests/registry.ollama.ai/library' / name / tag
            manifest.parent.mkdir(parents=True)
            manifest.write_text(json.dumps({'config': {'digest': digest}, 'layers': [{'digest': digest}]}))
        (root / 'blobs/unused').write_bytes(b'do not ship')
        return path

    def test_exports_referenced_blobs_only_and_deduplicates(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp); source = root / 'source'; source.mkdir()
            self.fixture(source)
            packager.package(source, root / 'target')
            self.assertEqual(len(list((root / 'target/blobs').iterdir())), 1)
            self.assertEqual(len(json.loads((root / 'target/inventory.json').read_text())), 3)

    def test_rejects_corrupt_model(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp); source = root / 'source'; source.mkdir()
            blob = self.fixture(source); blob.write_bytes(b'corrupted download')
            with self.assertRaisesRegex(ValueError, 'Corrupt blob'): packager.package(source, root / 'target')

    def test_rejects_digest_path_traversal(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp); source = root / 'source'; source.mkdir()
            self.fixture(source)
            manifest = source / 'manifests/registry.ollama.ai/library/qwen2.5/7b'
            manifest.write_text(json.dumps({'config': {'digest': '../../etc/passwd'}, 'layers': []}))
            with self.assertRaises(ValueError): packager.package(source, root / 'target')
