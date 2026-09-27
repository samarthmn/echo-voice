import contextlib
import os
from pathlib import Path
import sys
import types
import pytest
from echo_service.adapters import WhisperAdapter
from echo_service.models import ModelAssets


def test_pinned_upstream_whisper_uses_local_english_without_alignment(data_root, wav, monkeypatch):
    source = Path(os.environ.get("ECHO_VOICESTUDIO_ROOT", Path(__file__).parents[2] / "tmp" / "service-source"))
    if not source.exists():
        pytest.skip("Pinned VoiceStudio source not staged for integration test")
    monkeypatch.setenv("ECHO_VOICESTUDIO_ROOT", str(source))
    monkeypatch.setattr(ModelAssets, "require", lambda self, name: data_root / "local-model")
    # Model execution alone is substituted; the upstream backend and our full
    # adapter execute so fallback/model/path/language mistakes are observable.
    calls = []
    def transcribe(audio, **kwargs):
        calls.append(kwargs)
        assert audio.shape == (16000,)
        return {"language": "en", "segments": [{"start": 0, "end": 1, "text": " local sample "}]}
    monkeypatch.setitem(sys.modules, "mlx_whisper", types.SimpleNamespace(transcribe=transcribe))
    adapter = WhisperAdapter(data_root)
    adapter.activity = types.SimpleNamespace(regions=lambda audio: [(0, len(audio))])
    result = adapter.transcribe(wav())
    assert [(s["start"], s["end"], s["text"]) for s in result["segments"]] == [(0, 1, "local sample")]
    assert calls == [{"path_or_hf_repo": str(data_root / "local-model"), "word_timestamps": True, "language": "en", "task": "transcribe", "verbose": None, "condition_on_previous_text": False, "temperature": 0.0, "no_speech_threshold": 0.5, "logprob_threshold": -1.0, "compression_ratio_threshold": 2.4}]
    assert "backend.main" not in sys.modules


def test_diarization_config_resolves_only_verified_local_snapshots(data_root, monkeypatch):
    from echo_service.adapters import local_diarization_config, prepare_source
    from echo_service.models import MANIFEST
    source = Path(os.environ.get("ECHO_VOICESTUDIO_ROOT", Path(__file__).parents[2] / "tmp" / "service-source"))
    if not source.exists():
        pytest.skip("Pinned VoiceStudio source not staged for integration test")
    monkeypatch.setenv("ECHO_VOICESTUDIO_ROOT", str(source))
    prepare_source(data_root)
    for name in ("diarization", "segmentation", "embedding"):
        directory = ModelAssets(data_root).path(name)
        directory.mkdir(parents=True)
        (directory / "pytorch_model.bin").write_bytes(b'local')
    pipeline = ModelAssets(data_root).path("diarization") / "config.yaml"
    pipeline.write_text('pipeline:\n  params:\n    segmentation: pyannote/segmentation-3.0\n    embedding: pyannote/wespeaker-voxceleb-resnet34-LM\n')
    monkeypatch.setattr(ModelAssets, "require", lambda self, name: self.path(name))
    import yaml
    with local_diarization_config(data_root) as config:
        params = yaml.safe_load(Path(config).read_text())["pipeline"]["params"]
        assert params["segmentation"] == str(ModelAssets(data_root).path("segmentation") / "pytorch_model.bin")
        assert params["embedding"] == str(ModelAssets(data_root).path("embedding") / "pytorch_model.bin")
