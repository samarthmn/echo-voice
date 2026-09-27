#!/usr/bin/env python3
"""Mount checks and bounded filler writes for the isolated low-space recording check.

write-block writes one exclusive block only after the image mount is confirmed.
This module does not create or attach a disk image."""
import argparse
import os
import plistlib
import subprocess
from pathlib import Path

HOST_RESERVE_KB = 40 * 1024 * 1024
HOST_FILL_FLOOR_KB = 20 * 1024 * 1024
IMAGE_FILL_FLOOR_KB = 1_153_434
FILL_BLOCK_BYTES = 256 * 1024 * 1024


def host_allows_image(free_kb: int) -> None:
    if free_kb < HOST_RESERVE_KB:
        raise SystemExit(f'Host volume has {free_kb} KB free. Need at least {HOST_RESERVE_KB} KB before creating the 16 GB image.')


def fill_allowed(image_free_kb: int, host_free_kb: int, block_bytes: int = FILL_BLOCK_BYTES) -> bool:
    block_kb = (block_bytes + 1023) // 1024
    return image_free_kb - block_kb > IMAGE_FILL_FLOOR_KB and host_free_kb - block_kb > HOST_FILL_FLOOR_KB


def completed_chunk(library: Path) -> Path | None:
    matches = [path for path in library.rglob('*.caf') if not path.name.endswith('.partial.caf') and path.is_file() and path.stat().st_size > 0]
    return matches[0] if matches else None


def require_chunk(library: Path) -> Path:
    found = completed_chunk(library)
    if found is None:
        raise SystemExit(f'No completed recording chunk under {library}. Start recording before filling the image.')
    return found


def attached_images() -> list:
    detail = subprocess.run(['hdiutil', 'info', '-plist'], check=False, capture_output=True)
    if detail.returncode != 0:
        raise SystemExit('Could not read attached disk images.')
    return plistlib.loads(detail.stdout).get('images', [])


def same_path(left: Path, right: Path) -> bool:
    return left.resolve(strict=True) == right.resolve(strict=True)


def require_mount(mount: Path, image: Path, images: list | None = None) -> None:
    if mount.is_symlink() or image.is_symlink():
        raise SystemExit('Refusing a symlink for the pressure image or mount.')
    if not mount.is_dir() or not image.is_file():
        raise SystemExit('The pressure image is not mounted at the expected project path.')
    try:
        mount.resolve(strict=True).relative_to(image.resolve(strict=True).parent)
    except ValueError:
        raise SystemExit('Refusing a mount outside this run directory.') from None
    catalog = attached_images() if images is None else images
    image_real = image.resolve(strict=True)
    mount_real = mount.resolve(strict=True)
    for entry in catalog:
        raw_image = entry.get('image-path')
        if not raw_image:
            continue
        candidate = Path(raw_image)
        if candidate.is_symlink() or not candidate.is_file() or not same_path(candidate, image_real):
            continue
        for entity in entry.get('system-entities') or []:
            raw_mount = entity.get('mount-point')
            if not raw_mount:
                continue
            point = Path(raw_mount)
            if point.is_symlink():
                continue
            if point.is_dir() and same_path(point, mount_real):
                return
    raise SystemExit('This directory is not the mount for the new pressure image.')


def process_running(pid: int) -> bool:
    try:
        os.kill(pid, 0)
    except OSError:
        return False
    return True


def write_block(mount: Path, image: Path, fill: Path, counter: Path, host_free_kb: int, image_free_kb: int, app_pid: int, images: list | None = None, block_bytes: int = FILL_BLOCK_BYTES) -> Path:
    require_mount(mount, image, images)
    if not process_running(app_pid):
        raise SystemExit('Echo Voice is no longer running. No filler was written.')
    if not fill_allowed(image_free_kb, host_free_kb, block_bytes):
        raise SystemExit(2)
    if fill.is_symlink():
        raise SystemExit('Refusing a symlink fill directory.')
    try:
        fill.resolve(strict=True).relative_to(mount.resolve(strict=True))
    except ValueError:
        raise SystemExit('Refusing a fill path outside the pressure image.') from None
    current = int(counter.read_text() or '0') if counter.is_file() else 0
    nxt = current + 1
    target = fill.resolve(strict=True) / f'block-{nxt:08d}'
    try:
        descriptor = os.open(target, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o644)
    except OSError as error:
        raise SystemExit(f'Could not create an exclusive filler block: {error}') from error
    try:
        remaining = block_bytes
        chunk = b'\0' * min(1024 * 1024, block_bytes)
        while remaining:
            written = os.write(descriptor, chunk[:remaining])
            if written <= 0:
                raise OSError('short write')
            remaining -= written
    except OSError as error:
        os.close(descriptor)
        target.unlink(missing_ok=True)
        raise SystemExit(f'Filler write failed and was removed: {error}') from error
    os.close(descriptor)
    require_mount(mount, image, images)
    if not target.resolve(strict=True).is_relative_to(mount.resolve(strict=True)):
        target.unlink(missing_ok=True)
        raise SystemExit('The pressure mount changed during the write. The block was removed.')
    counter.write_text(f'{nxt}\n')
    return target


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=('host-reserve', 'chunk', 'mount', 'write-block'))
    parser.add_argument('--free-kb', type=int)
    parser.add_argument('--image-free-kb', type=int)
    parser.add_argument('--host-free-kb', type=int)
    parser.add_argument('--library', type=Path)
    parser.add_argument('--mount', type=Path)
    parser.add_argument('--image', type=Path)
    parser.add_argument('--fill', type=Path)
    parser.add_argument('--counter', type=Path)
    parser.add_argument('--app-pid', type=int)
    args = parser.parse_args()
    if args.command == 'host-reserve':
        host_allows_image(args.free_kb)
    elif args.command == 'chunk':
        print(require_chunk(args.library))
    elif args.command == 'mount':
        require_mount(args.mount, args.image)
    else:
        write_block(args.mount, args.image, args.fill, args.counter, args.host_free_kb, args.image_free_kb, args.app_pid)
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
