import hashlib
import json
import os
from pathlib import Path
import shutil
import sqlite3
import subprocess
import sys
import unittest
import uuid


PROJECT_ROOT = Path(__file__).resolve().parents[2]
SCRIPT = PROJECT_ROOT / "scripts" / "audit-library.py"
TEST_ROOT = Path(os.environ.get("ECHO_TEST_ROOT", PROJECT_ROOT / "tmp" / "audit-library-tests"))


SCHEMA = """
PRAGMA foreign_keys = ON;
CREATE TABLE meetings (
    id TEXT PRIMARY KEY NOT NULL,
    title TEXT NOT NULL,
    started_at REAL NOT NULL,
    ended_at REAL,
    state TEXT NOT NULL,
    language TEXT NOT NULL,
    source_name TEXT NOT NULL,
    uses_echo_cancellation INTEGER NOT NULL,
    transcript_revision INTEGER NOT NULL
);
CREATE TABLE chunks (
    meeting_id TEXT NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
    id TEXT NOT NULL,
    epoch_id TEXT NOT NULL,
    track TEXT NOT NULL,
    relative_path TEXT NOT NULL,
    start_time REAL NOT NULL,
    duration REAL NOT NULL,
    sample_rate REAL NOT NULL,
    frame_count INTEGER NOT NULL,
    sha256 TEXT NOT NULL,
    PRIMARY KEY (meeting_id, id)
);
CREATE TABLE capture_gaps (
    meeting_id TEXT NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
    id TEXT NOT NULL,
    start_time REAL NOT NULL,
    end_time REAL,
    reason TEXT NOT NULL,
    PRIMARY KEY (meeting_id, id)
);
CREATE TABLE transcript_segments (
    meeting_id TEXT NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
    id TEXT NOT NULL,
    window_id TEXT NOT NULL,
    track TEXT NOT NULL,
    start_time REAL NOT NULL,
    end_time REAL NOT NULL,
    text TEXT NOT NULL,
    speaker_id TEXT,
    is_uncertain INTEGER NOT NULL,
    is_provisional INTEGER NOT NULL,
    is_edited INTEGER NOT NULL,
    PRIMARY KEY (meeting_id, id)
);
CREATE TABLE screenshots (
    meeting_id TEXT NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
    id TEXT NOT NULL,
    relative_path TEXT NOT NULL,
    captured_at REAL NOT NULL,
    perceptual_hash TEXT NOT NULL,
    interpretation TEXT,
    PRIMARY KEY (meeting_id, id)
);
CREATE TABLE meeting_notes (
    meeting_id TEXT NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
    id TEXT NOT NULL,
    created_at REAL NOT NULL,
    transcript_revision INTEGER NOT NULL,
    summary_json BLOB NOT NULL,
    decisions_json BLOB NOT NULL,
    action_items_json BLOB NOT NULL,
    is_edited INTEGER NOT NULL,
    is_partial INTEGER NOT NULL,
    PRIMARY KEY (meeting_id, id)
);
CREATE TABLE processing_jobs (
    meeting_id TEXT NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
    id TEXT NOT NULL,
    kind TEXT NOT NULL,
    status TEXT NOT NULL,
    payload TEXT NOT NULL,
    attempts INTEGER NOT NULL,
    error TEXT,
    created_at REAL NOT NULL,
    PRIMARY KEY (meeting_id, id)
);
"""


class AuditLibraryTests(unittest.TestCase):
    def setUp(self):
        TEST_ROOT.mkdir(parents=True, exist_ok=True)
        self.root = TEST_ROOT / str(uuid.uuid4())
        self.meeting_id = "meeting-a"
        self.meeting_dir = self.root / "meetings" / self.meeting_id
        self.meeting_dir.mkdir(parents=True)
        self.database = self.root / "echo.sqlite"
        self.connection = sqlite3.connect(self.database)
        self.connection.executescript(SCHEMA)
        self.add_meeting(self.meeting_id)

    def tearDown(self):
        self.connection.close()
        shutil.rmtree(self.root, ignore_errors=True)

    def add_meeting(self, meeting_id, *, state="ready", ended_at=60.0):
        self.connection.execute(
            "INSERT INTO meetings VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
            (meeting_id, "private title", 0.0, ended_at, state, "en", "private source", 1, 0),
        )
        self.connection.commit()

    def write_asset(self, relative_path, contents):
        path = self.meeting_dir / relative_path
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(contents)
        return hashlib.sha256(contents).hexdigest()

    def add_chunk(self, chunk_id, start, duration, relative_path, digest, *, track="microphone", epoch="epoch-1", rate=10.0, frames=None):
        self.connection.execute(
            "INSERT INTO chunks VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
            (self.meeting_id, chunk_id, epoch, track, relative_path, start, duration, rate, frames if frames is not None else int(duration * rate), digest),
        )
        self.connection.commit()

    def run_audit(self, meeting_id=None):
        completed = subprocess.run(
            [sys.executable, str(SCRIPT), "--data-root", str(self.root), "--meeting-id", meeting_id or self.meeting_id],
            cwd=PROJECT_ROOT,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=10,
            check=False,
        )
        self.assertEqual(completed.stderr, "")
        return completed, json.loads(completed.stdout)

    def test_clean_selected_meeting_reports_only_metadata_and_leaves_library_unchanged(self):
        first_hash = self.write_asset("audio/mic-1.caf", b"first committed audio")
        second_hash = self.write_asset("audio/mic-2.caf", b"second committed audio")
        screenshot = self.meeting_dir / "screenshots" / "shot.png"
        screenshot.parent.mkdir(parents=True)
        screenshot.write_bytes(b"retained screenshot")
        self.add_chunk("chunk-1", 0.0, 5.0, "audio/mic-1.caf", first_hash)
        self.add_chunk("chunk-2", 5.0, 5.0, "audio/mic-2.caf", second_hash)
        self.connection.execute(
            "INSERT INTO transcript_segments VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
            (self.meeting_id, "segment-1", "window-1", "cleanMicrophone", 0.0, 2.0, "PRIVATE TRANSCRIPT TEXT", None, 0, 0, 0),
        )
        self.connection.execute(
            "INSERT INTO screenshots VALUES (?, ?, ?, ?, ?, ?)",
            (self.meeting_id, "screenshot-1", "screenshots/shot.png", 2.0, "private perceptual hash", "PRIVATE SCREEN CONTENT"),
        )
        note_item = [{"id": "item-1", "text": "PRIVATE NOTE TEXT", "evidenceIDs": ["segment-1", "screenshot-1"], "owner": None, "dueDate": None}]
        self.connection.execute(
            "INSERT INTO meeting_notes VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
            (self.meeting_id, "notes-1", 10.0, 0, json.dumps(note_item), "[]", "[]", 0, 0),
        )
        self.connection.execute(
            "INSERT INTO processing_jobs VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
            (self.meeting_id, "job-1", "notes", "completed", '{"token":"PRIVATE JOB TOKEN"}', 1, "PRIVATE ERROR", 10.0),
        )
        self.add_meeting("other-meeting")
        self.connection.execute(
            "INSERT INTO transcript_segments VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
            ("other-meeting", "other-segment", "other-window", "microphone", 0.0, 1.0, "OTHER MEETING SECRET", None, 0, 0, 0),
        )
        self.connection.commit()

        database_before = hashlib.sha256(self.database.read_bytes()).hexdigest()
        files_before = sorted(str(path.relative_to(self.root)) for path in self.root.rglob("*"))
        completed, report = self.run_audit()

        self.assertEqual(completed.returncode, 0)
        self.assertEqual(report["validation_gates"]["library_audit"], "no_unresolved_issues")
        self.assertEqual(report["validation_gates"]["physical_hardware"], "not_evaluated")
        self.assertEqual(report["validation_gates"]["eight_hour_endurance"], "not_evaluated")
        self.assertEqual(report["measurements"]["audio"]["committed_chunk_count"], 2)
        self.assertEqual(report["measurements"]["audio"]["checksum_verified_count"], 2)
        self.assertEqual(report["measurements"]["evidence"]["reference_count"], 2)
        self.assertEqual(report["measurements"]["evidence"]["unresolved_reference_count"], 0)
        self.assertEqual(report["measurements"]["screenshots"]["retained_count"], 1)
        self.assertEqual(report["measurements"]["jobs"]["pending"], 0)
        rendered = json.dumps(report)
        for secret in ("PRIVATE TRANSCRIPT TEXT", "PRIVATE SCREEN CONTENT", "PRIVATE NOTE TEXT", "PRIVATE JOB TOKEN", "PRIVATE ERROR", "OTHER MEETING SECRET"):
            self.assertNotIn(secret, rendered)
        self.assertEqual(hashlib.sha256(self.database.read_bytes()).hexdigest(), database_before)
        self.assertEqual(sorted(str(path.relative_to(self.root)) for path in self.root.rglob("*")), files_before)

    def test_reports_asset_timeline_job_evidence_and_screenshot_problems_without_mislabeling_disclosed_gap(self):
        valid_hash = self.write_asset("audio/valid.caf", b"valid")
        mismatch_hash = self.write_asset("audio/mismatch.caf", b"actual bytes")
        outside = self.root / "outside.caf"
        outside.write_bytes(b"outside")
        link = self.meeting_dir / "audio" / "link.caf"
        link.symlink_to(outside)
        self.add_chunk("chunk-1", 0.0, 5.0, "audio/valid.caf", valid_hash)
        self.add_chunk("chunk-2", 7.0, 5.0, "audio/mismatch.caf", "0" * 64)
        self.add_chunk("chunk-3", 14.0, 5.0, "audio/missing.caf", "1" * 64)
        self.add_chunk("chunk-4", 18.0, 5.0, "../outside.caf", hashlib.sha256(b"outside").hexdigest())
        self.add_chunk("chunk-5", 23.0, 5.0, "audio/link.caf", hashlib.sha256(b"outside").hexdigest(), track="remote")
        self.connection.execute(
            "INSERT INTO capture_gaps VALUES (?, ?, ?, ?, ?)",
            (self.meeting_id, "gap-1", 5.0, 7.0, "disclosed interruption details must stay private"),
        )
        self.connection.execute(
            "INSERT INTO meeting_notes VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
            (self.meeting_id, "notes-1", 10.0, 0, json.dumps([{"id": "item", "text": "secret", "evidenceIDs": ["missing-evidence"]}]), "[]", "[]", 0, 0),
        )
        self.connection.execute(
            "INSERT INTO screenshots VALUES (?, ?, ?, ?, ?, ?)",
            (self.meeting_id, "missing-shot", "screenshots/missing.png", 2.0, "hash", None),
        )
        for job_id, status in (("pending-job", "pending"), ("failed-job", "failed"), ("running-job", "running")):
            self.connection.execute(
                "INSERT INTO processing_jobs VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
                (self.meeting_id, job_id, "transcribe", status, '{"token":"never report"}', 1, "never report", 10.0),
            )
        self.connection.commit()

        completed, report = self.run_audit()

        self.assertEqual(completed.returncode, 1)
        counts = report["unresolved_issue_counts"]
        self.assertEqual(counts["audio_checksum_mismatch"], 1)
        self.assertEqual(counts["audio_asset_missing"], 1)
        self.assertEqual(counts["audio_asset_unsafe"], 2)
        self.assertEqual(counts["timeline_gap_undisclosed"], 1)
        self.assertEqual(counts["timeline_overlap"], 1)
        self.assertNotIn("timeline_gap_disclosed", counts)
        timeline = next(item for item in report["measurements"]["audio"]["timelines"] if item["track"] == "microphone")
        self.assertEqual(timeline["disclosed_gap_count"], 1)
        self.assertEqual(timeline["undisclosed_gap_count"], 1)
        self.assertEqual(timeline["overlap_count"], 1)
        self.assertEqual(report["measurements"]["jobs"]["pending"], 1)
        self.assertEqual(report["measurements"]["jobs"]["failed"], 1)
        self.assertEqual(report["measurements"]["evidence"]["unresolved_reference_count"], 1)
        self.assertEqual(report["measurements"]["screenshots"]["missing_count"], 1)
        self.assertNotIn("disclosed interruption details", json.dumps(report))
        self.assertNotIn("never report", json.dumps(report))

    def test_foreign_key_check_is_aggregated_without_exposing_other_meeting_identifiers(self):
        self.connection.execute("PRAGMA foreign_keys = OFF")
        self.connection.execute(
            "INSERT INTO processing_jobs VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
            ("private-orphan-meeting", "private-orphan-job", "notes", "failed", "private payload", 1, "private error", 0.0),
        )
        self.connection.commit()

        completed, report = self.run_audit()

        self.assertEqual(completed.returncode, 1)
        self.assertEqual(report["database"]["foreign_key_violation_count"], 1)
        rendered = json.dumps(report)
        self.assertNotIn("private-orphan-meeting", rendered)
        self.assertNotIn("private-orphan-job", rendered)
        self.assertNotIn("private payload", rendered)
        self.assertNotIn("private error", rendered)

    def test_raw_host_drift_within_fifty_milliseconds_is_measured_as_corrected(self):
        for name in ("raw-1", "raw-2", "raw-3", "raw-4", "clean-1", "clean-2"):
            relative_path = "audio/{}.caf".format(name)
            digest = self.write_asset(relative_path, name.encode("ascii"))
            if name == "raw-1":
                self.add_chunk(name, 0.0, 5.0, relative_path, digest, rate=1000.0, frames=5000)
            elif name == "raw-2":
                self.add_chunk(name, 5.002, 5.0, relative_path, digest, rate=1000.0, frames=5000)
            elif name == "raw-3":
                self.add_chunk(name, 10.0, 5.0, relative_path, digest, rate=1000.0, frames=5000)
            elif name == "raw-4":
                self.add_chunk(name, 15.051, 5.0, relative_path, digest, rate=1000.0, frames=5000)
            elif name == "clean-1":
                self.add_chunk(name, 0.0, 5.0, relative_path, digest, track="cleanMicrophone", rate=1000.0, frames=5000)
            else:
                self.add_chunk(name, 5.002, 5.0, relative_path, digest, track="cleanMicrophone", rate=1000.0, frames=5000)

        completed, report = self.run_audit()

        self.assertEqual(completed.returncode, 1)
        raw = next(item for item in report["measurements"]["audio"]["timelines"] if item["track"] == "microphone")
        self.assertEqual(raw["corrected_drift_count"], 2)
        self.assertEqual(raw["corrected_stretch_count"], 1)
        self.assertEqual(raw["corrected_compression_count"], 1)
        self.assertAlmostEqual(raw["corrected_drift_net_seconds"], 0.0, places=6)
        self.assertAlmostEqual(raw["corrected_drift_absolute_seconds"], 0.004, places=6)
        self.assertEqual(raw["undisclosed_gap_count"], 1)
        self.assertAlmostEqual(raw["gap_seconds"], 0.051, places=6)
        clean = next(item for item in report["measurements"]["audio"]["timelines"] if item["track"] == "cleanMicrophone")
        self.assertEqual(clean["corrected_drift_count"], 0)
        self.assertEqual(clean["undisclosed_gap_count"], 1)
        self.assertEqual(report["unresolved_issue_counts"]["timeline_gap_undisclosed"], 2)

    def test_rejects_unsafe_meeting_identifier_before_accessing_assets(self):
        completed, report = self.run_audit("../other-meeting")

        self.assertEqual(completed.returncode, 2)
        self.assertEqual(report["error"]["code"], "invalid_meeting_id")
        self.assertNotIn("private title", json.dumps(report))


if __name__ == "__main__":
    unittest.main()
