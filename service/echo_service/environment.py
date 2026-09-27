"""Set all model/cache switches before importing inference libraries."""
import os
import tempfile
from pathlib import Path

def configure(root: Path, *, offline=True):
    from .paths import no_symlinks
    no_symlinks(root)
    runtime_tmp = root / "runtime" / "tmp"
    no_symlinks(runtime_tmp)
    runtime_tmp.mkdir(parents=True, exist_ok=True, mode=0o700)
    values = {
        "HF_HOME": str(root / "models" / "hf"),
        "HF_HUB_CACHE": str(root / "models" / "hub"),
        "HF_HUB_OFFLINE": "1" if offline else "0",
        "TRANSFORMERS_OFFLINE": "1" if offline else "0",
        "HF_HUB_DISABLE_TELEMETRY": "1", "HF_HUB_DISABLE_IMPLICIT_TOKEN": "1",
        "HF_HUB_DISABLE_PROGRESS_BARS": "1", "PYANNOTE_METRICS_ENABLED": "false",
        "DO_NOT_TRACK": "1", "TOKENIZERS_PARALLELISM": "false",
        "MPLCONFIGDIR": str(runtime_tmp / "matplotlib"),
        "XDG_CACHE_HOME": str(runtime_tmp / "cache"),
        "TORCH_HOME": str(root / "models" / "torch"),
        "TMPDIR": str(runtime_tmp), "TMP": str(runtime_tmp), "TEMP": str(runtime_tmp),
        "NUMBA_CACHE_DIR": str(runtime_tmp / "numba"),
    }
    os.environ.update(values)
    tempfile.tempdir = str(runtime_tmp)
    # Authentication is never inherited by worker libraries.
    for name in ("HF_TOKEN", "HUGGING_FACE_HUB_TOKEN", "HUGGINGFACE_TOKEN"):
        os.environ.pop(name, None)
