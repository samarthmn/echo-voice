"""Local speech detection; bundled, version-locked Silero weights, no hub calls."""
import numpy as np


class SpeechActivity:
    def __init__(self):
        self.model = None

    def regions(self, audio):
        samples = np.asarray(audio, dtype=np.float32)
        if not samples.size or not np.isfinite(samples).all():
            return []
        # Fast path for digital silence. Quiet speech still reaches the VAD.
        if np.max(np.abs(samples)) < 1.0 / 32768:
            return []
        import torch
        from silero_vad import load_silero_vad, get_speech_timestamps
        if self.model is None:
            torch.set_num_threads(2)
            self.model = load_silero_vad(onnx=False)
        # get_speech_timestamps resets state per bounded window. Padding keeps
        # word onsets/ends; returned sample positions preserve the meeting clock.
        regions = get_speech_timestamps(
            torch.from_numpy(samples.copy()), self.model, sampling_rate=16000,
            threshold=0.3, min_speech_duration_ms=64,
            min_silence_duration_ms=450, speech_pad_ms=450,
            return_seconds=False,
        )
        merged = []
        for item in regions:
            begin, end = int(item['start']), int(item['end'])
            if merged and begin - merged[-1][1] <= 16000:
                merged[-1] = (merged[-1][0], end)
            else:
                merged.append((begin, end))
        return merged
