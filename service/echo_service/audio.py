from dataclasses import dataclass
from pathlib import Path
import soundfile as sf
from .errors import ServiceError

@dataclass(frozen=True)
class AudioInfo:
    frames: int
    sample_rate: int
    channels: int
    @property
    def duration(self):
        return self.frames / self.sample_rate


def inspect_wav(path: Path, *, max_seconds: float | None = None, aligned=False, allow_empty=False) -> AudioInfo:
    try:
        info = sf.info(str(path))
        if info.format not in ("WAV", "WAVEX", "RF64") or info.samplerate <= 0:
            raise ValueError()
        if info.frames < (0 if allow_empty else 1) or info.channels < 1 or info.channels > 2:
            raise ValueError()
        if max_seconds is not None and info.frames > max_seconds * info.samplerate:
            raise ValueError()
        if aligned and (info.samplerate != 16000 or info.channels != 1 or info.subtype != "PCM_16"):
            raise ValueError()
        return AudioInfo(info.frames, info.samplerate, info.channels)
    except (OSError, RuntimeError, ValueError):
        raise ServiceError("invalid_audio", "Audio is invalid or exceeds this operation's limits.") from None
