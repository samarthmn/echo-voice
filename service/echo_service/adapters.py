"""The only upstream imports: explicitly selected speech services, no router/TTS."""
from pathlib import Path
from contextlib import contextmanager
import random
import sys
import numpy as np
import soundfile as sf
from .audio import inspect_wav
from .models import ModelAssets, source_path, MANIFEST
from .errors import ServiceError
from .speech_activity import SpeechActivity
from .word_timing import whisper_words, parakeet_words, corrected_words
from .vocabulary import validate_entries, correct, prompt_terms


def prepare_source(root):
    sys.path.insert(0, str(source_path(root) / "backend"))


@contextmanager
def local_diarization_config(root):
    """Use VoiceStudio's config rewriter with an explicit verified-file resolver.

    Its usual Hugging Face cache may contain unrelated mutable revisions. This
    tightly scoped patch returns only our checked snapshots and cannot download.
    """
    import huggingface_hub
    from services.diarization_local import local_pipeline_config
    assets = ModelAssets(root)
    allowed = {MANIFEST["models"][name]["repo"]: name for name in ("diarization", "segmentation", "embedding")}
    original = huggingface_hub.hf_hub_download
    def local_file(*, repo_id, filename, revision, local_files_only):
        name = allowed.get(repo_id)
        if name is None or not local_files_only or revision != MANIFEST["models"][name]["revision"]:
            raise ServiceError("model_unavailable", "Diarization requires the pinned local model bundle.", 503)
        expected = "config.yaml" if name == "diarization" else "pytorch_model.bin"
        if filename != expected:
            raise ServiceError("model_unavailable", "Unexpected diarization model file.", 503)
        return str(assets.require(name) / filename)
    huggingface_hub.hf_hub_download = local_file
    try:
        with local_pipeline_config() as path:
            yield path
    finally:
        huggingface_hub.hf_hub_download = original


class WhisperAdapter:
    def __init__(self, root):
        path = ModelAssets(root).require("asr")
        prepare_source(root)
        from services import asr_backend
        import mlx_whisper
        # Pin English at the mlx call boundary: this VoiceStudio revision has
        # no language argument. word_timestamps=False below bypasses its aligner.
        self.activity = SpeechActivity()
        self.vocabulary = []
        self.fuzzy = False
        original = getattr(mlx_whisper.transcribe, "_echo_original", mlx_whisper.transcribe)
        def english(audio, **kwargs):
            kwargs["language"] = "en"
            kwargs["task"] = "transcribe"
            kwargs["verbose"] = None
            kwargs["word_timestamps"] = True
            if self.vocabulary:
                from mlx_whisper.tokenizer import get_tokenizer
                tokenizer = get_tokenizer(multilingual=True, language="en", task="transcribe")
                kwargs["initial_prompt"] = prompt_terms(self.vocabulary, tokenizer.encode)
            kwargs.update(condition_on_previous_text=False, temperature=0.0,
                          no_speech_threshold=0.5, logprob_threshold=-1.0,
                          compression_ratio_threshold=2.4)
            segments = []
            for begin, end in self.activity.regions(audio):
                decoded = original(audio[begin:end], **kwargs)
                rows = decoded.get("segments", [])
                suspicious = any(float(row.get("compression_ratio", 0)) > 2.4 for row in rows)
                if suspicious:
                    # One bounded retry, never an unbounded temperature sweep.
                    retry_kwargs = {**kwargs, "temperature": 0.2}
                    decoded = original(audio[begin:end], **retry_kwargs)
                previous_start = -1.0
                for item in decoded.get("segments", []):
                    # Reject uncertain silence and decoder loops at their source.
                    # Never blacklist real phrases such as "Thank you".
                    if (float(item.get("no_speech_prob", 0)) > 0.6 and
                        float(item.get("avg_logprob", 0)) < -1.0):
                        continue
                    start = max(0., float(item["start"]))
                    stop = min((end - begin) / 16000, float(item["end"]))
                    if start < previous_start or (start == previous_start and suspicious):
                        continue
                    previous_start = start
                    if np.isfinite(start) and np.isfinite(stop) and stop > start:
                        segments.append({**item, "start": start + begin / 16000,
                                         "end": stop + begin / 16000,
                                         "echo_words": whisper_words(item.get("words", []), str(item.get("text", "")).strip(), begin / 16000, (end - begin) / 16000),
                                         "uncertain": float(item.get("avg_logprob", 0)) < -1.0 or float(item.get("compression_ratio", 0)) > 2.4})
            return {"segments": segments, "language": "en"}
        english._echo_original = original
        mlx_whisper.transcribe = english
        # Our validated 16 kHz mono PCM WAVs need no ffmpeg subprocess.
        asr_backend._decode_audio_16k_mono = lambda path: sf.read(path, dtype="float32")[0]
        self.backend = asr_backend.MLXWhisperBackend(model_name=str(path))

    def transcribe(self, path, vocabulary=None, fuzzy=False):
        self.vocabulary = validate_entries(vocabulary or [])
        self.fuzzy = fuzzy
        info = inspect_wav(path, max_seconds=30, aligned=True)
        result = self.backend.transcribe(str(path), word_timestamps=False)
        segments = []
        seen = set()
        for segment in result.get("segments", []):
            start = max(0.0, float(segment["start"]))
            end = min(info.duration, float(segment["end"]))
            if np.isfinite(start) and np.isfinite(end) and end > start:
                text = str(segment.get("text", "")).strip()
                key = (start, end, text)
                if text and key not in seen:
                    seen.add(key)
                    corrected, changes = correct(text, self.vocabulary)
                    segments.append({"start": start, "end": end, "text": corrected, "original_text": text,
                                     "words": corrected_words(text, corrected, segment.get("echo_words", []), changes),
                                     "corrections": changes, "uncertain": segment.get("uncertain", False),
                                     "confidence": {key: segment[key] for key in ("avg_logprob", "no_speech_prob", "compression_ratio") if key in segment}})
        return {"segments": segments, "language": "en", "engine": "mlx-whisper"}


class ParakeetAdapter:
    """INT8 ONNX export of NVIDIA Parakeet Unified EN 0.6B, local CPU only."""
    def __init__(self, root):
        import sherpa_onnx
        path = ModelAssets(root).require("parakeet")
        self.activity = SpeechActivity()
        self.vocabulary = []
        self.fuzzy = False
        self.recognizer = sherpa_onnx.OfflineRecognizer.from_transducer(
            encoder=str(path / "encoder.int8.onnx"),
            decoder=str(path / "decoder.int8.onnx"),
            joiner=str(path / "joiner.int8.onnx"),
            tokens=str(path / "tokens.txt"),
            model_type="nemo_transducer", num_threads=2, provider="cpu",
            decoding_method="greedy_search", sample_rate=16000, feature_dim=80,
        )

    def transcribe(self, path, vocabulary=None, fuzzy=False):
        self.vocabulary = validate_entries(vocabulary or [])
        self.fuzzy = fuzzy
        inspect_wav(path, max_seconds=30, aligned=True)
        audio, _ = sf.read(path, dtype="float32")
        segments = []
        for begin, end in self.activity.regions(audio):
            stream = self.recognizer.create_stream()
            stream.accept_waveform(16000, audio[begin:end])
            # Decode independently: silence in another stream must not suppress speech.
            self.recognizer.decode_stream(stream)
            text = stream.result.text.strip()
            if text:
                # Unified supplies token emissions, not TDT durations.
                timed = parakeet_words(stream.result.tokens, stream.result.timestamps, text, begin / 16000, (end - begin) / 16000)
                corrected, changes = correct(text, self.vocabulary, fuzzy=self.fuzzy)
                segments.append({"start": begin / 16000, "end": end / 16000, "text": corrected, "original_text": text,
                                 "words": corrected_words(text, corrected, timed, changes), "corrections": changes, "uncertain": False})
        return {"segments": segments, "language": "en", "engine": "parakeet-unified-onnx-int8"}


class DiarizationAdapter:
    def __init__(self, root):
        assets = ModelAssets(root)
        for name in ("diarization", "segmentation", "embedding"):
            assets.require(name)
        prepare_source(root)
        import torch
        random.seed(0)
        np.random.seed(0)
        torch.manual_seed(0)
        torch.set_num_threads(2)
        from services.asr_backend import WhisperXBackend
        WhisperXBackend._allow_vad_pickle_globals()
        from pyannote.audio import Pipeline
        # VoiceStudio replaces both nested model references with local files.
        with local_diarization_config(root) as configuration:
            self.pipeline = Pipeline.from_pretrained(configuration, use_auth_token=False)
        if self.pipeline is None:
            raise RuntimeError("pipeline unavailable")
        self.pipeline.to(torch.device("cpu"))
        self.pipeline.clustering.max_num_embeddings = 2000

    def diarize(self, path: Path, window_seconds):
        from .community import diarize_bounded
        return diarize_bounded(self.pipeline, path, window_seconds)
