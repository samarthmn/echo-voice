#!/usr/bin/env python3
"""Copy version-pinned license files into matching installed distributions.

The application MIT license is not used. A notice is installed only when the
distribution name and version in METADATA match the pinned directory.
"""
import argparse
from email.parser import Parser
from pathlib import Path
import shutil
import sys

ROOT = Path(__file__).resolve().parents[1]
NOTICES = ROOT / 'service/runtime-notices'


def install(app: Path) -> list[str]:
    runtime = app / 'Contents/Resources/EchoRuntime'
    if not runtime.is_dir():
        raise ValueError('App has no EchoRuntime bundle')
    installed = []
    for notice_dir in sorted(path for path in NOTICES.glob('*/*') if path.is_dir()):
        name, version = notice_dir.parts[-2:]
        license_file = notice_dir / 'LICENSE'
        provenance = notice_dir / 'PROVENANCE.txt'
        if not license_file.is_file() or not provenance.is_file():
            raise ValueError(f'Missing LICENSE or PROVENANCE.txt for {name} {version}')
        for environment in ('speech', 'community'):
            site = runtime / environment / 'lib/python3.11/site-packages'
            if not site.is_dir():
                continue
            for folder in site.glob('*.dist-info'):
                metadata_path = folder / 'METADATA'
                if not metadata_path.is_file():
                    continue
                metadata = Parser().parsestr(metadata_path.read_text(errors='replace'))
                if metadata.get('Name') != name or metadata.get('Version') != version:
                    continue
                shutil.copyfile(license_file, folder / 'LICENSE')
                shutil.copyfile(provenance, folder / 'PROVENANCE.txt')
                installed.append(f'{environment}:{name}=={version}')
    if not installed:
        raise ValueError('No pinned notices matched an installed distribution')
    return installed


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('app', type=Path)
    args = parser.parse_args()
    try:
        for item in install(args.app):
            print(item)
    except (OSError, ValueError) as error:
        print(f'Runtime notices were not installed: {error}', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
