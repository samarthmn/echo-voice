"""Exercise the real shell flow with tiny pinned archives and no network.

Only the scratch copy's archive pins and curl executable are substituted. The
production script exposes no environment override for integrity validation.
"""
import hashlib
import io
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import unittest
import uuid


PROJECT = Path(__file__).resolve().parents[2]
SCRIPT = PROJECT / "scripts" / "bootstrap-runtime.sh"
TEST_ROOT = Path(os.environ.get("ECHO_TEST_ROOT", PROJECT / "tmp" / "bootstrap-tests"))
REVISION = "7ec803afa7c94ccf96973edcda58debe9b145693"
UV_ARCHIVE = "uv-0.11.21-aarch64-apple-darwin.tar.gz"
VOICE_ARCHIVE = f"VoiceStudio-{REVISION}.tar.gz"
UV_BYTES = b'#!/bin/bash\nset -eu\nmkdir -p "$UV_PROJECT_ENVIRONMENT"\nprintf synced > "$UV_PROJECT_ENVIRONMENT/fixture-sync"\n'
SOURCE_BYTES = b'PINNED_SPEECH_ENGINE = True\n'


def archive(path, files):
    with tarfile.open(path, "w:gz") as tar:
        for name, content, mode in files:
            info = tarfile.TarInfo(name)
            info.size, info.mode = len(content), mode
            tar.addfile(info, io.BytesIO(content))
    return hashlib.sha256(path.read_bytes()).hexdigest()


class BootstrapRepairTests(unittest.TestCase):
    def setUp(self):
        self.root = TEST_ROOT / ("bootstrap-" + uuid.uuid4().hex)
        self.root.mkdir(parents=True)
        self.data = self.root / "application data"
        self.runtime = self.data / "runtime"
        self.cache = self.runtime / "cache" / "bootstrap"
        self.cache.mkdir(parents=True)
        self.source = self.root / "bundled service"
        self.source.mkdir()
        (self.source / "pyproject.toml").write_text("# synthetic service\n")
        self.fixture_archives = self.root / "archives"
        self.fixture_archives.mkdir()
        uv_sha = archive(self.fixture_archives / UV_ARCHIVE, [("uv-aarch64-apple-darwin/uv", UV_BYTES, 0o755)])
        voice_sha = archive(self.fixture_archives / VOICE_ARCHIVE, [
            (f"VoiceStudio-{REVISION}/backend/services/asr_backend.py", SOURCE_BYTES, 0o644),
            (f"VoiceStudio-{REVISION}/LICENSE", b"Synthetic fixture\n", 0o644),
        ])
        self.network_marker = self.root / "download-attempted"
        self.curl = self.root / "blocked-curl"
        self.curl.write_text(f"#!/bin/bash\nprintf blocked > '{self.network_marker}'\nexit 91\n")
        self.curl.chmod(0o755)
        code = SCRIPT.read_text().replace(
            "ECHO_UV_SHA=1f921d491ba5ffeea774eb04d6681ecee379101341cbb1500394993b541bf3f4", f"ECHO_UV_SHA={uv_sha}"
        ).replace(
            "ECHO_ARCHIVE_SHA=aa04877d36838adb96f58577128f2049d8ef0e2ea5e14379936ac75929d1201c", f"ECHO_ARCHIVE_SHA={voice_sha}"
        ).replace("/usr/bin/curl", f"'{self.curl}'")
        self.script = self.root / "bootstrap-fixture.sh"
        self.script.write_text(code)
        for name in (UV_ARCHIVE, VOICE_ARCHIVE):
            shutil.copyfile(self.fixture_archives / name, self.cache / name)

    def tearDown(self):
        shutil.rmtree(self.root)

    def run_setup(self, success=True):
        result = subprocess.run(["/bin/bash", str(self.script), str(self.data), str(self.source)],
                                env={"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "TMPDIR": str(self.root)},
                                capture_output=True, text=True, timeout=10)
        if success:
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn('"status":"Runtime ready"', result.stdout)
        else:
            self.assertNotEqual(result.returncode, 0)
            self.assertNotIn('"status":"Runtime ready"', result.stdout)
        return result

    @property
    def voice(self):
        return self.runtime / "vendor" / "VoiceStudio"

    def test_cached_install_and_good_recheck_are_offline_and_preserve_files(self):
        self.run_setup()
        uv = self.runtime / "bin" / "uv"
        speech = self.voice / "backend" / "services" / "asr_backend.py"
        self.assertEqual(uv.read_bytes(), UV_BYTES)
        self.assertEqual(speech.read_bytes(), SOURCE_BYTES)
        identity = (uv.stat().st_ino, speech.stat().st_ino)
        self.run_setup()
        self.assertEqual((uv.stat().st_ino, speech.stat().st_ino), identity)
        self.assertFalse(self.network_marker.exists())
        self.assertTrue((self.cache / UV_ARCHIVE).is_file())
        self.assertTrue((self.cache / VOICE_ARCHIVE).is_file())
        self.assertEqual(list((self.runtime / "setup-tmp").iterdir()), [])

    def test_corrupt_executable_is_repaired_before_it_can_run(self):
        self.run_setup()
        uv = self.runtime / "bin" / "uv"
        uv.write_text('#!/bin/bash\necho bad > "$UV_PROJECT_ENVIRONMENT/untrusted"\nexit 99\n')
        uv.chmod(0o755)
        self.run_setup()
        self.assertEqual(uv.read_bytes(), UV_BYTES)
        self.assertFalse((self.runtime / "venv" / "untrusted").exists())
        self.assertFalse(self.network_marker.exists())

    def test_intact_revision_marker_does_not_hide_missing_or_changed_source(self):
        self.run_setup()
        speech = self.voice / "backend" / "services" / "asr_backend.py"
        for damage in ("missing", "changed", "extra"):
            with self.subTest(damage=damage):
                if damage == "missing":
                    speech.unlink()
                elif damage == "changed":
                    speech.write_text("UNTRUSTED = True\n")
                else:
                    (self.voice / "unexpected.py").write_text("UNTRUSTED = True\n")
                self.assertEqual((self.voice / ".echo-revision").read_text().strip(), REVISION)
                self.run_setup()
                self.assertEqual(speech.read_bytes(), SOURCE_BYTES)
                self.assertFalse((self.voice / "unexpected.py").exists())
        self.assertFalse(self.network_marker.exists())

    def test_source_and_uv_symlinks_are_replaced_without_changing_targets(self):
        self.run_setup()
        outside = self.root / "independent-files"
        outside.mkdir()
        target_uv = outside / "uv"
        target_uv.write_bytes(UV_BYTES)
        target_uv.chmod(0o755)
        target_speech = outside / "asr_backend.py"
        target_speech.write_bytes(SOURCE_BYTES)
        uv = self.runtime / "bin" / "uv"
        speech = self.voice / "backend" / "services" / "asr_backend.py"
        uv.unlink(); uv.symlink_to(target_uv)
        speech.unlink(); speech.symlink_to(target_speech)
        self.run_setup()
        self.assertFalse(uv.is_symlink())
        self.assertFalse(speech.is_symlink())
        self.assertEqual(target_uv.read_bytes(), UV_BYTES)
        self.assertEqual(target_speech.read_bytes(), SOURCE_BYTES)

    def test_corrupt_cached_archive_is_not_trusted_even_when_installed_files_match(self):
        self.run_setup()
        (self.cache / VOICE_ARCHIVE).write_bytes(b"corrupt archive")
        self.run_setup(success=False)
        self.assertTrue(self.network_marker.exists())  # Stubbed transport only.
        self.assertEqual((self.voice / "backend/services/asr_backend.py").read_bytes(), SOURCE_BYTES)

    def test_managed_directory_symlink_is_rejected_before_writes(self):
        independent = self.root / "independent-cache"
        independent.mkdir()
        marker = independent / "keep"
        marker.write_text("unchanged")
        shutil.rmtree(self.runtime / "cache")
        (self.runtime / "cache").symlink_to(independent, target_is_directory=True)
        self.run_setup(success=False)
        self.assertEqual(list(independent.iterdir()), [marker])
        self.assertEqual(marker.read_text(), "unchanged")
        self.assertFalse(self.network_marker.exists())

    def test_service_replacement_removes_stale_files_without_following_links(self):
        self.run_setup()
        independent = self.root / "independent-service"
        independent.mkdir()
        (independent / "keep").write_text("unchanged")
        (self.runtime / "service" / "stale.py").write_text("obsolete")
        (self.runtime / "service" / "injected").symlink_to(independent, target_is_directory=True)
        self.run_setup()
        self.assertEqual(sorted(p.name for p in (self.runtime / "service").iterdir()), ["pyproject.toml"])
        self.assertEqual((independent / "keep").read_text(), "unchanged")

    def test_unverified_download_is_rejected_before_execution(self):
        (self.cache / UV_ARCHIVE).unlink()
        self.curl.write_text('''#!/bin/bash
while [ "$#" -gt 0 ]; do
  if [ "$1" = -o ]; then printf unverified > "$2"; exit 0; fi
  shift
done
exit 92
''')
        result = self.run_setup(success=False)
        self.assertIn("checksum mismatch", result.stderr)
        self.assertFalse((self.runtime / "bin" / "uv").exists())
        self.assertFalse((self.runtime / "venv" / "fixture-sync").exists())
        self.assertFalse((self.cache / UV_ARCHIVE).exists())


if __name__ == "__main__":
    unittest.main()
