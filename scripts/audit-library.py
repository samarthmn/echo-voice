#!/usr/bin/env python3
"""Read-only, content-free validation measurements for one Echo Voice meeting."""

import argparse
from collections import Counter, defaultdict
import hashlib
import json
import math
import os
from pathlib import Path
import re
import sqlite3
import stat
import sys
from urllib.parse import quote


REPORT_VERSION = 1
IDENTIFIER = re.compile(r"[A-Za-z0-9][A-Za-z0-9_-]{0,127}\Z")
TRACKS = {"microphone", "remote", "cleanMicrophone"}
RAW_TRACKS = {"microphone", "remote"}
MEETING_STATES = {"recording", "paused", "interrupted", "finalizing", "ready", "failed"}
JOB_STATUSES = {"pending", "running", "completed", "failed", "cancelled"}
TIMELINE_TOLERANCE_SECONDS = 0.001
RAW_HOST_DRIFT_LIMIT_SECONDS = 0.05
DRIFT_REPORTING_EPSILON_SECONDS = 1e-9
MAX_ISSUE_DETAILS = 200
REQUIRED_TABLES = {
    "meetings",
    "chunks",
    "capture_gaps",
    "transcript_segments",
    "screenshots",
    "meeting_notes",
    "processing_jobs",
}


class InputFailure(Exception):
    def __init__(self, code, message):
        super().__init__(message)
        self.code = code
        self.message = message


def finite_number(value):
    return isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(float(value))


def seconds(value):
    return round(float(value), 6)


def safe_identifier(value):
    return isinstance(value, str) and IDENTIFIER.fullmatch(value) is not None


def record_reference(value, ordinal):
    return value if safe_identifier(value) else "row-{}".format(ordinal)


class Auditor:
    def __init__(self, root, meeting_id):
        self.root = root
        self.meeting_id = meeting_id
        self.issue_counts = Counter()
        self.issue_details = []
        self.hidden_issue_detail_count = 0
        self.report = {
            "report_version": REPORT_VERSION,
            "scope": {"meeting_id": meeting_id},
            "database": {},
            "measurements": {},
            "unresolved_issue_counts": {},
            "unresolved_issues": [],
            "validation_gates": {
                "library_audit": "not_evaluated",
                "physical_hardware": "not_evaluated",
                "eight_hour_endurance": "not_evaluated",
            },
        }

    def issue(self, code, message, *, occurrences=1, **metadata):
        self.issue_counts[code] += occurrences
        detail = {"code": code, "message": message}
        detail.update(metadata)
        if occurrences != 1:
            detail["occurrences"] = occurrences
        if len(self.issue_details) < MAX_ISSUE_DETAILS:
            self.issue_details.append(detail)
        else:
            self.hidden_issue_detail_count += occurrences

    def run(self):
        database_path = self.root / "echo.sqlite"
        try:
            database_stat = database_path.lstat()
        except FileNotFoundError as error:
            raise InputFailure("database_missing", "The data root does not contain echo.sqlite.") from error
        if stat.S_ISLNK(database_stat.st_mode) or not stat.S_ISREG(database_stat.st_mode):
            raise InputFailure("database_unsafe", "echo.sqlite must be a regular file inside the data root.")

        uri = "file:{}?mode=ro".format(quote(str(database_path), safe="/"))
        connection = sqlite3.connect(uri, uri=True, timeout=5.0)
        connection.row_factory = sqlite3.Row
        try:
            connection.execute("PRAGMA query_only = ON")
            self.audit_schema(connection)
            self.audit_database(connection)
            meeting = connection.execute(
                "SELECT started_at, ended_at, state FROM meetings WHERE id = ?",
                (self.meeting_id,),
            ).fetchone()
            if meeting is None:
                raise InputFailure("meeting_not_found", "The selected meeting is not present in the database.")
            self.audit_meeting(meeting)
            gaps = self.audit_capture_gaps(connection)
            self.audit_audio(connection, gaps)
            self.audit_jobs(connection)
            self.audit_evidence(connection)
            self.audit_screenshots(connection)
            self.finalize()
            return self.report
        finally:
            connection.close()

    def audit_schema(self, connection):
        rows = connection.execute("SELECT name FROM sqlite_schema WHERE type = 'table'").fetchall()
        available = {row["name"] for row in rows}
        missing = sorted(REQUIRED_TABLES - available)
        if missing:
            raise InputFailure("unsupported_schema", "The database is missing required Echo Voice tables.")

    def audit_database(self, connection):
        integrity_rows = list(connection.execute("PRAGMA integrity_check"))
        integrity_ok = len(integrity_rows) == 1 and integrity_rows[0][0] == "ok"
        foreign_key_count = sum(1 for _ in connection.execute("PRAGMA foreign_key_check"))
        self.report["database"] = {
            "open_mode": "read_only",
            "integrity_ok": integrity_ok,
            "foreign_key_violation_count": foreign_key_count,
        }
        if not integrity_ok:
            self.issue("database_integrity_failed", "SQLite integrity_check did not return ok.")
        if foreign_key_count:
            self.issue(
                "foreign_key_violations",
                "SQLite reported foreign-key violations; row identifiers are intentionally omitted.",
                occurrences=foreign_key_count,
            )

    def audit_meeting(self, meeting):
        started = meeting["started_at"]
        ended = meeting["ended_at"]
        state = meeting["state"] if meeting["state"] in MEETING_STATES else "invalid"
        duration = None
        if finite_number(started) and finite_number(ended) and float(ended) >= float(started):
            duration = seconds(float(ended) - float(started))
        elif ended is not None:
            self.issue("meeting_timeline_invalid", "The meeting start/end timestamps are invalid.")
        self.report["measurements"]["meeting"] = {
            "state": state,
            "wall_duration_seconds": duration,
        }
        if state != "ready" or ended is None:
            self.issue("meeting_not_finalized", "The selected meeting is not in a completed ready state.")

    def audit_capture_gaps(self, connection):
        rows = connection.execute(
            "SELECT start_time, end_time FROM capture_gaps WHERE meeting_id = ? ORDER BY start_time, id",
            (self.meeting_id,),
        ).fetchall()
        gaps = []
        open_ended = 0
        invalid = 0
        for row in rows:
            start = row["start_time"]
            end = row["end_time"]
            if not finite_number(start) or float(start) < 0 or (end is not None and (not finite_number(end) or float(end) < float(start))):
                invalid += 1
                self.issue("capture_gap_invalid", "A persisted capture-gap interval is invalid.")
                continue
            start = float(start)
            end = None if end is None else float(end)
            if end is None:
                open_ended += 1
            gaps.append((start, end))
        self.report["measurements"]["capture_gaps"] = {
            "persisted_count": len(rows),
            "valid_count": len(gaps),
            "invalid_count": invalid,
            "open_ended_count": open_ended,
        }
        return gaps

    def audit_audio(self, connection, capture_gaps):
        rows = connection.execute(
            """
            SELECT id, epoch_id, track, relative_path, start_time, duration,
                   sample_rate, frame_count, sha256
            FROM chunks
            WHERE meeting_id = ?
            ORDER BY track, epoch_id, start_time, id
            """,
            (self.meeting_id,),
        ).fetchall()
        counters = Counter()
        referenced_bytes = 0
        grouped = defaultdict(list)
        for ordinal, row in enumerate(rows, 1):
            reference = record_reference(row["id"], ordinal)
            asset_status, asset_path, asset_size = self.inspect_asset(row["relative_path"])
            if asset_status == "ok":
                referenced_bytes += asset_size
                actual = self.sha256(asset_path)
                expected = row["sha256"]
                if isinstance(expected, str) and len(expected) == 64 and actual.lower() == expected.lower():
                    counters["checksum_verified_count"] += 1
                else:
                    counters["checksum_mismatch_count"] += 1
                    self.issue(
                        "audio_checksum_mismatch",
                        "A committed audio file does not match its recorded checksum.",
                        record=reference,
                    )
            elif asset_status == "missing":
                counters["missing_count"] += 1
                self.issue("audio_asset_missing", "A committed audio file is missing.", record=reference)
            else:
                counters["unsafe_count"] += 1
                self.issue("audio_asset_unsafe", "A committed audio path is unsafe or is not a regular file.", record=reference)

            metadata_valid = (
                row["track"] in TRACKS
                and safe_identifier(row["epoch_id"])
                and finite_number(row["start_time"])
                and finite_number(row["duration"])
                and finite_number(row["sample_rate"])
                and isinstance(row["frame_count"], int)
                and float(row["start_time"]) >= 0
                and float(row["duration"]) > 0
                and float(row["sample_rate"]) > 0
                and row["frame_count"] > 0
            )
            if not metadata_valid:
                counters["invalid_metadata_count"] += 1
                self.issue("audio_metadata_invalid", "A committed audio row has invalid timing or format metadata.", record=reference)
                continue
            duration_from_frames = row["frame_count"] / float(row["sample_rate"])
            metadata_tolerance = max(TIMELINE_TOLERANCE_SECONDS, 1.0 / float(row["sample_rate"]))
            if abs(duration_from_frames - float(row["duration"])) > metadata_tolerance:
                counters["duration_mismatch_count"] += 1
                self.issue("audio_duration_mismatch", "Audio frame count and recorded duration disagree.", record=reference)
            grouped[(row["track"], row["epoch_id"])].append(row)

        timelines = []
        for (track, epoch), chunks in sorted(grouped.items()):
            timelines.append(self.timeline_measurement(track, epoch, chunks, capture_gaps))

        if not rows:
            self.issue("no_committed_audio", "The selected meeting has no committed audio chunks.")
        self.report["measurements"]["audio"] = {
            "committed_chunk_count": len(rows),
            "referenced_bytes": referenced_bytes,
            "checksum_verified_count": counters["checksum_verified_count"],
            "checksum_mismatch_count": counters["checksum_mismatch_count"],
            "missing_count": counters["missing_count"],
            "unsafe_count": counters["unsafe_count"],
            "invalid_metadata_count": counters["invalid_metadata_count"],
            "duration_mismatch_count": counters["duration_mismatch_count"],
            "timelines": timelines,
        }

    def timeline_measurement(self, track, epoch, chunks, capture_gaps):
        disclosed = 0
        undisclosed = 0
        overlaps = 0
        gap_seconds = 0.0
        overlap_seconds = 0.0
        corrected_drift = []
        for previous, current in zip(chunks, chunks[1:]):
            previous_end = float(previous["start_time"]) + float(previous["duration"])
            current_start = float(current["start_time"])
            delta = current_start - previous_end
            spacing = current_start - float(previous["start_time"])
            if (
                track in RAW_TRACKS
                and spacing > 0
                and float(current["duration"]) > 0
                and abs(delta) <= RAW_HOST_DRIFT_LIMIT_SECONDS
            ):
                if abs(delta) > DRIFT_REPORTING_EPSILON_SECONDS:
                    corrected_drift.append(delta)
                continue

            if track == "cleanMicrophone":
                tolerance = min(
                    TIMELINE_TOLERANCE_SECONDS,
                    max(1.0 / float(previous["sample_rate"]), 1.0 / float(current["sample_rate"])),
                )
            else:
                # Raw intervals only reach this branch when they cannot be
                # corrected by the same policy used by AudioWindowAssembler.
                tolerance = 0.0

            if delta > tolerance:
                gap_seconds += delta
                if self.disclosed(previous_end, current_start, capture_gaps):
                    disclosed += 1
                else:
                    undisclosed += 1
                    self.issue(
                        "timeline_gap_undisclosed",
                        "An audio timeline gap has no overlapping persisted capture-gap record.",
                        track=track,
                        epoch_id=epoch,
                        start_seconds=seconds(previous_end),
                        end_seconds=seconds(current_start),
                    )
            elif delta < -tolerance:
                overlaps += 1
                overlap_seconds += -delta
                self.issue(
                    "timeline_overlap",
                    "Committed audio chunks overlap within one track and epoch.",
                    track=track,
                    epoch_id=epoch,
                    start_seconds=seconds(current_start),
                    previous_end_seconds=seconds(previous_end),
                )
        start = float(chunks[0]["start_time"])
        end = max(float(row["start_time"]) + float(row["duration"]) for row in chunks)
        corrected_net = sum(corrected_drift)
        return {
            "track": track,
            "epoch_id": epoch,
            "chunk_count": len(chunks),
            "start_seconds": seconds(start),
            "end_seconds": seconds(end),
            "recorded_duration_seconds": seconds(sum(float(row["duration"]) for row in chunks)),
            "disclosed_gap_count": disclosed,
            "undisclosed_gap_count": undisclosed,
            "overlap_count": overlaps,
            "gap_seconds": seconds(gap_seconds),
            "overlap_seconds": seconds(overlap_seconds),
            "corrected_drift_count": len(corrected_drift),
            "corrected_stretch_count": sum(1 for drift in corrected_drift if drift > 0),
            "corrected_compression_count": sum(1 for drift in corrected_drift if drift < 0),
            "corrected_drift_net_seconds": seconds(corrected_net),
            "corrected_drift_absolute_seconds": seconds(sum(abs(drift) for drift in corrected_drift)),
            "host_corrected_duration_seconds": seconds(sum(float(row["duration"]) for row in chunks) + corrected_net),
        }

    @staticmethod
    def disclosed(start, end, capture_gaps):
        covered_until = start
        for gap_start, gap_end in sorted(capture_gaps, key=lambda gap: gap[0]):
            if gap_end is not None and gap_end < covered_until - TIMELINE_TOLERANCE_SECONDS:
                continue
            if gap_start > covered_until + TIMELINE_TOLERANCE_SECONDS:
                return False
            if gap_end is None:
                return True
            covered_until = max(covered_until, gap_end)
            if covered_until >= end - TIMELINE_TOLERANCE_SECONDS:
                return True
        return covered_until >= end - TIMELINE_TOLERANCE_SECONDS

    def audit_jobs(self, connection):
        counts = {status: 0 for status in sorted(JOB_STATUSES)}
        unknown = 0
        total = 0
        for row in connection.execute(
            "SELECT status, COUNT(*) AS count FROM processing_jobs WHERE meeting_id = ? GROUP BY status",
            (self.meeting_id,),
        ):
            count = int(row["count"])
            total += count
            if row["status"] in counts:
                counts[row["status"]] = count
            else:
                unknown += count
        measurements = {"total": total, **counts, "unknown_status": unknown}
        self.report["measurements"]["jobs"] = measurements
        if counts["pending"]:
            self.issue("pending_jobs_remaining", "Processing jobs remain pending.", occurrences=counts["pending"])
        if counts["running"]:
            self.issue("running_jobs_remaining", "Processing jobs remain marked running.", occurrences=counts["running"])
        if counts["failed"]:
            self.issue("failed_jobs_remaining", "Processing jobs remain failed.", occurrences=counts["failed"])
        if unknown:
            self.issue("unknown_job_status", "Processing jobs contain an unknown status.", occurrences=unknown)

    def audit_evidence(self, connection):
        segment_ids = {
            row["id"]
            for row in connection.execute("SELECT id FROM transcript_segments WHERE meeting_id = ?", (self.meeting_id,))
        }
        screenshot_ids = {
            row["id"]
            for row in connection.execute("SELECT id FROM screenshots WHERE meeting_id = ?", (self.meeting_id,))
        }
        allowed = segment_ids | screenshot_ids
        reference_count = 0
        resolved_count = 0
        unresolved_count = 0
        malformed_item_count = 0
        item_count = 0
        notes = connection.execute(
            "SELECT summary_json, decisions_json, action_items_json FROM meeting_notes WHERE meeting_id = ? ORDER BY created_at, id",
            (self.meeting_id,),
        ).fetchall()
        for note_index, note in enumerate(notes, 1):
            for column in ("summary_json", "decisions_json", "action_items_json"):
                try:
                    items = json.loads(note[column])
                except (TypeError, ValueError, UnicodeDecodeError):
                    items = None
                if not isinstance(items, list):
                    malformed_item_count += 1
                    self.issue("evidence_json_invalid", "A note evidence collection is not valid JSON.", note_index=note_index)
                    continue
                for item in items:
                    item_count += 1
                    if not isinstance(item, dict) or not isinstance(item.get("evidenceIDs"), list):
                        malformed_item_count += 1
                        self.issue("evidence_item_invalid", "A note item has invalid evidence metadata.", note_index=note_index)
                        continue
                    references = item["evidenceIDs"]
                    if not references:
                        self.issue("evidence_item_unreferenced", "A note item has no evidence references.", note_index=note_index)
                    for reference in references:
                        reference_count += 1
                        if isinstance(reference, str) and reference in allowed:
                            resolved_count += 1
                        else:
                            unresolved_count += 1
                            self.issue("evidence_reference_unresolved", "A note evidence reference does not resolve in the selected meeting.", note_index=note_index)
        self.report["measurements"]["evidence"] = {
            "note_version_count": len(notes),
            "note_item_count": item_count,
            "reference_count": reference_count,
            "resolved_reference_count": resolved_count,
            "unresolved_reference_count": unresolved_count,
            "malformed_item_count": malformed_item_count,
            "transcript_segment_count": len(segment_ids),
        }

    def audit_screenshots(self, connection):
        rows = connection.execute(
            "SELECT id, relative_path FROM screenshots WHERE meeting_id = ? ORDER BY captured_at, id",
            (self.meeting_id,),
        ).fetchall()
        retained = 0
        missing = 0
        unsafe = 0
        referenced_bytes = 0
        for ordinal, row in enumerate(rows, 1):
            reference = record_reference(row["id"], ordinal)
            asset_status, _, asset_size = self.inspect_asset(row["relative_path"])
            if asset_status == "ok":
                retained += 1
                referenced_bytes += asset_size
            elif asset_status == "missing":
                missing += 1
                self.issue("screenshot_missing", "A retained screenshot record has no file.", record=reference)
            else:
                unsafe += 1
                self.issue("screenshot_unsafe", "A retained screenshot path is unsafe or is not a regular file.", record=reference)
        self.report["measurements"]["screenshots"] = {
            "record_count": len(rows),
            "retained_count": retained,
            "missing_count": missing,
            "unsafe_count": unsafe,
            "referenced_bytes": referenced_bytes,
        }

    def inspect_asset(self, relative_path):
        if not isinstance(relative_path, str) or not relative_path or relative_path.startswith(("/", "~")) or "\\" in relative_path or "\x00" in relative_path:
            return "unsafe", None, 0
        parts = relative_path.split("/")
        if any(part in ("", ".", "..") for part in parts):
            return "unsafe", None, 0
        meetings_directory = self.root / "meetings"
        meeting_directory = meetings_directory / self.meeting_id
        try:
            meetings_stat = meetings_directory.lstat()
            meeting_stat = meeting_directory.lstat()
        except FileNotFoundError:
            return "missing", None, 0
        if (
            stat.S_ISLNK(meetings_stat.st_mode)
            or not stat.S_ISDIR(meetings_stat.st_mode)
            or stat.S_ISLNK(meeting_stat.st_mode)
            or not stat.S_ISDIR(meeting_stat.st_mode)
        ):
            return "unsafe", None, 0
        base = meeting_directory.resolve(strict=True)
        try:
            base.relative_to(meetings_directory.resolve(strict=True))
        except ValueError:
            return "unsafe", None, 0
        current = meeting_directory
        for index, part in enumerate(parts):
            current = current / part
            try:
                current_stat = current.lstat()
            except FileNotFoundError:
                return "missing", None, 0
            if stat.S_ISLNK(current_stat.st_mode):
                return "unsafe", None, 0
            if index < len(parts) - 1 and not stat.S_ISDIR(current_stat.st_mode):
                return "unsafe", None, 0
        try:
            resolved = current.resolve(strict=True)
            resolved.relative_to(base)
        except (FileNotFoundError, RuntimeError, ValueError):
            return "unsafe", None, 0
        final_stat = resolved.stat()
        if not stat.S_ISREG(final_stat.st_mode):
            return "unsafe", None, 0
        return "ok", resolved, final_stat.st_size

    @staticmethod
    def sha256(path):
        digest = hashlib.sha256()
        with path.open("rb") as stream:
            while True:
                block = stream.read(1024 * 1024)
                if not block:
                    break
                digest.update(block)
        return digest.hexdigest()

    def finalize(self):
        self.report["unresolved_issue_counts"] = dict(sorted(self.issue_counts.items()))
        self.report["unresolved_issues"] = self.issue_details
        self.report["unreported_issue_detail_count"] = self.hidden_issue_detail_count
        self.report["validation_gates"]["library_audit"] = "issues_found" if self.issue_counts else "no_unresolved_issues"


def error_report(code, message):
    return {
        "report_version": REPORT_VERSION,
        "error": {"code": code, "message": message},
        "validation_gates": {
            "library_audit": "not_evaluated",
            "physical_hardware": "not_evaluated",
            "eight_hour_endurance": "not_evaluated",
        },
    }


def parse_arguments(argv):
    parser = argparse.ArgumentParser(description="Read-only audit of one Echo Voice meeting library record.")
    parser.add_argument("--data-root", required=True, help="Echo Voice application data root containing echo.sqlite and meetings/")
    parser.add_argument("--meeting-id", required=True, help="Exact meeting identifier to audit")
    return parser.parse_args(argv)


def main(argv=None):
    arguments = parse_arguments(argv)
    try:
        if not safe_identifier(arguments.meeting_id):
            raise InputFailure("invalid_meeting_id", "Meeting identifiers must use 1-128 ASCII letters, digits, underscores, or hyphens.")
        supplied_root = Path(arguments.data_root).expanduser()
        try:
            root = supplied_root.resolve(strict=True)
        except (FileNotFoundError, RuntimeError) as error:
            raise InputFailure("data_root_missing", "The supplied data root does not exist.") from error
        if not root.is_dir():
            raise InputFailure("data_root_unsafe", "The supplied data root must be a directory.")
        auditor = Auditor(root, arguments.meeting_id)
        report = auditor.run()
        exit_code = 1 if report["unresolved_issue_counts"] else 0
    except InputFailure as error:
        report = error_report(error.code, error.message)
        exit_code = 2
    except (sqlite3.DatabaseError, OSError, ValueError):
        report = error_report("audit_failed", "The selected library could not be audited safely.")
        exit_code = 2
    except KeyboardInterrupt:
        report = error_report("audit_cancelled", "The read-only audit was cancelled.")
        exit_code = 2
    json.dump(report, sys.stdout, indent=2, sort_keys=True, allow_nan=False)
    sys.stdout.write("\n")
    return exit_code


if __name__ == "__main__":
    raise SystemExit(main())
