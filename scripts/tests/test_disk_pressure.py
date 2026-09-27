import os
import tempfile
import unittest
from pathlib import Path
from importlib.machinery import SourceFileLoader

ROOT = Path(__file__).resolve().parents[2]
pressure = SourceFileLoader('disk_pressure', str(ROOT / 'scripts/disk_pressure.py')).load_module()


def images_for(image: Path, mount: Path) -> list:
    return [{'image-path': str(image), 'system-entities': [{'mount-point': str(mount)}]}]


class DiskPressureTests(unittest.TestCase):
    def test_preconditions_and_mount_identity(self):
        with self.assertRaises(SystemExit):
            pressure.host_allows_image(pressure.HOST_RESERVE_KB - 1)
        pressure.host_allows_image(pressure.HOST_RESERVE_KB)
        self.assertFalse(pressure.fill_allowed(pressure.IMAGE_FILL_FLOOR_KB, pressure.HOST_FILL_FLOOR_KB))
        with tempfile.TemporaryDirectory(dir=ROOT / 'tmp') as temporary:
            root = Path(temporary)
            library = root / 'EchoVoice'
            library.mkdir()
            with self.assertRaises(SystemExit):
                pressure.require_chunk(library)
            chunk = library / 'audio' / 'microphone-1.caf'
            chunk.parent.mkdir()
            chunk.write_bytes(b'caf')
            self.assertEqual(pressure.require_chunk(library), chunk)
            image = root / 'pressure.dmg'
            image.write_bytes(b'dmg')
            other = root / 'other.dmg'
            other.write_bytes(b'other')
            mount = root / 'mnt'
            mount.mkdir()
            with self.assertRaises(SystemExit):
                pressure.require_mount(mount, image, [])
            with self.assertRaises(SystemExit):
                pressure.require_mount(mount, image, images_for(other, mount))
            pressure.require_mount(mount, image, images_for(image, mount))
            escaped = root / 'escape'
            outside = Path(tempfile.mkdtemp(dir=ROOT / 'tmp'))
            try:
                escaped.symlink_to(outside)
                with self.assertRaises(SystemExit):
                    pressure.require_mount(escaped, image, images_for(image, escaped))
            finally:
                escaped.unlink(missing_ok=True)
                os.rmdir(outside)
            fill = mount / 'pressure-fill'
            fill.mkdir()
            counter = root / 'block-counter'
            huge_free = pressure.HOST_FILL_FLOOR_KB + pressure.FILL_BLOCK_BYTES
            written = pressure.write_block(mount, image, fill, counter, huge_free, huge_free, os.getpid(), images_for(image, mount), block_bytes=8)
            self.assertEqual(written.name, 'block-00000001')
            self.assertEqual(written.stat().st_size, 8)
            with self.assertRaises(SystemExit):
                pressure.write_block(mount, image, fill, counter, huge_free, huge_free, os.getpid(), [], block_bytes=8)
            self.assertFalse((fill / 'block-00000002').exists())
            link = mount / 'linked-fill'
            link.symlink_to(root)
            with self.assertRaises(SystemExit):
                pressure.write_block(mount, image, link, counter, huge_free, huge_free, os.getpid(), images_for(image, mount), block_bytes=8)


if __name__ == '__main__':
    unittest.main()
