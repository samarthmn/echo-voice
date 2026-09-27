import numpy as np
import pytest
import soundfile as sf
from echo_service.audio import inspect_wav
from echo_service.aec import FrameProcessor
from echo_service.errors import ServiceError

class RecordingProcessor:
    def __init__(self):
        self.calls = []
    def process(self, near, far):
        self.calls.append((near.copy(), far.copy()))
        return near - far

def test_partial_frames_carried_then_flushed_once():
    engine = RecordingProcessor()
    frames = FrameProcessor(engine)
    near = np.arange(321, dtype=np.int16)
    far = np.ones(321, dtype=np.int16)
    first = frames.process(near[:103], far[:103])
    assert len(first) == 0
    second = frames.process(near[103:], far[103:])
    final = frames.process(near[:0], far[:0], final=True)
    assert np.array_equal(np.concatenate((first, second, final)), near - far)
    assert [len(n) for n, _ in engine.calls] == [160, 160, 160]
    assert len(frames.process(near[:0], far[:0], final=True)) == 0

def test_missing_far_is_never_synthesized():
    with pytest.raises(ServiceError):
        FrameProcessor(RecordingProcessor()).process(np.zeros(160, dtype=np.int16), None)

def test_audio_limits_and_alignment(wav):
    assert inspect_wav(wav(), max_seconds=30).frames == 16000
    with pytest.raises(ServiceError):
        inspect_wav(wav("long.wav", frames=480001), max_seconds=30)
    with pytest.raises(ServiceError):
        inspect_wav(wav("stereo.wav", channels=2), aligned=True)
    with pytest.raises(ServiceError):
        inspect_wav(wav("rate.wav", rate=48000), aligned=True)
