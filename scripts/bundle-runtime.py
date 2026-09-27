#!/usr/bin/env python3
"""Build relocatable, application-owned Python runtimes from locked build inputs.

Use a runtime produced by bootstrap-runtime.sh and community_setup at build time.
Never execute this packager on an end user's installation during application setup.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]


def digest(path):
    h = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            h.update(block)
    return h.hexdigest()


def copy_relocatable(source, destination):
    source = Path(source).resolve()
    destination = Path(destination)
    links = []
    for folder, directories, files in os.walk(source, followlinks=False):
        for name in directories + files:
            item = Path(folder) / name
            if item.is_symlink():
                target = item.resolve(strict=True)
                if not target.is_relative_to(source):
                    raise ValueError(f'Runtime symlink escapes its component: {item.relative_to(source)}')
                links.append((item.relative_to(source), target.relative_to(source)))
    shutil.copytree(source, destination, symlinks=True, dirs_exist_ok=True,
                    ignore=shutil.ignore_patterns('__pycache__', '*.pyc', '.DS_Store', '_editable_impl_echo_voice_service*', '_virtualenv*'))
    for relative, target in links:
        copied = destination / relative
        if copied.is_symlink():
            copied.unlink()
            copied.symlink_to(os.path.relpath(destination / target, copied.parent))


def inventory(root):
    result = {}
    for path in sorted(root.rglob('*')):
        if path.name == 'runtime-manifest.json':
            continue
        if path.is_symlink():
            if not path.resolve().is_relative_to(root.resolve()):
                raise ValueError('Packaged runtime contains an external symlink')
            result[path.relative_to(root).as_posix()] = {'link': os.readlink(path)}
        elif path.is_file():
            result[path.relative_to(root).as_posix()] = {'sha256': digest(path)}
    return result


def write_manifest(root, provenance):
    (root / 'runtime-manifest.json').write_text(json.dumps({'schema': 1, 'provenance': provenance, 'files': inventory(root)}, indent=2) + '\n')


def verify_manifest(root):
    manifest = json.loads((root / 'runtime-manifest.json').read_text())
    if manifest['schema'] != 1 or manifest['files'] != inventory(root):
        raise ValueError('Runtime manifest does not match packaged files')


def build(runtime, output):
    if output.exists():
        raise ValueError('Output already exists; choose a fresh staging directory')
    revision = json.loads((ROOT / 'service/models.json').read_text())['voicestudio']['revision']
    if (runtime / 'vendor/VoiceStudio/.echo-revision').read_text().strip() != revision:
        raise ValueError('VoiceStudio revision does not match the lock')
    lock_hash = digest(ROOT / 'service/community/requirements.lock')
    receipt = json.loads((runtime / 'community-venv/.echo-runtime.json').read_text())
    if receipt['lock_sha256'] != lock_hash:
        raise ValueError('Community runtime does not match its dependency lock')
    output.mkdir(parents=True)
    for environment, name in [('venv', 'speech'), ('community-venv', 'community')]:
        executable = (runtime / environment / 'bin/python').resolve(strict=True)
        interpreter = executable.parent.parent
        copy_relocatable(interpreter, output / name)
        packages = runtime / environment / 'lib/python3.11/site-packages'
        copy_relocatable(packages, output / name / 'lib/python3.11/site-packages')
        # Editable service installations are development artifacts. Use bundled code.
        shutil.copytree(ROOT / 'service/echo_service', output / name / 'lib/python3.11/site-packages/echo_service', dirs_exist_ok=True,
                        ignore=shutil.ignore_patterns('__pycache__', '*.pyc'))
        shutil.copy2(ROOT / 'service/models.json', output / name / 'lib/python3.11/site-packages/echo_service/models.json')
        shutil.copytree(ROOT / 'service/community', output / name / 'lib/python3.11/site-packages/community', dirs_exist_ok=True)
        for metadata in (output / name / 'lib/python3.11/site-packages').glob('*.dist-info/direct_url.json'):
            metadata.unlink()  # build-machine locations are not runtime dependencies
        probe = subprocess.check_output([str(output / name / 'bin/python3.11'), '-I', '-B', '-c',
            'import sys, json; print(json.dumps({"version": list(sys.version_info[:3]), "prefix": sys.prefix}))'], text=True)
        info = json.loads(probe)
        if info['version'] != [3, 11, 15] or Path(info['prefix']).resolve() != (output / name).resolve():
            raise ValueError('Interpreter relocation failed')
    copy_relocatable(runtime / 'vendor/VoiceStudio', output / 'vendor/VoiceStudio')
    shutil.copy2(runtime / 'community-venv/.echo-runtime.json', output / 'community/.echo-runtime.json')
    write_manifest(output, {'voiceStudio': revision, 'speechLock': digest(ROOT / 'service/uv.lock'), 'communityLock': lock_hash})
    verify_manifest(output)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--runtime-root', type=Path)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--verify', action='store_true')
    args = parser.parse_args()
    if args.verify:
        verify_manifest(args.output)
    elif args.runtime_root:
        build(args.runtime_root, args.output)
    else:
        parser.error('--runtime-root is required when building')
