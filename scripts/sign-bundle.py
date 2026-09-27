#!/usr/bin/env python3
"""Sign bundled native code inside-out; never use --deep to sign."""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]
TEAM_ID = '4PM5BTR8YS'
APPLICATION_IDENTIFIER = '4PM5BTR8YS.com.samarthmn.EchoVoice'
MAGIC = {b'\xfe\xed\xfa\xce', b'\xce\xfa\xed\xfe', b'\xfe\xed\xfa\xcf', b'\xcf\xfa\xed\xfe', b'\xca\xfe\xba\xbe', b'\xbe\xba\xfe\xca', b'\xca\xfe\xba\xbf', b'\xbf\xba\xfe\xca'}


def decode_profile(profile):
    detail = subprocess.run(['security', 'cms', '-D', '-i', str(profile)], check=False, capture_output=True)
    if detail.returncode != 0:
        raise ValueError('Provisioning profile could not be decoded')
    return plistlib.loads(detail.stdout)


def signing_entitlements(static, profile):
    """Copy the reviewed sandbox entitlements and add only the matching profile identifiers."""
    entitlements = profile.get('Entitlements') or {}
    if static.get('com.apple.security.get-task-allow') is True or entitlements.get('com.apple.security.get-task-allow') is True:
        raise ValueError('Distribution signing rejects com.apple.security.get-task-allow')
    if TEAM_ID not in (profile.get('TeamIdentifier') or []):
        raise ValueError('Provisioning profile is not for team 4PM5BTR8YS')
    if entitlements.get('com.apple.application-identifier') != APPLICATION_IDENTIFIER:
        raise ValueError('Provisioning profile application identifier does not match Echo Voice')
    if entitlements.get('com.apple.developer.team-identifier') != TEAM_ID:
        raise ValueError('Provisioning profile team identifier does not match')
    merged = dict(static)
    merged['com.apple.application-identifier'] = APPLICATION_IDENTIFIER
    merged['com.apple.developer.team-identifier'] = TEAM_ID
    return merged

def native(path):
    if path.is_symlink() or not path.is_file(): return False
    with path.open('rb') as stream: return stream.read(4) in MAGIC

def sign(app, identity, provisioning_profile=None):
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    channel = info.get('EchoDistributionChannel', 'development')
    if channel == 'direct' and identity != '-' and not identity.startswith('Developer ID Application:'):
        raise ValueError('Direct distribution requires a Developer ID Application identity')
    executable = app / 'Contents/MacOS' / info['CFBundleExecutable']
    def apply(path, entitlements=None):
        command = ['codesign', '--force', '--sign', identity]
        # Ad-hoc code has no Team ID: hardened Python cannot load its extension modules.
        # Local qualification keeps child interpreters unhardened. Real signed releases
        # harden every component with the same identity; no validation-bypass entitlement.
        if identity != '-' or path == app: command += ['--options', 'runtime']
        if identity != '-': command += ['--timestamp']
        if entitlements: command += ['--entitlements', str(entitlements)]
        subprocess.run(command + [str(path)], check=True)
    for path in sorted(app.rglob('*'), key=lambda p: len(p.parts), reverse=True):
        if path == executable or not native(path): continue
        entitlements = None
        if channel == 'appStore' and path.name.startswith('python') and path.parent.name == 'bin':
            entitlements = ROOT / 'Resources/Worker-AppStore.entitlements'
        apply(path, entitlements)
    for framework in sorted(app.rglob('*.framework'), key=lambda p: len(p.parts), reverse=True):
        if not framework.is_symlink(): apply(framework)
    runtime = app / 'Contents/Resources/EchoRuntime'
    if runtime.exists():
        spec = importlib.util.spec_from_file_location('runtime_packager', ROOT / 'scripts/bundle-runtime.py')
        module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
        provenance = json.loads((runtime / 'runtime-manifest.json').read_text())['provenance']
        # Signing changes executable bytes. Seal the final bytes, then seal the outer bundle.
        module.write_manifest(runtime, provenance)
    entitlements_path = ROOT / 'Resources' / ('EchoVoice-AppStore.entitlements' if channel == 'appStore' else 'EchoVoice.entitlements')
    temporary_entitlements = None
    if provisioning_profile:
        if channel != 'appStore':
            raise ValueError('A Mac App Store profile can only be embedded in an App Store build')
        merged = signing_entitlements(plistlib.loads(entitlements_path.read_bytes()), decode_profile(provisioning_profile))
        shutil.copyfile(provisioning_profile, app / 'Contents/embedded.provisionprofile')
        stage = ROOT / 'tmp' / 'appstore-signing-entitlements'
        stage.mkdir(parents=True, exist_ok=True)
        temporary_entitlements = stage / f'echo-entitlements-{os.getpid()}.plist'
        with temporary_entitlements.open('wb') as stream:
            plistlib.dump(merged, stream)
        entitlements_path = temporary_entitlements
    try:
        apply(app, entitlements_path)
    finally:
        if temporary_entitlements is not None:
            temporary_entitlements.unlink(missing_ok=True)
    subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True)

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('app', type=Path)
    parser.add_argument('--identity', default='-', help='Ad-hoc signing is for local qualification only')
    parser.add_argument('--provisioning-profile', type=Path, help='Mac App Store profile. Required for an upload-ready archive, not for local inspection.')
    args = parser.parse_args()
    sign(args.app, args.identity, args.provisioning_profile)
