"""Reject ambiguous paths and all symlinks in service-owned media paths."""
from pathlib import Path, PurePosixPath
import os
import re
from .errors import ServiceError

IDENTIFIER = re.compile(r"[A-Za-z0-9][A-Za-z0-9_-]{0,127}\Z")

def identifier(value: str) -> str:
    if not IDENTIFIER.fullmatch(value):
        raise ServiceError("invalid_path", "Invalid identifier.")
    return value


def no_symlinks(path: Path):
    for part in (path, *path.parents):
        if part.is_symlink():
            raise ServiceError("invalid_path", "Symbolic links are not allowed.")


class MediaPaths:
    def __init__(self, root: Path):
        self.root = Path(root).absolute()
        no_symlinks(self.root)

    def meeting(self, meeting_id: str) -> Path:
        path = self.root / "meetings" / identifier(meeting_id)
        no_symlinks(path)
        if not path.is_dir():
            raise ServiceError("missing_meeting", "Meeting directory is unavailable.", 404)
        return path

    def resolve(self, meeting_id: str, relative: str) -> Path:
        if not relative or "\\" in relative or "\x00" in relative:
            raise ServiceError("invalid_path", "A relative media path is required.")
        parts = relative.split("/")
        if any(p in ("", ".", "..") for p in parts) or PurePosixPath(relative).is_absolute():
            raise ServiceError("invalid_path", "A relative media path is required.")
        path = self.meeting(meeting_id).joinpath(*parts)
        no_symlinks(path)
        return path

    def input(self, meeting_id: str, relative: str) -> Path:
        path = self.resolve(meeting_id, relative)
        if not path.is_file():
            raise ServiceError("missing_audio", "Audio file is unavailable.", 404)
        if path.suffix.lower() != ".wav":
            raise ServiceError("invalid_audio", "The service accepts WAV audio only.")
        return path

    def output(self, meeting_id: str, relative: str, *, allow_existing=False) -> Path:
        path = self.resolve(meeting_id, relative)
        if path.suffix.lower() != ".wav":
            raise ServiceError("invalid_audio", "Derived audio must be a WAV file.")
        if path.exists() and not allow_existing:
            raise ServiceError("output_exists", "Derived output already exists.", 409)
        # A separate derived namespace ensures a request cannot replace raw tracks.
        if not relative.startswith("derived/"):
            raise ServiceError("invalid_path", "Derived audio must be inside derived/.")
        path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        no_symlinks(path)
        return path


def atomic_json(path: Path, data):
    import json
    import uuid
    no_symlinks(path)
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    temporary = path.with_name(path.name + "." + uuid.uuid4().hex + ".partial")
    try:
        with temporary.open("x", encoding="utf-8") as f:
            os.chmod(temporary, 0o600)
            json.dump(data, f, separators=(",", ":"), allow_nan=False)
            f.flush()
            os.fsync(f.fileno())
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)
