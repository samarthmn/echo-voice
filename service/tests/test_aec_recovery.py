import numpy as np
import pytest
import soundfile as sf
from echo_service.aec import AECSession
from echo_service.errors import ServiceError
from echo_service.models import digest

def request(sequence, final=False):
    return {"job_id": f"job{sequence}", "meeting_id": "meeting", "epoch_id": "epoch", "sequence": sequence,
            "near_path": f"near{sequence}.wav", "far_path": f"far{sequence}.wav", "output_path": f"derived/clean{sequence}.wav", "reset": False, "final": final}

def test_actual_aec_replay_keeps_committed_output_and_raw_inputs(data_root, wav):
    for index, count in enumerate((103, 218)):
        wav(f"near{index}.wav", frames=count)
        wav(f"far{index}.wav", frames=count)
    source = data_root / "meetings" / "meeting" / "near0.wav"
    raw_hash = digest(source)
    first = AECSession(data_root).prepare(request(0))
    assert first["frame_count"] == 0
    output = data_root / "meetings" / "meeting" / first["relative_path"]
    modification = output.stat().st_mtime_ns
    restarted = AECSession(data_root)
    assert restarted.prepare(request(0)) == first
    second = restarted.prepare(request(1, final=True))
    assert second["frame_count"] == 321
    assert digest(source) == raw_hash
    assert output.stat().st_mtime_ns == modification
    assert restarted.prepare(request(1, final=True)) == second

def test_finalized_receipt_allows_replay_inputs_to_retire(data_root, wav):
    for index in range(2):
        wav(f"near{index}.wav", frames=160)
        wav(f"far{index}.wav", frames=160)
    session = AECSession(data_root)
    session.prepare(request(0))
    final = session.prepare(request(1, final=True))
    meeting = data_root / "meetings" / "meeting"
    for index in range(2):
        (meeting / f"near{index}.wav").unlink()
        (meeting / f"far{index}.wav").unlink()
    restarted = AECSession(data_root)
    assert restarted.prepare(request(1, final=True)) == final
    assert restarted.finalized_input_signatures(request(1, final=True)) is not None

def test_terminal_replay_reconstructs_receipt_after_journal_commit(data_root, wav):
    for index in range(2):
        wav(f"near{index}.wav", frames=160)
        wav(f"far{index}.wav", frames=160)
    session = AECSession(data_root)
    session.prepare(request(0))
    final = session.prepare(request(1, final=True))
    meeting = data_root / "meetings" / "meeting"
    receipt = meeting / "derived/.aec/epoch.finalized.json"
    receipt.unlink()  # crash after durable final journal but before its receipt
    restarted = AECSession(data_root)
    assert restarted.prepare(request(1, final=True)) == final
    assert receipt.is_file()
    for index in range(2):
        (meeting / f"near{index}.wav").unlink()
        (meeting / f"far{index}.wav").unlink()
    assert AECSession(data_root).prepare(request(1, final=True)) == final

def test_sequence_gap_and_job_conflict_rejected(data_root, wav):
    for index in range(2):
        wav(f"near{index}.wav", frames=160)
        wav(f"far{index}.wav", frames=160)
    session = AECSession(data_root)
    with pytest.raises(ServiceError) as error:
        session.prepare(request(1))
    assert error.value.code == "sequence_conflict"
    session.prepare(request(0))
    changed = {**request(0), "reset": True}
    with pytest.raises(ServiceError) as error:
        session.prepare(changed)
    assert error.value.code == "job_conflict"

def test_reset_discards_prior_adaptation_but_stays_in_sequence(data_root, wav):
    for index in range(2):
        wav(f"near{index}.wav", frames=103)
        wav(f"far{index}.wav", frames=103)
    session = AECSession(data_root)
    session.prepare(request(0))
    result = session.prepare({**request(1, final=True), "reset": True})
    assert result["frame_count"] == 103
