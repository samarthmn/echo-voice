import json
import os
from pathlib import Path
import selectors
import subprocess
import sys
import time
import httpx


def launch(data_root, **env):
    process = subprocess.Popen([sys.executable, "-m", "echo_service", "serve", "--port", "0"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env={**os.environ, "ECHO_DATA_ROOT": str(data_root), **env})
    process.stdin.write(json.dumps({"token": "test-secret-token" * 3}) + "\n")
    process.stdin.close()
    selector = selectors.DefaultSelector()
    selector.register(process.stdout, selectors.EVENT_READ)
    try:
        assert selector.select(10), "helper did not report its bound port"
        line = process.stdout.readline()
        startup = json.loads(line)
        assert set(startup) == {"port", "protocol"}
        assert startup["protocol"] == "echo.v1"
        return process, startup["port"]
    finally:
        selector.close()


def test_cli_binds_loopback_port_zero_and_serves_authenticated_health(data_root):
    process, port = launch(data_root)
    try:
        with httpx.Client(base_url=f"http://127.0.0.1:{port}") as client:
            for _ in range(30):
                try:
                    assert client.get("/echo/v1/health").status_code == 401
                    break
                except httpx.TransportError:
                    time.sleep(0.05)
            result = client.get("/echo/v1/health", headers={"Authorization": "Bearer " + "test-secret-token" * 3})
            assert result.status_code == 200
            assert result.json()["capabilities"]["transcribe"] is False
    finally:
        process.terminate()
        process.wait(timeout=10)
        assert "test-secret-token" not in process.stderr.read()
        assert process.stdout.read() == ""


def test_helper_exits_when_parent_is_gone(data_root):
    process, _ = launch(data_root, ECHO_PARENT_PID="99999999")
    try:
        assert process.wait(timeout=8) == 0
    finally:
        if process.poll() is None:
            process.kill()
            process.wait()


def test_worker_exits_if_helper_is_killed(data_root, wav):
    import psutil
    wav("near0.wav", frames=160)
    wav("far0.wav", frames=160)
    from test_aec_recovery import request
    # This helper harness exposes its child's PID only to the test; production
    # HTTP responses intentionally contain no process or private path details.
    script = data_root / "helper_harness.py"
    script.write_text("""
import asyncio, json, os, sys
from pathlib import Path
from echo_service.supervisor import Worker
async def run():
    worker = Worker('aec', Path(os.environ['ECHO_DATA_ROOT']))
    await worker.run(json.loads(sys.argv[1]))
    print(worker.process.pid, flush=True)
    await asyncio.sleep(30)
if __name__ == '__main__':
    asyncio.run(run())
""")
    process = subprocess.Popen([sys.executable, str(script), json.dumps(request(0))], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env={**os.environ, "ECHO_DATA_ROOT": str(data_root)})
    child = None
    try:
        selector = selectors.DefaultSelector()
        selector.register(process.stdout, selectors.EVENT_READ)
        try:
            assert selector.select(10)
            child = psutil.Process(int(process.stdout.readline()))
        finally:
            selector.close()
        process.kill()
        process.wait(timeout=5)
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            if not child.is_running() or child.status() == psutil.STATUS_ZOMBIE:
                break
            time.sleep(0.05)
        assert not child.is_running() or child.status() == psutil.STATUS_ZOMBIE
    finally:
        if process.poll() is None:
            process.kill()
            process.wait()
        if child is not None and child.is_running():
            try:
                child.kill()
            except psutil.NoSuchProcess:
                pass


def test_normal_model_unload_cleans_multiprocessing_semaphores(data_root, wav):
    wav()
    script = data_root / "semaphore_harness.py"
    script.write_text("""
import asyncio, multiprocessing, os
from pathlib import Path
from echo_service.supervisor import Worker

def target(kind, root, connection):
    import echo_service.adapters as adapters
    from echo_service.worker import worker_main
    class ModelWithSemaphore:
        def __init__(self, root):
            self.lock = multiprocessing.get_context('spawn').Semaphore(1)
        def transcribe(self, path):
            return {'segments': [], 'language': 'en', 'engine': 'test'}
    adapters.WhisperAdapter = ModelWithSemaphore
    worker_main(kind, root, connection)

async def run():
    worker = Worker('asr', Path(os.environ['ECHO_DATA_ROOT']), target=target)
    await worker.run({'job_id':'semaphore', 'meeting_id':'meeting', 'relative_path':'input.wav'})
    worker.terminate()
if __name__ == '__main__':
    asyncio.run(run())
""")
    result = subprocess.run([sys.executable, str(script)], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, timeout=15, env={**os.environ, "ECHO_DATA_ROOT": str(data_root)})
    assert result.returncode == 0
    assert "leaked semaphore" not in result.stderr


def test_intentional_sigint_exits_cleanly_without_startup_failure(data_root):
    import signal
    process, port = launch(data_root)
    try:
        with httpx.Client(base_url=f"http://127.0.0.1:{port}") as client:
            for _ in range(30):
                try:
                    assert client.get("/echo/v1/health").status_code == 401
                    break
                except httpx.TransportError:
                    time.sleep(0.05)
        process.send_signal(signal.SIGINT)
        assert process.wait(timeout=10) == 0
        assert "startup_failed" not in process.stderr.read()
    finally:
        if process.poll() is None:
            process.kill()
            process.wait()
