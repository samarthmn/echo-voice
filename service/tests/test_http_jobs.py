import asyncio
import json
from pathlib import Path
import pytest
import httpx
from echo_service.api import create_app
from echo_service.service import SpeechService
from echo_service.errors import ServiceError

class ControlledWorker:
    def __init__(self, kind, root, **kwargs):
        self.kind = kind
        self.active_job = None
        self.calls = 0
        self.terminations = 0
    async def run(self, request):
        self.calls += 1
        self.active_job = request["job_id"]
        try:
            await asyncio.sleep(0.1)
            return {"job_id": request["job_id"], "segments": [{"start": 0.0, "end": 1.0, "text": "local sample"}], "language": "en", "engine": "mlx-whisper"}
        finally:
            self.active_job = None
    def terminate(self):
        self.terminations += 1

@pytest.fixture
def service(data_root, monkeypatch):
    service = SpeechService(data_root, worker_factory=ControlledWorker)
    monkeypatch.setattr(service.assets, "require", lambda name: data_root / "model")
    monkeypatch.setattr("echo_service.service.source_path", lambda root: root)
    return service

def payload():
    return {"job_id": "transcription", "meeting_id": "meeting", "window_id": "window", "track": "remote", "relative_path": "input.wav", "start_time": 0, "language": "en"}

async def test_cancel_during_validation_prevents_worker_admission(service, wav, monkeypatch):
    import threading
    wav()
    started = threading.Event()
    release = threading.Event()
    validate = service.validate
    def delayed_validation(kind, request):
        started.set()
        assert release.wait(5)
        return validate(kind, request)
    monkeypatch.setattr(service, "validate", delayed_validation)
    pending = asyncio.create_task(service.execute("asr", payload()))
    try:
        assert await asyncio.to_thread(started.wait, 5)
        assert service.cancel("transcription") is True
    finally:
        release.set()
    outcome = (await asyncio.gather(pending, return_exceptions=True))[0]
    assert isinstance(outcome, (asyncio.CancelledError, ServiceError))
    assert service.asr.calls == 0
    # Intentional cancellation must not permanently tombstone a reusable final window.
    await service.execute("asr", payload())
    assert service.asr.calls == 1
    await service.close()

async def test_cancel_covers_duplicate_validations_finishing_out_of_order(service, wav, monkeypatch):
    import threading
    wav()
    entered = [threading.Event(), threading.Event()]
    release = [threading.Event(), threading.Event()]
    lock = threading.Lock()
    count = 0
    validate = service.validate
    def delayed_validation(kind, request):
        nonlocal count
        with lock:
            index = count
            count += 1
        entered[index].set()
        assert release[index].wait(5)
        return validate(kind, request)
    monkeypatch.setattr(service, "validate", delayed_validation)
    first = asyncio.create_task(service.execute("asr", payload()))
    assert await asyncio.to_thread(entered[0].wait, 5)
    second = asyncio.create_task(service.execute("asr", payload()))
    try:
        assert await asyncio.to_thread(entered[1].wait, 5)
        release[1].set()
        for _ in range(100):
            if service.asr.calls:
                break
            await asyncio.sleep(0.001)
        assert service.asr.calls == 1
        assert service.cancel("transcription") is True
    finally:
        release[0].set()
        release[1].set()
    results = await asyncio.gather(first, second, return_exceptions=True)
    assert all(isinstance(result, (asyncio.CancelledError, ServiceError)) for result in results)
    assert service.asr.calls == 1
    await service.close()

async def test_http_job_idempotence_and_conflicts(service, data_root, wav):
    wav()
    app = create_app(data_root, "a" * 32, service=service)
    async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="http://127.0.0.1", headers={"Authorization": "Bearer " + "a" * 32}) as client:
        first, second = await asyncio.gather(*(client.post("/echo/v1/transcribe", json=payload()) for _ in range(2)))
        assert first.status_code == second.status_code == 200
        assert first.json() == second.json()
        assert service.asr.calls == 1
        third = await client.post("/echo/v1/transcribe", json=payload())
        assert third.json() == first.json()
        assert service.asr.calls == 1
        conflict = await client.post("/echo/v1/transcribe", json={**payload(), "start_time": 2})
        assert conflict.status_code == 409
    await service.close()

async def test_unload_cancels_queued_and_active_inference(service, wav):
    wav()
    tasks = [asyncio.create_task(service.execute("asr", {**payload(), "job_id": f"job{i}"})) for i in range(3)]
    await asyncio.sleep(0.03)
    service.unload()
    await asyncio.gather(*tasks, return_exceptions=True)
    assert service.asr.calls <= 1
    await service.close()

async def test_http_path_traversal_before_any_inference(service, data_root):
    app = create_app(data_root, "a" * 32, service=service)
    async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="http://127.0.0.1", headers={"Authorization": "Bearer " + "a" * 32}) as client:
        response = await client.post("/echo/v1/transcribe", json={**payload(), "relative_path": "../../private.wav"})
        assert response.status_code == 400
        assert service.asr.calls == 0
    await service.close()

async def test_cancel_http_endpoint_stops_inflight_request(service, data_root, wav):
    wav()
    app = create_app(data_root, "a" * 32, service=service)
    async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="http://127.0.0.1", headers={"Authorization": "Bearer " + "a" * 32}) as client:
        pending = asyncio.create_task(client.post("/echo/v1/transcribe", json=payload()))
        await asyncio.sleep(0.025)
        result = await client.post("/echo/v1/cancel", json={"job_id": "transcription"})
        assert result.json() == {"cancelled": True}
        cancelled = await pending
        assert cancelled.status_code == 409
        assert cancelled.json()["error"]["code"] == "cancelled"
        assert (await client.post("/echo/v1/cancel", json={"job_id": "unknown"})).json() == {"cancelled": False}
    await service.close()


async def test_model_switch_restarts_worker_and_cannot_reuse_receipt(service, wav):
    wav()
    first = await service.execute("asr", {**payload(), "model": "whisper"})
    terminated = service.asr.terminations
    from echo_service.errors import ServiceError
    with pytest.raises(ServiceError) as error:
        await service.execute("asr", {**payload(), "model": "parakeet"})
    assert error.value.code == "job_conflict"
    await service.execute("asr", {**payload(), "job_id": "parakeet-job", "model": "parakeet"})
    assert service.asr.terminations == terminated + 1
    assert service.asr_model == "parakeet"
    await service.close()


async def test_explicit_whisper_reuses_legacy_receipt(service, wav):
    wav()
    first = await service.execute("asr", payload())
    assert await service.execute("asr", {**payload(), "model": "whisper"}) == first
    assert service.asr.calls == 1
    await service.close()
