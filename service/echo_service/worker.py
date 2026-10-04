"""Spawn entry point. Model logs never reach helper stdout or meeting logs."""
import logging
import os
import signal
import threading
import time
from pathlib import Path
from .environment import configure
from .errors import ServiceError


def worker_main(kind, root_string, connection):
    if kind == "community1":
        from .runtime_layout import activate_worker_environment
        activate_worker_environment()
    def terminate_cleanly(signum, frame):
        # Let multiprocessing finalizers unlink library-created semaphores.
        # The supervisor still escalates to kill if native inference is stuck.
        raise SystemExit(0)
    signal.signal(signal.SIGTERM, terminate_cleanly)
    helper_pid = os.getppid()
    def stop_if_orphaned():
        while True:
            time.sleep(1)
            if os.getppid() != helper_pid:
                os._exit(0)
    threading.Thread(target=stop_if_orphaned, daemon=True).start()
    root = Path(root_string)
    configure(root)
    import sys
    def deny_network(event, args):
        if event in ("socket.connect", "socket.getaddrinfo"):
            raise ServiceError("offline_only", "Inference cannot access the network.", 503)
    sys.addaudithook(deny_network)
    logging.disable(logging.CRITICAL)
    with open(os.devnull, "w") as quiet:
        os.dup2(quiet.fileno(), 1)
        os.dup2(quiet.fileno(), 2)
    from .paths import MediaPaths
    paths = MediaPaths(root)
    adapter = None
    while True:
        try:
            request = connection.recv()
        except EOFError:
            return
        try:
            if kind == "aec":
                from .aec import AECSession
                adapter = adapter or AECSession(root)
                result = adapter.prepare(request)
            elif kind == "asr":
                from .adapters import WhisperAdapter, ParakeetAdapter
                adapter = adapter or (ParakeetAdapter(root) if request.get("model", "whisper") == "parakeet" else WhisperAdapter(root))
                options = {"vocabulary": request.get("vocabulary", []), "fuzzy": request.get("fuzzy_vocabulary", False)} if request.get("vocabulary") or request.get("fuzzy_vocabulary") else {}
                result = adapter.transcribe(paths.input(request["meeting_id"], request["relative_path"]), **options)
            elif kind == "community1":
                from .community import CommunityAdapter
                adapter = adapter or CommunityAdapter(root)
                result = adapter.diarize(paths.input(request["meeting_id"], request["relative_path"]), request["window_seconds"])
            elif kind == "diarization":
                from .adapters import DiarizationAdapter
                adapter = adapter or DiarizationAdapter(root)
                result = adapter.diarize(paths.input(request["meeting_id"], request["relative_path"]), request["window_seconds"])
            else:
                raise RuntimeError("invalid worker")
            connection.send({"job_id": request["job_id"], **result})
        except SystemExit:
            return
        except ServiceError as error:
            connection.send({"error": {**error.payload()["error"], "status": error.status}})
        except BaseException:
            connection.send({"error": {"code": "processing_failed", "message": "Local inference failed. Raw recordings are preserved.", "status": 500, "retryable": True}})
