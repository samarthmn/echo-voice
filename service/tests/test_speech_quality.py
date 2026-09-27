"""Bounded regressions for silence, decoding loops, and model selection."""
import sys
import types
import numpy as np
from echo_service.adapters import WhisperAdapter
from echo_service.models import ModelAssets


def adapter(monkeypatch, data_root, decoded, regions):
    calls = []
    def transcribe(audio, **kwargs):
        calls.append((len(audio), kwargs))
        return {'segments': decoded}
    monkeypatch.setattr(ModelAssets, 'require', lambda self, name: data_root)
    monkeypatch.setattr('echo_service.adapters.prepare_source', lambda root: None)
    monkeypatch.setitem(sys.modules, 'mlx_whisper', types.SimpleNamespace(transcribe=transcribe))
    class Backend:
        def __init__(self, **kwargs): pass
        def transcribe(self, path, **kwargs):
            return sys.modules['mlx_whisper'].transcribe(np.zeros(16000 * 5), **kwargs)
    monkeypatch.setitem(sys.modules, 'services', types.SimpleNamespace(asr_backend=types.SimpleNamespace(MLXWhisperBackend=Backend)))
    result = WhisperAdapter(data_root)
    result.activity = types.SimpleNamespace(regions=lambda audio: regions)
    return result, calls


def test_silence_never_invokes_decoder(monkeypatch, data_root, wav):
    a, calls = adapter(monkeypatch, data_root, [{'start': 0, 'end': 1, 'text': 'Thank you.'}], [])
    assert a.transcribe(wav(frames=80000))['segments'] == []
    assert calls == []


def test_speech_offsets_preserved_and_real_thank_you_kept(monkeypatch, data_root, wav):
    a, calls = adapter(monkeypatch, data_root, [{'start': 0, 'end': 1, 'text': 'Thank you.', 'avg_logprob': -.2, 'no_speech_prob': .01, 'compression_ratio': 1.1}], [(32000, 64000)])
    result = a.transcribe(wav(frames=80000))['segments']
    assert [(r['start'], r['end'], r['text']) for r in result] == [(2., 3., 'Thank you.')]
    assert result[0]['confidence']['avg_logprob'] == -.2
    assert calls[0][0] == 32000
    assert calls[0][1]['condition_on_previous_text'] is False
    assert calls[0][1]['temperature'] == 0.0


def test_low_confidence_retained_for_review_and_retry_bounded(monkeypatch, data_root, wav):
    bad = [dict(start=0, end=1, text='that', compression_ratio=4.8), dict(start=1, end=2, text='I love you.', no_speech_prob=.95), dict(start=2, end=3, text='random', avg_logprob=-2)]
    a, calls = adapter(monkeypatch, data_root, bad, [(0, 80000)])
    result = a.transcribe(wav(frames=80000))['segments']
    assert len(result) == 3
    assert result[0]['uncertain'] and result[2]['uncertain']
    assert len(calls) == 2


def test_exact_decoder_duplicates_saved_once(monkeypatch, data_root, wav):
    row = dict(start=0, end=1, text='A genuine word')
    a, _ = adapter(monkeypatch, data_root, [row, row], [(0, 80000)])
    assert len(a.transcribe(wav(frames=80000))['segments']) == 1


def test_model_contract_defaults_to_whisper_and_rejects_unknown():
    from echo_service.schema import Transcribe
    import pytest
    values = dict(job_id='j', meeting_id='m', window_id='w', track='remote', relative_path='a.wav', start_time=0)
    assert Transcribe(**values).model == 'whisper'
    assert Transcribe(**values, model='parakeet').model == 'parakeet'
    with pytest.raises(ValueError):
        Transcribe(**values, model='remote-api')
