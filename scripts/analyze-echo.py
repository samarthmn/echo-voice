#!/usr/bin/env python3
"""Read-only, bounded PCM measurements from one committed Echo Voice AEC epoch.

This measures near/clean energy attenuation, not proof that acoustic echo alone
was removed. The caller must establish a remote-only run independently.
"""
import argparse
import array
import hashlib
import json
import math
import os
from pathlib import Path
import re
import stat
import sys
import wave


RATE = 16000
FRAME = 160
BLOCK = 8192
MAX_SECONDS = 300
MAX_JOURNAL_BYTES = 8 * 1024 * 1024
IDENTIFIER = re.compile(r"[A-Za-z0-9][A-Za-z0-9_-]{0,127}\Z")
SHA256 = re.compile(r"[0-9a-f]{64}\Z")


class AnalysisFailure(Exception):
    def __init__(self, code, message):
        self.code, self.message = code, message
        super().__init__(message)


def require(condition, code, message):
    if not condition:
        raise AnalysisFailure(code, message)


def identifier(value):
    return isinstance(value, str) and IDENTIFIER.fullmatch(value) is not None


def integer(value):
    return type(value) is int and value >= 0


def no_symlinks(path):
    require(not any(part.is_symlink() for part in (path, *path.parents)),
            "unsafe_path", "Symbolic links are not allowed in the selected meeting.")


def regular(path):
    no_symlinks(path)
    info = path.stat()
    require(stat.S_ISREG(info.st_mode), "unsafe_path", "Analysis inputs must be regular files.")
    return (info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns, info.st_ctime_ns)


def relative_file(meeting, relative):
    require(isinstance(relative, str) and relative and "\\" not in relative and "\0" not in relative,
            "unsafe_path", "Journal paths must be relative meeting assets.")
    require(not relative.startswith("/") and all(part not in ("", ".", "..") for part in relative.split("/")),
            "unsafe_path", "Journal paths must stay inside the selected meeting.")
    path = meeting.joinpath(*relative.split("/"))
    require(path.suffix.lower() == ".wav", "invalid_audio", "Journal audio must be WAV files.")
    regular(path)
    return path


def audio_span(path, expected_hash, start, *, clean=False):
    require(isinstance(expected_hash, str) and SHA256.fullmatch(expected_hash),
            "invalid_journal", "A journal checksum is missing or invalid.")
    identity = regular(path)
    with wave.open(str(path), "rb") as audio:
        require(audio.getnchannels() == 1 and audio.getsampwidth() == 2 and audio.getframerate() == RATE
                and audio.getcomptype() == "NONE", "invalid_audio", "Analysis requires 16 kHz mono PCM16 WAV files.")
        count = audio.getnframes()
    limit = 30 * RATE + (FRAME if clean else 0)
    require(0 <= count <= limit, "invalid_audio", "An AEC chunk exceeds its expected size.")
    require(regular(path) == identity, "input_changed", "An input changed during inspection.")
    return {"path": path, "hash": expected_hash, "start": start, "end": start + count, "identity": identity}


def inspect_epoch(meeting, epoch):
    journal = meeting / "derived" / ".aec" / (epoch + ".json")
    identity = regular(journal)
    require(identity[2] <= MAX_JOURNAL_BYTES, "journal_too_large", "The selected AEC journal is too large.")
    history = json.loads(journal.read_text())
    require(isinstance(history, list) and 0 < len(history) <= 10000,
            "invalid_journal", "The selected AEC journal must contain bounded committed entries.")
    tracks = {"near": [], "far": [], "clean": []}
    totals = {name: 0 for name in tracks}
    jobs, outputs = set(), set()
    finalized = False
    for sequence, entry in enumerate(history):
        require(isinstance(entry, dict), "invalid_journal", "Invalid AEC journal entry.")
        request, result, inputs = entry.get("request"), entry.get("result"), entry.get("inputs")
        require(all(isinstance(value, dict) for value in (request, result, inputs)),
                "invalid_journal", "Invalid AEC journal entry fields.")
        require(not finalized and request.get("meeting_id") == meeting.name and request.get("epoch_id") == epoch
                and type(request.get("sequence")) is int and request["sequence"] == sequence,
                "invalid_sequence", "AEC entries must belong to one epoch in contiguous sequence order.")
        job = request.get("job_id")
        require(identifier(job) and job not in jobs and result.get("job_id") == job,
                "invalid_journal", "AEC job identifiers must be unique and match their results.")
        jobs.add(job)
        require(type(request.get("reset")) is bool and type(request.get("final")) is bool,
                "invalid_journal", "AEC reset/final flags must be explicit booleans.")
        require(sequence == 0 or not request["reset"], "mid_epoch_reset", "Select an epoch without an internal AEC reset.")
        finalized = request["final"]
        for name, field in (("near", "near_path"), ("far", "far_path"), ("clean", "output_path")):
            relative = request.get(field)
            if name == "clean":
                require(isinstance(relative, str) and relative.startswith("derived/") and relative not in outputs,
                        "invalid_journal", "Committed cleaned outputs must be unique derived assets.")
                outputs.add(relative)
                require(result.get("relative_path") == relative and result.get("sample_rate") == RATE,
                        "invalid_journal", "AEC output metadata does not match its request.")
            path = relative_file(meeting, relative)
            expected = entry.get("output_sha256") if name == "clean" else inputs.get(field)
            span = audio_span(path, expected, totals[name], clean=name == "clean")
            if name == "clean":
                require(integer(result.get("frame_count")) and result["frame_count"] == span["end"] - span["start"],
                        "invalid_audio", "Cleaned output frame count does not match the committed result.")
            tracks[name].append(span)
            totals[name] = span["end"]
        require(totals["near"] == totals["far"], "unaligned_audio", "Near/far chunk lengths do not match.")
        expected_clean = totals["near"] if finalized else totals["near"] // FRAME * FRAME
        require(totals["clean"] == expected_clean, "invalid_frame_accounting", "Cleaned frames do not match AEC remainder carry and finalization.")
    require(regular(journal) == identity, "input_changed", "The AEC journal changed during inspection.")
    return tracks, totals, finalized, (journal, identity)


def verify_span(span):
    require(regular(span["path"]) == span["identity"], "input_changed", "An audio input changed during analysis.")
    digest = hashlib.sha256()
    with span["path"].open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    require(digest.hexdigest() == span["hash"], "checksum_mismatch", "A selected audio file differs from its committed checksum.")
    require(regular(span["path"]) == span["identity"], "input_changed", "An audio input changed during verification.")


def measure(spans, start, end):
    count = squares = clipped = verified = 0
    for span in spans:
        first, last = max(start, span["start"]), min(end, span["end"])
        if first >= last:
            continue
        verify_span(span)
        verified += 1
        with wave.open(str(span["path"]), "rb") as audio:
            audio.setpos(first - span["start"])
            remaining = last - first
            while remaining:
                requested = min(BLOCK, remaining)
                raw = audio.readframes(requested)
                require(len(raw) == requested * 2, "truncated_audio", "A selected WAV does not contain its declared frames.")
                samples = array.array("h", raw)
                if sys.byteorder != "little":
                    samples.byteswap()
                squares += sum(sample * sample for sample in samples)
                clipped += sum(sample in (-32768, 32767) for sample in samples)
                count += requested
                remaining -= requested
        require(regular(span["path"]) == span["identity"], "input_changed", "An audio input changed while being measured.")
    require(count == end - start, "incomplete_coverage", "The selected audio interval is not fully represented by committed chunks.")
    rms = math.sqrt(squares / count) / 32768
    return {"sample_count": count, "rms": rms, "rms_dbfs": 20 * math.log10(rms) if rms else None,
            "clipped_sample_count": clipped, "clipped_fraction": clipped / count, "verified_chunk_count": verified}


def analyze(meeting_dir, epoch_id, *, run_mode, warmup_seconds, duration_seconds):
    require(run_mode == "remote-only", "run_mode_required", "Explicitly declare a remote-only user or fixture run.")
    require(identifier(epoch_id), "invalid_epoch", "Provide one valid AEC epoch identifier.")
    require(all(type(value) in (int, float) and math.isfinite(value) for value in (warmup_seconds, duration_seconds))
            and warmup_seconds >= 0 and math.isfinite(warmup_seconds * RATE) and 0 < duration_seconds <= MAX_SECONDS,
            "invalid_interval", "Warmup must be nonnegative and the measurement duration must be at most 300 seconds.")
    meeting = Path(meeting_dir).absolute()
    no_symlinks(meeting)
    require(meeting.is_dir() and meeting.parent.name == "meetings" and identifier(meeting.name),
            "invalid_meeting", "Provide an explicit app-managed meetings/<identifier> directory.")
    tracks, totals, finalized, journal = inspect_epoch(meeting, epoch_id)
    start = math.ceil(warmup_seconds * RATE)
    requested_count = math.floor(duration_seconds * RATE)
    end = min(start + requested_count, min(totals.values()))
    require(requested_count > 0 and end > start, "no_coverage", "No committed aligned audio remains in the requested interval after warmup.")
    measurements = {name: measure(spans, start, end) for name, spans in tracks.items()}
    require(regular(journal[0]) == journal[1], "input_changed", "The AEC journal changed during analysis; retry after it settles.")
    near, far, clean = (measurements[name]["rms"] for name in ("near", "far", "clean"))
    undefined = "far_silent" if not far else "near_silent" if not near else "clean_silent" if not clean else None
    reduction = 20 * math.log10(near / clean) if undefined is None else None
    return {
        "report_version": 1, "scope": {"meeting_id": meeting.name, "epoch_id": epoch_id},
        "run_mode": "remote-only", "run_mode_source": "caller_declaration_not_verified",
        "sample_rate": RATE, "epoch_finalized": finalized,
        "interval": {"warmup_seconds": warmup_seconds, "requested_duration_seconds": duration_seconds,
                     "start_frame": start, "end_frame": end, "measured_seconds": (end - start) / RATE},
        "coverage": {"requested_sample_count": requested_count, "measured_sample_count": end - start,
                     "fraction": (end - start) / requested_count, "complete": end - start == requested_count,
                     "epoch_input_frames": totals["near"], "epoch_clean_frames": totals["clean"],
                     "pending_tail_frames": totals["near"] - totals["clean"]},
        "measurements": measurements, "echo_reduction_db": reduction, "undefined_reduction_reason": undefined,
        "checksum_scope": "all complete files overlapping each track's measured interval; unselected audio payloads not hashed",
        "interpretation": "Near-to-clean RMS attenuation after the declared warmup. Noise, local speech, clipping, room changes, and AEC delay can affect this value; it does not isolate echo energy or establish acoustic quality.",
        "validation_gates": {"15db_echo_reduction": "not_evaluated", "double_talk": "not_evaluated", "physical_hardware": "not_evaluated"},
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--meeting-dir", type=Path, required=True)
    parser.add_argument("--epoch-id", required=True)
    parser.add_argument("--run-mode", choices=("remote-only",), required=True,
                        help="Caller confirmation that the selected interval is a remote-only test.")
    parser.add_argument("--warmup-seconds", type=float, required=True, help="Discard this many seconds from the start of the selected epoch.")
    parser.add_argument("--duration-seconds", type=float, required=True, help="Analyze up to this many seconds after warmup (maximum 300).")
    args = parser.parse_args()
    try:
        report = analyze(args.meeting_dir, args.epoch_id, run_mode=args.run_mode,
                         warmup_seconds=args.warmup_seconds, duration_seconds=args.duration_seconds)
        print(json.dumps(report, indent=2, allow_nan=False))
        return 0
    except AnalysisFailure as error:
        payload = {"error": {"code": error.code, "message": error.message}}
    except (OSError, ValueError, KeyError, TypeError, wave.Error, EOFError):
        payload = {"error": {"code": "unreadable_artifact", "message": "The selected committed AEC artifacts are missing, malformed, or unreadable."}}
    print(json.dumps(payload), file=sys.stderr)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
