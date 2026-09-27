import asyncio
import os
import time
import pytest
from echo_service.supervisor import Worker
from echo_service.errors import ServiceError

# A real spawned process with a deterministic stand-in for expensive inference.
def controlled_worker(kind, root, connection):
    while True:
        request = connection.recv()
        if request.get("crash"):
            os._exit(7)
        if request.get("sleep"):
            time.sleep(10)
        connection.send({"job_id": request["job_id"], "pid": os.getpid()})

async def test_crashed_worker_is_replaced(data_root):
    worker = Worker("asr", data_root, target=controlled_worker)
    try:
        first = await worker.run({"job_id": "first"})
        with pytest.raises(ServiceError):
            await worker.run({"job_id": "crash", "crash": True})
        second = await worker.run({"job_id": "second"})
        assert first["pid"] != second["pid"]
    finally:
        worker.terminate()

async def test_cancel_terminates_model_process_and_next_request_recovers(data_root):
    worker = Worker("asr", data_root, target=controlled_worker)
    task = asyncio.create_task(worker.run({"job_id": "slow", "sleep": True}))
    await asyncio.sleep(0.2)
    worker.terminate()
    with pytest.raises(ServiceError) as result:
        await task
    assert result.value.code == "cancelled"
    assert (await worker.run({"job_id": "next"}))["job_id"] == "next"
    worker.terminate()

async def test_timeout_terminates_stuck_worker(data_root):
    worker = Worker("asr", data_root, target=controlled_worker, timeout=0.2)
    with pytest.raises(ServiceError) as result:
        await worker.run({"job_id": "slow", "sleep": True})
    assert result.value.code == "worker_timeout"
    assert worker.process is None

async def test_memory_watchdog_terminates_worker(data_root):
    worker = Worker("diarization", data_root, target=controlled_worker, memory_limit=1)
    with pytest.raises(ServiceError) as result:
        await worker.run({"job_id": "large", "sleep": True})
    assert result.value.code == "memory_limit"
    assert worker.process is None

async def test_real_aec_process_recovers_adaptation_from_journal(data_root, wav):
    from test_aec_recovery import request
    for index in range(2):
        wav(f"near{index}.wav", frames=103)
        wav(f"far{index}.wav", frames=103)
    worker = Worker("aec", data_root)
    try:
        assert (await worker.run(request(0)))["frame_count"] == 0
        worker.terminate()
        assert (await worker.run(request(1, final=True)))["frame_count"] == 206
    finally:
        worker.terminate()
