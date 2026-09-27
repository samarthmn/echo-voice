#!/usr/bin/env python3
"""Inventory bundled Python license evidence without making a legal conclusion."""

import argparse
from email.parser import Parser
import json
from pathlib import Path
import sys


# A license file does not clear these. Update the entry only after the artifact itself proves redistribution.
UNRESOLVED_PROVENANCE = {
    ('sherpa-onnx-core', '1.13.8'): 'sherpa-onnx-core 1.13.8 vendors libonnxruntime.dylib. That file is not the onnxruntime 1.24.3 wheel. Tag v1.13.8 cmake pins onnxruntime-osx-arm64 1.28.2, and the installed dylib was not byte-matched to that zip, so the wheel license does not prove the vendored binary.',
}


def audit(app: Path) -> dict:
    resources = app / 'Contents/Resources'
    runtime = resources / 'EchoRuntime'
    own_license = resources / 'Notices/EchoVoice-LICENSE.txt'
    findings = []
    distributions = []
    for environment in ('speech', 'community'):
        site = runtime / environment / 'lib/python3.11/site-packages'
        if not site.is_dir():
            raise ValueError(f'Missing bundled {environment} site-packages')
        metadata_dirs = sorted(site.glob('*.dist-info'))
        if not metadata_dirs:
            raise ValueError(f'No distribution metadata in {environment}')
        for folder in metadata_dirs:
            metadata_path = folder / 'METADATA'
            if not metadata_path.is_file():
                findings.append({'environment': environment, 'distribution': folder.name,
                                 'issue': 'missing METADATA'})
                continue
            metadata = Parser().parsestr(metadata_path.read_text(errors='replace'))
            name = metadata.get('Name', folder.name)
            version = metadata.get('Version', '')
            notices = sorted(path.relative_to(folder).as_posix() for path in folder.rglob('*')
                             if path.is_file() and path.name.lower().startswith(
                                 ('license', 'licence', 'copying', 'notice')))
            top_level = folder / 'top_level.txt'
            if top_level.is_file():
                for module in top_level.read_text(errors='replace').splitlines():
                    module = module.strip()
                    if not module or module in ('.', '..') or '/' in module or '\\' in module:
                        continue
                    package = site / module
                    if not package.is_dir():
                        continue
                    notices.extend(sorted(
                        path.relative_to(site).as_posix() for path in package.rglob('*')
                        if path.is_file() and path.name.lower().startswith(
                            ('license', 'licence', 'copying', 'notice'))))
            notices = sorted(set(notices))
            covered_by_app_license = name.lower().replace('_', '-') == 'echo-voice-service' and own_license.is_file()
            declared = metadata.get('License-Expression') or metadata.get('License')
            if declared and (len(declared) > 200 or '\n' in declared):
                declared = '(license text in METADATA; inspect original file)'
            distributions.append({'environment': environment, 'name': name, 'version': version,
                                  'declaredLicense': declared,
                                  'noticeFiles': notices,
                                  'coveredByAppLicense': covered_by_app_license})
            if not notices and not covered_by_app_license:
                findings.append({'environment': environment, 'distribution': name,
                                 'version': version, 'issue': 'no license/notice file in distribution metadata'})
            blocker = UNRESOLVED_PROVENANCE.get((name, version))
            if blocker:
                findings.append({'environment': environment, 'distribution': name,
                                 'version': version, 'issue': 'unresolved redistribution provenance',
                                 'detail': blocker})
    manifests = sorted(path.relative_to(app).as_posix() for path in app.rglob('PrivacyInfo.xcprivacy'))
    return {'scope': 'Structural inventory only; source licenses, model terms, privacy declarations and legal review remain separate.',
            'distributionCount': len(distributions), 'distributions': distributions,
            'privacyManifests': manifests, 'findings': findings}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', required=True, type=Path)
    parser.add_argument('--strict', action='store_true', help='Fail when distribution metadata lacks notice evidence')
    parser.add_argument('--summary', action='store_true', help='Print only counts, manifests and unresolved findings')
    args = parser.parse_args()
    try:
        result = audit(args.app)
    except (OSError, ValueError) as error:
        print(f'Runtime notice audit could not complete: {error}', file=sys.stderr)
        return 2
    if args.summary:
        result = {key: result[key] for key in ('scope', 'distributionCount', 'privacyManifests', 'findings')}
    print(json.dumps(result, indent=2))
    return 1 if args.strict and result['findings'] else 0


if __name__ == '__main__':
    raise SystemExit(main())
