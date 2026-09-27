import asyncio
import hashlib
import importlib.util
import json
from pathlib import Path
from .audio import inspect_wav
from .errors import ServiceError
from .models import ModelAssets, digest, source_path
from .paths import MediaPaths, atomic_json
from .supervisor import Worker


class SpeechService:
    def __init__(self, root: Path, *, worker_factory=Worker):
        self.root = root
        self.paths = MediaPaths(root)
        self.assets = ModelAssets(root)
        from .model_lifecycle import recover_removals, remove_model
        recover_removals(root)
        if (root / "models" / "vision").exists(): remove_model(root, "vision")
        self.asr = worker_factory("asr", root, timeout=300)
        self.aec = worker_factory("aec", root, timeout=600)
        self.diarization = worker_factory("diarization", root, timeout=6 * 3600)
        self.community = worker_factory("community1", root, timeout=6 * 3600)
        self.asr_model = None
        self.model_lock = asyncio.Lock()
        self.jobs = {}
        self.job_kinds = {}
        self.admitting = {}
        self.admission_generation = 0

    def health(self):
        models = self.assets.status()
        from .runtime_layout import community_environment
        runtime_receipt = community_environment(self.root) / ".echo-runtime.json"
        if not runtime_receipt.is_file(): models["community1"]["ready"] = False
        try:
            source_path(self.root)
            source_ready = True
        except ServiceError:
            source_ready = False
        speech_runtime = importlib.util.find_spec("silero_vad") is not None
        speech_models = {
            "whisper": speech_runtime and source_ready and models["asr"]["ready"] and importlib.util.find_spec("mlx_whisper") is not None,
            "parakeet": speech_runtime and models["parakeet"]["ready"] and importlib.util.find_spec("sherpa_onnx") is not None,
        }
        capabilities = {
            "transcribe": any(speech_models.values()),
            "prepare_audio": importlib.util.find_spec("pywebrtc_audio") is not None,
            "diarize": source_ready and all(models[n]["ready"] for n in ("diarization", "segmentation", "embedding")) and importlib.util.find_spec("torch") is not None,
        }
        return {"protocol": "echo.v1", "status": "ready", "capabilities": capabilities, "models": models, "speech_models": speech_models}

    def validate(self, kind, request):
        signatures = {}
        if kind == "aec":
            from .aec import AECSession
            finalized = AECSession(self.root).finalized_input_signatures(request)
            for name in ("near_path", "far_path"):
                if finalized is not None:
                    path = self.paths.resolve(request["meeting_id"], request[name])
                    if path.is_file() and digest(path) != finalized[name]:
                        raise ServiceError("input_changed", "An AEC replay input has changed.", 409)
                    signatures[name] = finalized[name]
                else:
                    path = self.paths.input(request["meeting_id"], request[name])
                    inspect_wav(path, aligned=True, max_seconds=30, allow_empty=request["final"])
                    signatures[name] = digest(path)
            self.paths.output(request["meeting_id"], request["output_path"], allow_existing=True)
        else:
            path = self.paths.input(request["meeting_id"], request["relative_path"])
            inspect_wav(path, max_seconds=30 if kind == "asr" else None, aligned=kind == "asr")
            signatures["relative_path"] = digest(path)
        canonical_request = dict(request)
        if kind == "asr" and canonical_request.get("model") == "whisper":
            canonical_request.pop("model")  # preserve legacy Whisper retry fingerprints
        if kind == "asr" and not canonical_request.get("configuration_id"):
            for field in ("transcript_version_id", "configuration_id", "vocabulary", "fuzzy_vocabulary"):
                if not canonical_request.get(field): canonical_request.pop(field, None)
        if kind == "diarization" and canonical_request.get("model") == "diarization":
            canonical_request.pop("model")
        identity = {"kind": kind, "request": canonical_request, "inputs": signatures}
        fingerprint = hashlib.sha256(json.dumps(identity, sort_keys=True, separators=(",", ":")).encode()).hexdigest()
        return fingerprint

    async def execute(self, kind, request):
        admission = self.admission_generation
        job_id = request["job_id"]
        token = {"cancelled": False}
        self.admitting.setdefault(job_id, []).append(token)
        try:
            fingerprint = await asyncio.to_thread(self.validate, kind, request)
            if token["cancelled"]:
                raise ServiceError("cancelled", "Processing was cancelled.", 409, True)
        finally:
            pending = self.admitting[job_id]
            pending[:] = [entry for entry in pending if entry is not token]
            if not pending:
                self.admitting.pop(job_id)
        if kind != "aec" and admission != self.admission_generation:
            raise ServiceError("cancelled", "Processing was unloaded.", 409, True)
        job_id = request["job_id"]
        if job_id in self.jobs:
            existing, task = self.jobs[job_id]
            if existing != fingerprint:
                raise ServiceError("job_conflict", "Job identifier was reused with different inputs.", 409)
            return await asyncio.shield(task)
        task = asyncio.create_task(self._execute(kind, request, fingerprint))
        self.jobs[job_id] = (fingerprint, task)
        self.job_kinds[job_id] = kind
        def finished(done):
            if self.jobs.get(job_id, (None, None))[1] is done:
                self.jobs.pop(job_id, None)
                self.job_kinds.pop(job_id, None)
            if not done.cancelled():
                done.exception()  # observe errors even if a client disconnected
        task.add_done_callback(finished)
        return await asyncio.shield(task)

    async def _execute(self, kind, request, fingerprint):
        receipt_path = self.paths.resolve(request["meeting_id"], "derived/.jobs/" + request["job_id"] + ".json")
        if receipt_path.exists():
            receipt = json.loads(await asyncio.to_thread(receipt_path.read_text))
            if receipt["fingerprint"] != fingerprint:
                raise ServiceError("job_conflict", "Job identifier was reused with different inputs.", 409)
            if kind != "aec":
                return receipt["result"]
            # AEC's own journal validates committed output and rebuilds the
            # epoch after a helper restart, even when the job receipt exists.
        if kind == "aec":
            result = await self.aec.run(request)
        else:
            if kind == "asr":
                # Live recording takes priority over post-meeting analysis.
                self.diarization.terminate(); self.community.terminate()
            async with self.model_lock:
                if kind == "asr":
                    model = request.get("model", "whisper")
                    if model not in ("whisper", "parakeet"):
                        raise ServiceError("invalid_model", "Choose an installed speech recognition model.", 400)
                    await asyncio.to_thread(self.assets.require, "parakeet" if model == "parakeet" else "asr")
                    if model == "whisper":
                        source_path(self.root)
                    if self.asr_model != model:
                        self.asr.terminate()
                        self.asr_model = model
                    result = await self.asr.run(request)
                else:
                    self.asr.terminate()
                    selected = request.get("model", "diarization")
                    from .model_lifecycle import selected_assets
                    for name in selected_assets(selected):
                        await asyncio.to_thread(self.assets.require, name)
                    if selected == "diarization": source_path(self.root)
                    worker = self.community if selected == "community1" else self.diarization
                    try:
                        result = await worker.run(request)
                    finally:
                        worker.terminate()
        await asyncio.to_thread(atomic_json, receipt_path, {"fingerprint": fingerprint, "result": result})
        return result

    def cancel(self, job_id):
        pending = self.admitting.get(job_id, [])
        for token in pending:
            token["cancelled"] = True
        item = self.jobs.get(job_id)
        if item is None or item[1].done():
            return bool(pending)
        item[1].cancel()
        for worker in (self.asr, self.aec, self.diarization, self.community):
            if worker.active_job == job_id:
                worker.terminate()
        return True

    def unload(self):
        self.admission_generation += 1
        for job_id, (_, task) in list(self.jobs.items()):
            if self.job_kinds.get(job_id) != "aec":
                task.cancel()
        self.asr.terminate()
        self.diarization.terminate(); self.community.terminate()

    async def close(self):
        tasks = [task for _, task in self.jobs.values()]
        for task in tasks:
            task.cancel()
        await asyncio.gather(*tasks, return_exceptions=True)
        for worker in (self.asr, self.aec, self.diarization, self.community):
            worker.terminate()
        self.jobs.clear()
        self.job_kinds.clear()
