import tempfile
import unittest
from pathlib import Path
from importlib.machinery import SourceFileLoader

ROOT = Path(__file__).resolve().parents[2]
installer = SourceFileLoader('install_runtime_notices', str(ROOT / 'scripts/install-runtime-notices.py')).load_module()
auditor = SourceFileLoader('audit_runtime_notices', str(ROOT / 'scripts/audit-runtime-notices.py')).load_module()


class InstallRuntimeNoticesTests(unittest.TestCase):
    def test_matching_version_receives_license_and_wrong_version_does_not(self):
        with tempfile.TemporaryDirectory(dir=ROOT / 'tmp') as temporary:
            app = Path(temporary) / 'Echo Voice.app'
            site = app / 'Contents/Resources/EchoRuntime/speech/lib/python3.11/site-packages'
            matched = site / 'primePy-1.3.dist-info'
            other = site / 'primePy-9.9.dist-info'
            matched.mkdir(parents=True)
            other.mkdir()
            (matched / 'METADATA').write_text('Metadata-Version: 2.1\nName: primePy\nVersion: 1.3\n')
            (other / 'METADATA').write_text('Metadata-Version: 2.1\nName: primePy\nVersion: 9.9\n')
            installed = installer.install(app)
            self.assertEqual(installed, ['speech:primePy==1.3'])
            self.assertIn('MIT', (matched / 'LICENSE').read_text())
            self.assertTrue((matched / 'PROVENANCE.txt').is_file())
            self.assertFalse((other / 'LICENSE').exists())

    def test_known_provenance_blockers_remain_findings_when_a_license_file_exists(self):
        with tempfile.TemporaryDirectory(dir=ROOT / 'tmp') as temporary:
            app = Path(temporary) / 'Echo Voice.app'
            for environment in ('speech', 'community'):
                site = app / 'Contents/Resources/EchoRuntime' / environment / 'lib/python3.11/site-packages'
                folder = site / ('sherpa_onnx_core-1.13.8.dist-info' if environment == 'speech' else 'example-1.0.dist-info')
                folder.mkdir(parents=True)
                if environment == 'speech':
                    (folder / 'METADATA').write_text('Metadata-Version: 2.1\nName: sherpa-onnx-core\nVersion: 1.13.8\n')
                else:
                    (folder / 'METADATA').write_text('Metadata-Version: 2.1\nName: example\nVersion: 1.0\n')
                (folder / 'LICENSE').write_text('MIT\n')
            result = auditor.audit(app)
            self.assertTrue(any(item.get('issue') == 'unresolved redistribution provenance' for item in result['findings']))
