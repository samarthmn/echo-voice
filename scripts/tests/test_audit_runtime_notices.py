import tempfile
import unittest
from pathlib import Path
from importlib.machinery import SourceFileLoader

ROOT = Path(__file__).resolve().parents[2]
audit_module = SourceFileLoader('audit_runtime_notices', str(ROOT / 'scripts/audit-runtime-notices.py')).load_module()


def write_environment(app: Path, environment: str, name: str, license_in_package: bool):
    site = app / 'Contents/Resources/EchoRuntime' / environment / 'lib/python3.11/site-packages'
    dist = site / f'{name}-1.0.0.dist-info'
    dist.mkdir(parents=True)
    (dist / 'METADATA').write_text(f'Metadata-Version: 2.1\nName: {name}\nVersion: 1.0.0\nLicense: MIT\n')
    (dist / 'top_level.txt').write_text(f'{name}\n')
    if license_in_package:
        package = site / name
        package.mkdir()
        (package / 'LICENSE').write_text('MIT License\n')
    else:
        (dist / 'LICENSE').write_text('MIT License\n')


class RuntimeNoticeAuditTests(unittest.TestCase):
    def test_package_license_file_counts_as_installed_notice(self):
        with tempfile.TemporaryDirectory(dir=ROOT / 'tmp') as temporary:
            app = Path(temporary) / 'Echo Voice.app'
            write_environment(app, 'speech', 'example_pkg', True)
            write_environment(app, 'community', 'other_pkg', False)
            (app / 'Contents/Resources/Notices').mkdir(parents=True)
            (app / 'Contents/Resources/Notices/EchoVoice-LICENSE.txt').write_text('MIT\n')
            result = audit_module.audit(app)
            self.assertEqual(result['findings'], [])
            speech = next(item for item in result['distributions'] if item['name'] == 'example_pkg')
            self.assertIn('example_pkg/LICENSE', speech['noticeFiles'])

    def test_license_label_without_a_file_stays_a_finding(self):
        with tempfile.TemporaryDirectory(dir=ROOT / 'tmp') as temporary:
            app = Path(temporary) / 'Echo Voice.app'
            site = app / 'Contents/Resources/EchoRuntime/speech/lib/python3.11/site-packages'
            dist = site / 'example_pkg-1.0.0.dist-info'
            dist.mkdir(parents=True)
            (dist / 'METADATA').write_text('Metadata-Version: 2.1\nName: example-pkg\nVersion: 1.0.0\nLicense: MIT\n')
            write_environment(app, 'community', 'other_pkg', False)
            (app / 'Contents/Resources/Notices').mkdir(parents=True)
            (app / 'Contents/Resources/Notices/EchoVoice-LICENSE.txt').write_text('MIT\n')
            result = audit_module.audit(app)
            self.assertEqual([item['distribution'] for item in result['findings']], ['example-pkg'])