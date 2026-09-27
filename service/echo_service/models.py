"""Pinned model manifests and verified local-asset readiness."""
import hashlib
import json
import os
from pathlib import Path
from .errors import ServiceError
from .paths import no_symlinks

MANIFEST_PATH = Path(__file__).with_name("models.json")
if not MANIFEST_PATH.exists():
    MANIFEST_PATH = Path(__file__).parents[1] / "models.json"
MANIFEST = json.loads(MANIFEST_PATH.read_text())


def digest(path: Path, *, git_blob=False):
    h = hashlib.sha1() if git_blob else hashlib.sha256()
    if git_blob:
        h.update(f"blob {path.stat().st_size}\0".encode())
    with path.open("rb") as stream:
        while chunk := stream.read(1024 * 1024):
            h.update(chunk)
    return h.hexdigest()


class ModelAssets:
    def __init__(self, root: Path):
        self.root = root
        self._verified = {}

    def path(self, name):
        item = MANIFEST["models"][name]
        return self.root / "models" / name / item["revision"]

    def clean_layout(self, name):
        """Only manifest files and the receipt may exist in a model snapshot.

        Walk without following links, including links under unlisted directories.
        Missing expected files are handled separately by checksum verification.
        """
        path = self.path(name)
        allowed = {file["path"] for file in MANIFEST["models"][name]["files"]}
        allowed.add(".verified.json")
        directories = {str(parent) for file in allowed for parent in Path(file).parents if str(parent) != "."}
        try:
            no_symlinks(path)
            if not path.is_dir():
                return False
            def walk_error(error):
                raise error
            for directory, children, files in os.walk(path, followlinks=False, onerror=walk_error):
                for name in children + files:
                    entry = Path(directory) / name
                    if entry.is_symlink():
                        return False
                    relative = entry.relative_to(path).as_posix()
                    if entry.is_dir():
                        if relative not in directories:
                            return False
                    elif not entry.is_file() or relative not in allowed:
                        return False
            return True
        except (OSError, ValueError, ServiceError):
            return False

    def ready(self, name):
        item = MANIFEST["models"][name]
        path = self.path(name)
        try:
            if not self.clean_layout(name):
                return False
            receipt_path = path / ".verified.json"
            no_symlinks(receipt_path)
            receipt = json.loads(receipt_path.read_text())
            if receipt.get("revision") != item["revision"]:
                return False
            for file in item["files"]:
                local = path / file["path"]
                no_symlinks(local)
                stat = local.stat()
                if not local.is_file() or stat.st_size != file["size"]:
                    return False
                key = (str(local), stat.st_size, stat.st_mtime_ns, stat.st_ctime_ns)
                if key not in self._verified:
                    expected = file["sha256"] or file["git_blob_sha1"]
                    if digest(local, git_blob=file["sha256"] is None) != expected:
                        return False
                    self._verified[key] = True
            return True
        except (OSError, ValueError, KeyError, ServiceError):
            return False

    def require(self, name):
        if not self.ready(name):
            raise ServiceError("model_unavailable", "Required local model is missing or incomplete. Run model setup.", 503)
        return self.path(name)

    def status(self):
        return {key: {"ready": self.ready(key), "revision": value["revision"]} for key, value in MANIFEST["models"].items()}


def source_path(root: Path) -> Path:
    path = Path(os.environ.get("ECHO_VOICESTUDIO_ROOT", root / "runtime" / "vendor" / "VoiceStudio"))
    try:
        no_symlinks(path)
        if (path / ".echo-revision").read_text().strip() != MANIFEST["voicestudio"]["revision"]:
            raise ValueError()
        if not (path / "backend" / "services" / "asr_backend.py").is_file():
            raise ValueError()
        return path
    except (OSError, ValueError):
        raise ServiceError("runtime_unavailable", "Pinned speech runtime is unavailable. Repair the runtime.", 503) from None
