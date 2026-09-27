import plistlib
import tempfile
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path
from importlib.machinery import SourceFileLoader

ROOT = Path(__file__).resolve().parents[2]
archive = SourceFileLoader('appstore_archive', str(ROOT / 'scripts/appstore_archive.py')).load_module()


def fixture_app(root: Path) -> Path:
    app = root / 'Echo Voice.app'
    runtime = app / 'Contents/Resources/EchoRuntime'
    for environment in ('speech', 'community'):
        site = runtime / environment / 'lib/python3.11/site-packages'
        worker = runtime / environment / 'bin'
        site.mkdir(parents=True)
        worker.mkdir()
        (worker / 'python3.11').write_text('#!/bin/sh\n')
        service = site / 'echo_service'
        service.mkdir()
        (service / '__main__.py').write_text('print("fixture")\n')
    packager = SourceFileLoader('runtime_packager', str(ROOT / 'scripts/bundle-runtime.py')).load_module()
    packager.write_manifest(runtime, {'fixture': True})
    notices = app / 'Contents/Resources/Notices'
    notices.mkdir(parents=True)
    (notices / 'EchoVoice-LICENSE.txt').write_text('MIT\n')
    info = {
        'CFBundleIdentifier': archive.BUNDLE_ID,
        'CFBundleShortVersionString': '1.0.0',
        'CFBundleVersion': '1',
        'CFBundleName': 'Echo Voice',
        'EchoDistributionChannel': 'appStore',
    }
    (app / 'Contents').mkdir(exist_ok=True)
    (app / 'Contents/Info.plist').write_bytes(plistlib.dumps(info))
    return app


def store_profile(certificate: bytes, **overrides):
    profile = {
        'TeamIdentifier': ['4PM5BTR8YS'],
        'Platform': ['OSX'],
        'ExpirationDate': datetime.now(timezone.utc).replace(tzinfo=None) + timedelta(days=30),
        'DeveloperCertificates': [certificate],
        'Entitlements': {
            'com.apple.application-identifier': archive.APPLICATION_IDENTIFIER,
            'com.apple.developer.team-identifier': '4PM5BTR8YS',
        },
    }
    profile.update(overrides)
    return profile


class AppStoreArchiveTests(unittest.TestCase):
    def setUp(self):
        self.originals = {
            'signing_identity': archive.signing_identity,
            'signed_entitlements': archive.signed_entitlements,
            'signature_leaf': archive.signature_leaf,
            'decode_profile': archive.decode_profile,
            'run': archive.subprocess.run,
        }
        archive.subprocess.run = lambda *args, **kwargs: type('Result', (), {'returncode': 0})()

    def tearDown(self):
        for name, value in self.originals.items():
            if name == 'run':
                archive.subprocess.run = value
            else:
                setattr(archive, name, value)

    def test_negative_profiles_stay_local_inspection(self):
        certificate = b'cert-a'
        signed = dict(archive.SANDBOX_ENTITLEMENTS)
        signed['com.apple.application-identifier'] = archive.APPLICATION_IDENTIFIER
        signed['com.apple.developer.team-identifier'] = '4PM5BTR8YS'
        now = datetime.now(timezone.utc).replace(tzinfo=None)
        good = store_profile(certificate)
        self.assertEqual(archive.distribution_checks('Apple Distribution: Example (4PM5BTR8YS)', good, signed, certificate, now), 'distribution-checks-passed')
        self.assertEqual(archive.distribution_checks('Developer ID Application: Example (4PM5BTR8YS)', good, signed, certificate, now), 'local-inspection')
        self.assertEqual(archive.distribution_checks('Apple Distribution: Example (4PM5BTR8YS)', store_profile(certificate, ProvisionedDevices=['device']), signed, certificate, now), 'local-inspection')
        self.assertEqual(archive.distribution_checks('Apple Distribution: Example (4PM5BTR8YS)', store_profile(certificate, ProvisionsAllDevices=True), signed, certificate, now), 'local-inspection')
        self.assertEqual(archive.distribution_checks('Apple Distribution: Example (4PM5BTR8YS)', store_profile(certificate, ExpirationDate=now - timedelta(days=1)), signed, certificate, now), 'local-inspection')
        self.assertEqual(archive.distribution_checks('Apple Distribution: Example (4PM5BTR8YS)', store_profile(certificate, Platform=['iOS']), signed, certificate, now), 'local-inspection')
        self.assertEqual(archive.distribution_checks('Apple Distribution: Example (4PM5BTR8YS)', good, signed, b'other', now), 'local-inspection')
        mismatched = dict(signed)
        mismatched['com.apple.application-identifier'] = 'OTHER'
        self.assertEqual(archive.distribution_checks('Apple Distribution: Example (4PM5BTR8YS)', good, mismatched, certificate, now), 'local-inspection')
        self.assertEqual(archive.distribution_checks('-', None, archive.SANDBOX_ENTITLEMENTS, None, now), 'local-inspection')

    def test_assemble_writes_archive_and_preserves_destination_on_failure(self):
        with tempfile.TemporaryDirectory(dir=ROOT / 'tmp') as temporary:
            root = Path(temporary)
            app = fixture_app(root / 'source')
            archive.signing_identity = lambda path: '-'
            archive.signed_entitlements = lambda path: dict(archive.SANDBOX_ENTITLEMENTS)
            archive.signature_leaf = lambda path: b''
            archive.decode_profile = lambda path: (_ for _ in ()).throw(AssertionError('no profile'))
            destination = root / 'dist' / 'Echo Voice.xcarchive'
            stage = root / 'stage'
            readiness = archive.assemble(app, destination, stage, None)
            self.assertEqual(readiness, 'local-inspection')
            info = plistlib.loads((destination / 'Info.plist').read_bytes())
            self.assertEqual(info['ArchiveVersion'], 2)
            self.assertIsInstance(info['CreationDate'], datetime)
            options = plistlib.loads((destination.parent / 'AppStoreExportOptions.plist').read_bytes())
            self.assertEqual(set(options), {'method', 'destination', 'teamID', 'signingStyle', 'uploadSymbols'})
            marker = (destination.parent / 'export-readiness.txt').read_text()
            self.assertIn('distribution_credentials: unverified', marker)
            self.assertIn('export: not-run', marker)
            self.assertIn('redistribution_audit: publication-blocker', marker)
            (destination / 'Info.plist').write_text('previous')
            broken = fixture_app(root / 'broken')
            (broken / 'Contents/Resources/Notices/EchoVoice-LICENSE.txt').unlink()
            with self.assertRaises(ValueError):
                archive.assemble(broken, destination, stage, None)
            self.assertEqual((destination / 'Info.plist').read_text(), 'previous')
            original_move = archive.shutil.move
            def fail_move(*args, **kwargs):
                raise OSError('replacement failed')
            archive.shutil.move = fail_move
            try:
                with self.assertRaises(OSError):
                    archive.assemble(app, destination, stage, None)
            finally:
                archive.shutil.move = original_move
            self.assertEqual((destination / 'Info.plist').read_text(), 'previous')


if __name__ == '__main__':
    unittest.main()
