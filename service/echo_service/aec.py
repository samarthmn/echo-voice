"""AEC3 framing and crash-replay journal; raw WAV inputs are read-only."""
import json
import os
from pathlib import Path
import uuid
import numpy as np
import soundfile as sf
from .audio import inspect_wav
from .errors import ServiceError
from .models import digest
from .paths import MediaPaths, atomic_json, identifier


class FrameProcessor:
    FRAME = 160

    def __init__(self, processor):
        self.processor = processor
        self.near = np.empty(0, dtype=np.int16)
        self.far = np.empty(0, dtype=np.int16)

    def process(self, near, far, *, final=False):
        if far is None or len(near) != len(far):
            raise ServiceError("unaligned_audio", "An aligned far-end reference is required.")
        self.near = np.concatenate((self.near, near))
        self.far = np.concatenate((self.far, far))
        output = []
        count = len(self.near) // self.FRAME * self.FRAME
        for i in range(0, count, self.FRAME):
            output.append(self.processor.process(self.near[i:i + self.FRAME], self.far[i:i + self.FRAME]))
        self.near, self.far = self.near[count:], self.far[count:]
        if final and len(self.near):
            remaining = len(self.near)
            output.append(self.processor.process(np.pad(self.near, (0, self.FRAME - remaining)), np.pad(self.far, (0, self.FRAME - remaining)))[:remaining])
            self.near = np.empty(0, dtype=np.int16)
            self.far = np.empty(0, dtype=np.int16)
        return np.concatenate(output) if output else np.empty(0, dtype=np.int16)


def new_processor():
    from pywebrtc_audio import AudioProcessor
    return FrameProcessor(AudioProcessor(sample_rate=16000, num_channels=1, echo_cancellation=True, noise_suppression=False, auto_gain_control=False, stream_delay_ms=0))


class AECSession:
    def __init__(self, root: Path, factory=new_processor):
        self.paths = MediaPaths(root)
        self.factory = factory
        self.current = None
        self.frames = None
        self.history = []

    def _inputs(self, request):
        near_path = self.paths.input(request["meeting_id"], request["near_path"])
        far_path = self.paths.input(request["meeting_id"], request["far_path"])
        near = inspect_wav(near_path, max_seconds=30, aligned=True, allow_empty=request["final"])
        far = inspect_wav(far_path, max_seconds=30, aligned=True, allow_empty=request["final"])
        if near.frames != far.frames:
            raise ServiceError("unaligned_audio", "Microphone and far-end WAV inputs must have equal frame counts.")
        return near_path, far_path

    def _process(self, request):
        near_path, far_path = self._inputs(request)
        if request["reset"]:
            self.frames = self.factory()
        near, _ = sf.read(near_path, dtype="int16")
        far, _ = sf.read(far_path, dtype="int16")
        return self.frames.process(near, far, final=request["final"])

    def finalized_input_signatures(self, request):
        meeting, epoch = request["meeting_id"], identifier(request["epoch_id"])
        journal = self.paths.resolve(meeting, "derived/.aec/" + epoch + ".json")
        receipt_path = self.paths.resolve(meeting, "derived/.aec/" + epoch + ".finalized.json")
        if not receipt_path.exists():
            return None
        try:
            receipt = json.loads(receipt_path.read_text())
            if not journal.is_file() or digest(journal) != receipt["journal_sha256"]:
                raise ValueError("journal mismatch")
            history = json.loads(journal.read_text())
            if not history or not history[-1]["request"]["final"]:
                raise ValueError("epoch has no final job")
            for entry in history:
                output = self.paths.output(meeting, entry["request"]["output_path"], allow_existing=True)
                if not output.is_file() or digest(output) != entry["output_sha256"]:
                    raise ValueError("cleaned output changed")
            for entry in history:
                if entry["request"]["job_id"] == request["job_id"]:
                    if entry["request"] != request:
                        raise ServiceError("job_conflict", "Job identifier was reused with different inputs.", 409)
                    return entry["inputs"]
            raise ServiceError("epoch_closed", "The AEC epoch is already finalized.", 409)
        except ServiceError:
            raise
        except (KeyError, ValueError, TypeError, json.JSONDecodeError) as error:
            raise ServiceError("finalized_receipt_invalid", "Finalized AEC receipt or cleaned audio is invalid.", 409) from error

    def prepare(self, request):
        meeting, epoch = request["meeting_id"], identifier(request["epoch_id"])
        journal = self.paths.meeting(meeting) / "derived" / ".aec" / (epoch + ".json")
        self.paths.resolve(meeting, "derived/.aec/" + epoch + ".json")
        signatures = self.finalized_input_signatures(request)
        if signatures is not None:
            for field, signature in signatures.items():
                path = self.paths.resolve(meeting, request[field])
                if path.exists() and digest(path) != signature:
                    raise ServiceError("input_changed", "An AEC replay input has changed.", 409)
            return next(item["result"] for item in json.loads(journal.read_text())
                        if item["request"]["job_id"] == request["job_id"])
        key = (meeting, epoch)
        if self.current != key:
            self.frames = self.factory()
            self.history = json.loads(journal.read_text()) if journal.exists() else []
            self.current = key
            # Replay canonical inputs in sequence to restore DSP adaptation and
            # the uncommitted partial frame. Never rewrite committed outputs.
            for previous in self.history:
                for field, signature in previous["inputs"].items():
                    if digest(self.paths.input(meeting, previous["request"][field])) != signature:
                        self.current = None
                        raise ServiceError("input_changed", "An AEC replay input has changed.", 409)
                self._process(previous["request"])
        for item in self.history:
            if item["request"]["job_id"] == request["job_id"]:
                if item["request"] != request:
                    raise ServiceError("job_conflict", "Job identifier was reused with different inputs.", 409)
                output = self.paths.output(meeting, request["output_path"], allow_existing=True)
                if not output.is_file() or digest(output) != item["output_sha256"]:
                    raise ServiceError("output_changed", "Committed derived audio is missing or changed.", 409)
                if request["final"]:
                    # Journal publication can survive a crash before the receipt.
                    # Verify every committed output before allowing replay inputs to retire.
                    self._publish_finalized_receipt(meeting, epoch, journal)
                return item["result"]
        expected = self.history[-1]["request"]["sequence"] + 1 if self.history else 0
        if request["sequence"] != expected:
            raise ServiceError("sequence_conflict", "AEC chunks must be submitted in contiguous sequence order.", 409)
        if self.history and self.history[-1]["request"]["final"]:
            raise ServiceError("epoch_closed", "The AEC epoch is already finalized.", 409)
        near, far = self._inputs(request)
        output = self.paths.output(meeting, request["output_path"], allow_existing=True)
        if output in (near, far):
            raise ServiceError("invalid_path", "Derived output cannot replace an input.")
        samples = self._process(request)
        temporary = output.with_name(output.name + "." + uuid.uuid4().hex + ".partial")
        try:
            with temporary.open("xb") as stream:
                os.chmod(temporary, 0o600)
                sf.write(stream, samples, 16000, subtype="PCM_16", format="WAV")
                stream.flush()
                os.fsync(stream.fileno())
            output_hash = digest(temporary)
            if output.exists():
                if digest(output) != output_hash:
                    self.current = None
                    raise ServiceError("output_exists", "Derived output already exists with different content.", 409)
            else:
                # link is exclusive and avoids replacing anything created concurrently.
                os.link(temporary, output)
            result = {"job_id": request["job_id"], "relative_path": request["output_path"], "sample_rate": 16000, "frame_count": len(samples)}
            entry = {"request": request, "result": result, "inputs": {"near_path": digest(near), "far_path": digest(far)}, "output_sha256": output_hash}
            atomic_json(journal, self.history + [entry])
            self.history.append(entry)
            if request["final"]:
                self._publish_finalized_receipt(meeting, epoch, journal)
            return result
        except BaseException:
            self.current = None
            raise
        finally:
            temporary.unlink(missing_ok=True)

    def _publish_finalized_receipt(self, meeting, epoch, journal):
        for entry in self.history:
            output = self.paths.output(meeting, entry["request"]["output_path"], allow_existing=True)
            if not output.is_file() or digest(output) != entry["output_sha256"]:
                raise ServiceError("output_changed", "Committed derived audio is missing or changed.", 409)
        receipt_path = self.paths.resolve(meeting, "derived/.aec/" + epoch + ".finalized.json")
        atomic_json(receipt_path, {"journal_sha256": digest(journal), "epoch_id": epoch,
                                  "jobs": [entry["request"]["job_id"] for entry in self.history]})
