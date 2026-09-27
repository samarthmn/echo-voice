#!/usr/bin/env python3
"""Assemble an App Store xcarchive for local inspection or a later export.

Distribution credentials are optional. Without a checked Mac App Store profile,
the result is local inspection and credential readiness stays unverified.
Export completion is recorded only by archive-appstore.sh after xcodebuild exits 0.
"""
import argparse
import importlib.util
import plistlib
import shutil
import subprocess
import tempfile
from datetime import datetime, timedelta, timezone
from pathlib import Path

TEAM_ID = '4PM5BTR8YS'
BUNDLE_ID = 'com.samarthmn.EchoVoice'
APPLICATION_IDENTIFIER = f'{TEAM_ID}.{BUNDLE_ID}'
UPLOAD_IDENTITY_PREFIXES = ('Apple Distribution:', '3rd Party Mac Developer Application:')
EXPORT_OPTION_KEYS = ('method', 'destination', 'teamID', 'signingStyle', 'uploadSymbols', 'provisioningProfiles')
SANDBOX_ENTITLEMENTS = {
    'com.apple.security.app-sandbox': True,
    'com.apple.security.device.audio-input': True,
    'com.apple.security.network.client': True,
    'com.apple.security.network.server': True,
    'com.apple.security.files.user-selected.read-write': True,
}


def write_plist(value, path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open('wb') as stream:
        plistlib.dump(value, stream)


def utc_now() -> datetime:
    # Property list dates are UTC and plistlib rejects aware datetimes.
    return datetime.now(timezone.utc).replace(tzinfo=None)


def signing_identity(app: Path) -> str:
    detail = subprocess.run(['codesign', '-dv', '--verbose=4', str(app)], check=False, capture_output=True, text=True)
    output = detail.stderr + detail.stdout
    for line in output.splitlines():
        if line.startswith('Authority='):
            return line.split('=', 1)[1]
    if 'Signature=adhoc' in output:
        return '-'
    raise ValueError('Could not read the app signing identity')


def signed_entitlements(app: Path) -> dict:
    detail = subprocess.run(['codesign', '-d', '--entitlements', ':-', str(app)], check=False, capture_output=True)
    if detail.returncode != 0 or not detail.stdout:
        raise ValueError('Could not read signed entitlements')
    return plistlib.loads(detail.stdout)


def signature_leaf(app: Path) -> bytes:
    stage = Path(__file__).resolve().parents[1] / 'tmp' / 'appstore-cert-extract'
    stage.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=stage, prefix='echo-codesign-') as temporary:
        detail = subprocess.run(['codesign', '-d', '--extract-certificates', str(app.resolve())], check=False, capture_output=True, cwd=temporary)
        leaf = Path(temporary) / 'codesign0'
        if detail.returncode != 0 or not leaf.is_file():
            raise ValueError('Could not read the leaf signature certificate')
        return leaf.read_bytes()


def decode_profile(profile: Path) -> dict:
    detail = subprocess.run(['security', 'cms', '-D', '-i', str(profile)], check=False, capture_output=True)
    if detail.returncode != 0:
        raise ValueError('Provisioning profile could not be decoded')
    return plistlib.loads(detail.stdout)


def sandbox_entitlements_match(signed: dict) -> bool:
    return all(signed.get(key) is value for key, value in SANDBOX_ENTITLEMENTS.items())


def distribution_checks(identity: str, profile: dict | None, signed: dict, leaf: bytes | None, now: datetime) -> str:
    """Return distribution-checks-passed or local-inspection. Never means exported."""
    if profile is None or not sandbox_entitlements_match(signed):
        return 'local-inspection'
    if not any(identity.startswith(prefix) for prefix in UPLOAD_IDENTITY_PREFIXES):
        return 'local-inspection'
    if profile.get('ProvisionedDevices') or profile.get('ProvisionsAllDevices') is True:
        return 'local-inspection'
    platforms = profile.get('Platform') or []
    if isinstance(platforms, str):
        platforms = [platforms]
    if not any(item in ('OSX', 'macOS') for item in platforms):
        return 'local-inspection'
    expires = profile.get('ExpirationDate')
    if not isinstance(expires, datetime) or expires <= now:
        return 'local-inspection'
    if TEAM_ID not in (profile.get('TeamIdentifier') or []):
        return 'local-inspection'
    entitlements = profile.get('Entitlements') or {}
    if entitlements.get('com.apple.application-identifier') != APPLICATION_IDENTIFIER:
        return 'local-inspection'
    if entitlements.get('com.apple.developer.team-identifier') != TEAM_ID:
        return 'local-inspection'
    if entitlements.get('com.apple.security.get-task-allow') is True:
        return 'local-inspection'
    if signed.get('com.apple.application-identifier') != APPLICATION_IDENTIFIER:
        return 'local-inspection'
    if signed.get('com.apple.developer.team-identifier') != TEAM_ID:
        return 'local-inspection'
    embedded = [bytes(item) for item in profile.get('DeveloperCertificates') or []]
    if not leaf or leaf not in embedded:
        return 'local-inspection'
    return 'distribution-checks-passed'


def archive_info(app_info: dict, identity: str, created: datetime) -> dict:
    return {
        'ArchiveVersion': 2,
        'CreationDate': created,
        'Name': app_info.get('CFBundleName', 'Echo Voice'),
        'SchemeName': 'EchoVoice',
        'ApplicationProperties': {
            'ApplicationPath': 'Applications/Echo Voice.app',
            'Architectures': ['arm64'],
            'CFBundleIdentifier': app_info['CFBundleIdentifier'],
            'CFBundleShortVersionString': app_info['CFBundleShortVersionString'],
            'CFBundleVersion': app_info['CFBundleVersion'],
            'SigningIdentity': identity,
            'Team': TEAM_ID,
        },
    }


def export_options(checks_passed: bool, profile_name: str | None) -> dict:
    options = {
        'method': 'app-store-connect',
        'destination': 'export',
        'teamID': TEAM_ID,
        'signingStyle': 'manual',
        'uploadSymbols': False,
    }
    if checks_passed and profile_name:
        options['provisioningProfiles'] = {BUNDLE_ID: profile_name}
    unknown = set(options) - set(EXPORT_OPTION_KEYS)
    if unknown:
        raise ValueError(f'Unsupported export option keys: {sorted(unknown)}')
    return options


def verify_contents(archive: Path) -> None:
    info_path = archive / 'Info.plist'
    app = archive / 'Products/Applications/Echo Voice.app'
    if not info_path.is_file() or not app.is_dir():
        raise ValueError('Archive is missing Info.plist or the application')
    info = plistlib.loads(info_path.read_bytes())
    app_info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    properties = info.get('ApplicationProperties') or {}
    if info.get('ArchiveVersion') != 2 or properties.get('ApplicationPath') != 'Applications/Echo Voice.app':
        raise ValueError('Archive Info.plist is missing Apple archive metadata')
    if not isinstance(info.get('CreationDate'), datetime):
        raise ValueError('Archive creation date is not a property-list date')
    if properties.get('CFBundleIdentifier') != app_info.get('CFBundleIdentifier') or app_info.get('EchoDistributionChannel') != 'appStore':
        raise ValueError('Archive app is not the App Store configuration')
    runtime = app / 'Contents/Resources/EchoRuntime'
    for environment in ('speech', 'community'):
        site = runtime / environment / 'lib/python3.11/site-packages'
        worker = runtime / environment / 'bin/python3.11'
        if not site.is_dir() or not worker.is_file():
            raise ValueError(f'Missing {environment} runtime or worker')
    if not (app / 'Contents/Resources/Notices/EchoVoice-LICENSE.txt').is_file():
        raise ValueError('Missing collected notices')
    if not sandbox_entitlements_match(signed_entitlements(app)):
        raise ValueError('Signed sandbox entitlement values do not match the App Store entitlements')
    for environment in ('speech', 'community'):
        service = runtime / environment / 'lib/python3.11/site-packages/echo_service/__main__.py'
        if not service.is_file():
            raise ValueError(f'Missing {environment} service worker')
    spec = importlib.util.spec_from_file_location('runtime_packager', Path(__file__).resolve().parent / 'bundle-runtime.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    module.verify_manifest(runtime)
    subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True)


def classify(app: Path, now: datetime | None = None) -> str:
    profile_path = app / 'Contents/embedded.provisionprofile'
    profile = decode_profile(profile_path) if profile_path.is_file() else None
    leaf = signature_leaf(app) if profile is not None else None
    return distribution_checks(signing_identity(app), profile, signed_entitlements(app), leaf, now or utc_now())


def assemble(app: Path, destination: Path, stage_root: Path, profile_name: str | None) -> str:
    stage_root.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=stage_root) as temporary:
        archive = Path(temporary) / 'Echo Voice.xcarchive'
        shutil.copytree(app, archive / 'Products/Applications/Echo Voice.app', symlinks=True)
        app_info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
        identity = signing_identity(app)
        write_plist(archive_info(app_info, identity, utc_now()), archive / 'Info.plist')
        verify_contents(archive)
        staged_app = archive / 'Products/Applications/Echo Voice.app'
        readiness = classify(staged_app)
        options = export_options(readiness == 'distribution-checks-passed', profile_name)
        write_plist(options, destination.parent / 'AppStoreExportOptions.plist')
        replaced = destination.parent / '.Echo Voice.xcarchive.previous'
        if destination.exists():
            if replaced.exists():
                shutil.rmtree(replaced)
            destination.rename(replaced)
        try:
            shutil.move(str(archive), destination)
        except Exception:
            if replaced.exists() and not destination.exists():
                replaced.rename(destination)
            raise
        if replaced.exists():
            shutil.rmtree(replaced)
        credential = 'unverified' if readiness == 'local-inspection' else 'distribution-checks-passed'
        (destination.parent / 'export-readiness.txt').write_text(
            f'readiness: {readiness}\ndistribution_credentials: {credential}\nexport: not-run\n'
            'redistribution_audit: publication-blocker\n'
        )
        return readiness


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', type=Path, required=True)
    parser.add_argument('--destination', type=Path, required=True)
    parser.add_argument('--stage-root', type=Path, required=True)
    parser.add_argument('--profile-name')
    args = parser.parse_args()
    readiness = assemble(args.app, args.destination, args.stage_root, args.profile_name)
    print(readiness)
    print(args.destination)
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
