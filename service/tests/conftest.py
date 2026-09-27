import os
from pathlib import Path
import shutil
import uuid
import numpy as np
import pytest
import soundfile as sf

PROJECT = Path(__file__).resolve().parents[2]
TEST_ROOT = Path(os.environ.get("ECHO_TEST_ROOT", PROJECT / "tmp" / "service-tests"))

@pytest.fixture
def data_root():
    root = TEST_ROOT / str(uuid.uuid4())
    (root / "meetings" / "meeting").mkdir(parents=True)
    yield root
    shutil.rmtree(root)

@pytest.fixture
def wav(data_root):
    def write(name="input.wav", frames=16000, rate=16000, channels=1):
        p = data_root / "meetings" / "meeting" / name
        p.parent.mkdir(parents=True, exist_ok=True)
        sf.write(p, np.zeros((frames, channels), dtype=np.int16), rate, subtype="PCM_16")
        return p
    return write
