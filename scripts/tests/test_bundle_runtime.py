import importlib.util
import pathlib
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]


class RuntimeBundleTests(unittest.TestCase):
    def test_packager_exists(self):
        self.assertTrue((ROOT / 'scripts/bundle-runtime.py').is_file(), 'Production runtime packager is missing')

    def test_internal_links_are_relocated_and_external_links_rejected(self):
        path = ROOT / 'scripts/bundle-runtime.py'
        if not path.exists():
            self.skipTest('packager not implemented')
        spec = importlib.util.spec_from_file_location('bundle_runtime', path)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        scratch = ROOT / 'tmp'
        scratch.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(dir=scratch) as directory:
            root = pathlib.Path(directory)
            source = root / 'source'
            source.mkdir()
            (source / 'real').write_text('runtime')
            (source / 'link').symlink_to(source / 'real')
            module.copy_relocatable(source, root / 'output')
            self.assertEqual((root / 'output/link').read_text(), 'runtime')
            self.assertFalse((root / 'output/link').readlink().is_absolute())
            (source / 'escape').symlink_to('/etc/passwd')
            with self.assertRaises(ValueError):
                module.copy_relocatable(source, root / 'rejected')

    def test_hash_verification_detects_modified_runtime(self):
        path = ROOT / 'scripts/bundle-runtime.py'
        if not path.exists():
            self.skipTest('packager not implemented')
        spec = importlib.util.spec_from_file_location('bundle_runtime', path)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        scratch = ROOT / 'tmp'
        scratch.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(dir=scratch) as directory:
            root = pathlib.Path(directory)
            (root / 'python').write_text('binary')
            module.write_manifest(root, {'source': 'fixture'})
            module.verify_manifest(root)
            (root / 'python').write_text('changed')
            with self.assertRaises(ValueError):
                module.verify_manifest(root)
