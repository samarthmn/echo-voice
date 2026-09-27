from pathlib import Path
import pytest
from fastapi.testclient import TestClient
from echo_service.api import create_app
from echo_service.errors import ServiceError
from echo_service.paths import MediaPaths

@pytest.mark.parametrize("path", ["../escape.wav", "/etc/passwd", "a/../../outside", "a\\b", "", "./input.wav"])
def test_unsafe_media_paths_rejected(data_root, path):
    with pytest.raises(ServiceError):
        MediaPaths(data_root).input("meeting", path)

@pytest.mark.parametrize("meeting", ["..", "a/b", "/tmp", "", "a\\b"])
def test_meeting_identifier_is_not_a_path(data_root, meeting):
    with pytest.raises(ServiceError):
        MediaPaths(data_root).input(meeting, "input.wav")

def test_symlink_escape_and_internal_symlink_rejected(data_root, wav):
    target = wav()
    link = target.parent / "linked.wav"
    link.symlink_to(target)
    with pytest.raises(ServiceError):
        MediaPaths(data_root).input("meeting", "linked.wav")

def test_output_cannot_replace_input_or_existing_file(data_root, wav):
    wav()
    with pytest.raises(ServiceError):
        MediaPaths(data_root).output("meeting", "input.wav")

def test_every_endpoint_requires_bearer_and_rejects_browser_origins(data_root):
    with TestClient(create_app(data_root, "a" * 32)) as c:
        for method, path in [("get", "/health"), ("post", "/transcribe"), ("post", "/prepare-audio"), ("post", "/diarize"), ("post", "/cancel"), ("post", "/unload")]:
            assert getattr(c, method)("/echo/v1" + path).status_code == 401
        headers = {"Authorization": "Bearer " + "a" * 32, "Origin": "http://localhost"}
        assert c.get("/echo/v1/health", headers=headers).status_code == 403
        headers.pop("Origin")
        response = c.get("/echo/v1/health", headers=headers)
        assert response.status_code == 200
        assert response.json()["capabilities"]["transcribe"] is False
        assert c.get("/docs", headers=headers).status_code == 404

def test_validation_never_echoes_user_payload(data_root):
    with TestClient(create_app(data_root, "a" * 32), headers={"Authorization": "Bearer " + "a" * 32}) as c:
        r = c.post("/echo/v1/transcribe", json={"meeting_id": "secret transcript"})
        assert r.status_code == 422
        assert "secret transcript" not in r.text
        assert r.json()["error"]["code"] == "invalid_request"

def test_chunked_request_is_rejected_before_body_is_read(data_root):
    with TestClient(create_app(data_root, "a" * 32), headers={"Authorization": "Bearer " + "a" * 32}) as client:
        response = client.post("/echo/v1/cancel", content=iter([b'{"job_id":"job"}']), headers={"Transfer-Encoding": "chunked"})
        assert response.status_code == 413
