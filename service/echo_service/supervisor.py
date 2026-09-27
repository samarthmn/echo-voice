"""One disposable process per inference family with cancellation and RSS limits."""
import asyncio
import multiprocessing as mp
from pathlib import Path
import time
import sys
import psutil
from .errors import ServiceError


class Worker:
    def __init__(self, kind: str, root: Path, *, target=None, timeout=900, memory_limit=12 * 1024**3):
        self.kind, self.root = kind, root
        self.target = target
        self.timeout, self.memory_limit = timeout, memory_limit
        self.process = None
        self.connection = None
        self.lock = asyncio.Lock()
        self.active_job = None
        self.generation = 0

    def start(self):
        from .worker import worker_main
        context = mp.get_context("spawn")
        parent, child = context.Pipe()
        process = context.Process(target=self.target or worker_main, args=(self.kind, str(self.root), child), daemon=True)
        if self.kind == "community1":
            from .runtime_layout import community_python
            executable = community_python(self.root)
            if not executable.is_file(): raise ServiceError("model_unavailable", "Install the Community-1 runtime in model setup.", 503)
            # Spawn consumes this synchronously; reset before another task can launch.
            mp.set_executable(str(executable))
            try: process.start()
            finally: mp.set_executable(sys.executable)
        else:
            process.start()
        child.close()
        self.process, self.connection = process, parent

    def terminate(self):
        self.generation += 1
        process, self.process = self.process, None
        connection, self.connection = self.connection, None
        if process is not None:
            if process.is_alive():
                process.terminate()
                process.join(timeout=1)
            if process.is_alive():
                process.kill()
                process.join(timeout=1)
            process.close()
        if connection is not None:
            connection.close()

    async def run(self, request):
        async with self.lock:
            self.active_job = request["job_id"]
            if self.process is None:
                self.start()
            generation = self.generation
            process, connection = self.process, self.connection
            deadline = time.monotonic() + self.timeout
            try:
                connection.send(request)
                while True:
                    if generation != self.generation:
                        raise ServiceError("cancelled", "Processing was cancelled.", 409, True)
                    if connection.poll():
                        result = connection.recv()
                        if "error" in result:
                            error = result["error"]
                            raise ServiceError(error["code"], error["message"], error.get("status", 500), error.get("retryable", True))
                        return result
                    if not process.is_alive():
                        raise ServiceError("worker_failed", "The inference worker stopped unexpectedly.", 503, True)
                    try:
                        memory = psutil.Process(process.pid).memory_info().rss
                        if memory > self.memory_limit:
                            raise ServiceError("memory_limit", "Inference exceeded its memory budget. Try a shorter diarization window.", 503, True)
                    except psutil.NoSuchProcess:
                        raise ServiceError("worker_failed", "The inference worker stopped unexpectedly.", 503, True) from None
                    if time.monotonic() > deadline:
                        raise ServiceError("worker_timeout", "Inference exceeded its time limit.", 503, True)
                    await asyncio.sleep(0.025)
            except asyncio.CancelledError:
                self.terminate()
                raise
            except (EOFError, OSError, BrokenPipeError):
                self.terminate()
                raise ServiceError("worker_failed", "The inference worker stopped unexpectedly.", 503, True) from None
            except ServiceError:
                self.terminate()
                raise
            finally:
                self.active_job = None
