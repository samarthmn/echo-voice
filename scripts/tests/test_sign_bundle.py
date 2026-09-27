import plistlib
import unittest
from importlib.machinery import SourceFileLoader
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
signer = SourceFileLoader('sign_bundle', str(ROOT / 'scripts/sign-bundle.py')).load_module()


class SignBundleTests(unittest.TestCase):
    def test_profile_adds_only_matching_identifiers(self):
        static = plistlib.loads((ROOT / 'Resources/EchoVoice-AppStore.entitlements').read_bytes())
        profile = {
            'TeamIdentifier': ['4PM5BTR8YS'],
            'Entitlements': {
                'com.apple.application-identifier': '4PM5BTR8YS.com.samarthmn.EchoVoice',
                'com.apple.developer.team-identifier': '4PM5BTR8YS',
                'com.apple.security.application-groups': ['should-not-copy'],
            },
        }
        merged = signer.signing_entitlements(static, profile)
        self.assertEqual(merged['com.apple.application-identifier'], '4PM5BTR8YS.com.samarthmn.EchoVoice')
        self.assertEqual(merged['com.apple.developer.team-identifier'], '4PM5BTR8YS')
        self.assertTrue(merged['com.apple.security.app-sandbox'])
        self.assertNotIn('com.apple.security.application-groups', merged)
        self.assertNotIn('com.apple.security.get-task-allow', merged)

    def test_invalid_profiles_are_rejected(self):
        static = {'com.apple.security.app-sandbox': True}
        base = {
            'TeamIdentifier': ['4PM5BTR8YS'],
            'Entitlements': {
                'com.apple.application-identifier': '4PM5BTR8YS.com.samarthmn.EchoVoice',
                'com.apple.developer.team-identifier': '4PM5BTR8YS',
            },
        }
        with self.assertRaises(ValueError):
            signer.signing_entitlements(static, {**base, 'Entitlements': {**base['Entitlements'], 'com.apple.security.get-task-allow': True}})
        with self.assertRaises(ValueError):
            signer.signing_entitlements({**static, 'com.apple.security.get-task-allow': True}, base)
        with self.assertRaises(ValueError):
            signer.signing_entitlements(static, {**base, 'TeamIdentifier': ['OTHER']})
        with self.assertRaises(ValueError):
            signer.signing_entitlements(static, {**base, 'Entitlements': {**base['Entitlements'], 'com.apple.application-identifier': 'WRONG'}})
