import array
import hashlib
import importlib.util
import json
import math
import os
from pathlib import Path
import shutil
import subprocess
import sys
import unittest
from unittest import mock
import uuid
import wave


PROJECT = Path(__file__).resolve().parents[2]
SCRIPT = PROJECT / "scripts/analyze-echo.py"
SPEC = importlib.util.spec_from_file_location("analyze_echo", SCRIPT)
ANALYZER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(ANALYZER)
TEST_ROOT = Path(os.environ.get("ECHO_TEST_ROOT", PROJECT / "tmp/analyze-echo-tests"))


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def write_wav(path, samples):
    path.parent.mkdir(parents=True, exist_ok=True)
    data = array.array("h", samples)
    if sys.byteorder != "little":
        data.byteswap()
    with wave.open(str(path), "wb") as output:
        output.setparams((1, 2, 16000, 0, "NONE", "not compressed"))
        output.writeframes(data.tobytes())


class EchoAnalysisTests(unittest.TestCase):
    def setUp(self):
        self.root = TEST_ROOT / ("echo-analysis-" + uuid.uuid4().hex)
        self.meeting = self.root / "data/meetings/meeting-test"
        self.journal = self.meeting / "derived/.aec/epoch-test.json"
        self.journal.parent.mkdir(parents=True)

    def tearDown(self):
        shutil.rmtree(self.root)

    def fixture(self, sizes=(253, 547, 800), *, finalized=True, near=None, clean=None, far=None):
        total = sum(sizes)
        near = near if near is not None else [(2000 + i // 37 % 5 * 2000) * (1 if i % 2 else -1) for i in range(total)]
        clean = clean if clean is not None else [int(value / 10) for value in near]
        far = far if far is not None else [4000 if i % 2 else -4000 for i in range(total)]
        history, input_offset, clean_offset = [], 0, 0
        for sequence, size in enumerate(sizes):
            final = finalized and sequence == len(sizes) - 1
            end = input_offset + size
            clean_end = end if final else end // 160 * 160
            paths = {"near_path": f"derived/near-{sequence}.wav", "far_path": f"derived/far-{sequence}.wav", "output_path": f"derived/clean-{sequence}.wav"}
            for key, values in (("near_path", near[input_offset:end]), ("far_path", far[input_offset:end]), ("output_path", clean[clean_offset:clean_end])):
                write_wav(self.meeting / paths[key], values)
            job = f"aec-job-{sequence}"
            request = {"job_id": job, "meeting_id": self.meeting.name, "epoch_id": "epoch-test", "sequence": sequence,
                       "reset": sequence == 0, "final": final, **paths}
            history.append({"request": request, "result": {"job_id": job, "relative_path": paths["output_path"], "sample_rate": 16000, "frame_count": clean_end - clean_offset},
                            "inputs": {key: digest(self.meeting / paths[key]) for key in ("near_path", "far_path")},
                            "output_sha256": digest(self.meeting / paths["output_path"])})
            input_offset, clean_offset = end, clean_end
        self.journal.write_text(json.dumps(history))
        return history

    def analyze(self, warmup=0.01, duration=0.07, **kwargs):
        return ANALYZER.analyze(self.meeting, "epoch-test", run_mode="remote-only", warmup_seconds=warmup, duration_seconds=duration, **kwargs)

    def test_cumulative_offsets_align_remainders_and_do_not_modify_artifacts(self):
        self.fixture()
        before = {path: (path.stat().st_mtime_ns, digest(path)) for path in self.meeting.rglob("*") if path.is_file()}
        result = self.analyze()
        self.assertAlmostEqual(result["echo_reduction_db"], 20.0, places=10)
        self.assertEqual(result["coverage"]["measured_sample_count"], 1120)
        self.assertEqual(result["measurements"]["near"]["verified_chunk_count"], 3)
        self.assertEqual(result["measurements"]["clean"]["verified_chunk_count"], 2)
        self.assertTrue(result["coverage"]["complete"])
        self.assertEqual(set(result["validation_gates"].values()), {"not_evaluated"})
        after = {path: (path.stat().st_mtime_ns, digest(path)) for path in before}
        self.assertEqual(before, after)

    def test_unfinalized_remainder_and_partial_interval_are_disclosed(self):
        self.fixture(sizes=(257,), finalized=False)
        result = self.analyze(warmup=0, duration=257 / 16000)
        self.assertFalse(result["epoch_finalized"])
        self.assertEqual(result["coverage"]["pending_tail_frames"], 97)
        self.assertEqual(result["coverage"]["measured_sample_count"], 160)
        self.assertFalse(result["coverage"]["complete"])
        self.assertAlmostEqual(result["coverage"]["fraction"], 160 / 257)

    def test_empty_final_input_flushes_carried_output_without_losing_alignment(self):
        self.fixture(sizes=(257, 0))
        result = self.analyze(warmup=0, duration=257 / 16000)
        self.assertTrue(result["epoch_finalized"])
        self.assertEqual(result["coverage"]["pending_tail_frames"], 0)
        self.assertEqual(result["coverage"]["measured_sample_count"], 257)
        self.assertAlmostEqual(result["echo_reduction_db"], 20)

    def test_selected_checksum_mismatch_is_rejected(self):
        self.fixture()
        path = self.meeting / "derived/clean-1.wav"
        with path.open("r+b") as stream:
            stream.seek(-2, 2)
            stream.write(b"\x00\x00")
        with self.assertRaises(ANALYZER.AnalysisFailure) as error:
            self.analyze()
        self.assertEqual(error.exception.code, "checksum_mismatch")

    def test_only_selected_payloads_are_hashed_and_audio_reads_are_bounded(self):
        self.fixture(sizes=(16000, 16000, 16000))
        path = self.meeting / "derived/near-2.wav"
        with path.open("r+b") as stream:
            stream.seek(-2, 2); stream.write(b"\x00\x00")
        requested = []
        original = wave.Wave_read.readframes
        def readframes(reader, count):
            requested.append(count)
            return original(reader, count)
        with mock.patch.object(wave.Wave_read, "readframes", readframes):
            result = self.analyze(warmup=0, duration=0.75)
        self.assertEqual(result["coverage"]["measured_sample_count"], 12000)
        self.assertEqual(sum(requested), 3 * 12000)
        self.assertLessEqual(max(requested), ANALYZER.BLOCK)
        self.assertIn("unselected audio payloads not hashed", result["checksum_scope"])

    def test_unsafe_paths_and_cross_meeting_reference_are_rejected(self):
        history = self.fixture()
        history[0]["request"]["near_path"] = "../../unrelated.wav"
        self.journal.write_text(json.dumps(history))
        with self.assertRaises(ANALYZER.AnalysisFailure) as error:
            self.analyze()
        self.assertEqual(error.exception.code, "unsafe_path")
        self.fixture()
        path = self.meeting / "derived/near-0.wav"
        independent = self.root / "independent.wav"
        shutil.copyfile(path, independent)
        path.unlink(); path.symlink_to(independent)
        with self.assertRaises(ANALYZER.AnalysisFailure) as error:
            self.analyze()
        self.assertEqual(error.exception.code, "unsafe_path")

    def test_sequence_and_frame_accounting_must_be_consistent(self):
        for damage in ("sequence", "reset", "frame_count"):
            with self.subTest(damage=damage):
                history = self.fixture()
                if damage == "sequence":
                    history[1]["request"]["sequence"] = 3
                elif damage == "reset":
                    history[1]["request"]["reset"] = True
                else:
                    history[1]["result"]["frame_count"] += 1
                self.journal.write_text(json.dumps(history))
                with self.assertRaises(ANALYZER.AnalysisFailure):
                    self.analyze()

    def test_clipping_and_silence_are_reported_without_infinite_db_or_gate_pass(self):
        self.fixture(sizes=(320,), near=[32767, -32768] * 160, clean=[0] * 320)
        result = self.analyze(warmup=0, duration=0.02)
        self.assertEqual(result["measurements"]["near"]["clipped_sample_count"], 320)
        self.assertEqual(result["measurements"]["clean"]["clipped_sample_count"], 0)
        self.assertIsNone(result["echo_reduction_db"])
        self.assertEqual(result["undefined_reduction_reason"], "clean_silent")
        json.dumps(result, allow_nan=False)
        self.fixture(sizes=(320,), far=[0] * 320)
        result = self.analyze(warmup=0, duration=0.02)
        self.assertEqual(result["undefined_reduction_reason"], "far_silent")
        self.assertIsNone(result["echo_reduction_db"])

    def test_run_mode_interval_and_available_coverage_are_explicit(self):
        self.fixture()
        with self.assertRaises(ANALYZER.AnalysisFailure):
            ANALYZER.analyze(self.meeting, "epoch-test", run_mode="unknown", warmup_seconds=0, duration_seconds=1)
        for warmup, duration in ((-1, 1), (0, 301), (math.nan, 1), (1, 0), (1, math.inf), (30, 1)):
            with self.subTest(warmup=warmup, duration=duration), self.assertRaises(ANALYZER.AnalysisFailure):
                self.analyze(warmup=warmup, duration=duration)

    def test_cli_outputs_only_measurements_and_requires_remote_only_declaration(self):
        self.fixture()
        args = [sys.executable, str(SCRIPT), "--meeting-dir", str(self.meeting), "--epoch-id", "epoch-test", "--warmup-seconds", "0.01", "--duration-seconds", "0.07"]
        missing = subprocess.run(args, capture_output=True, text=True, timeout=10)
        self.assertEqual(missing.returncode, 2)
        completed = subprocess.run(args + ["--run-mode", "remote-only"], capture_output=True, text=True, timeout=10)
        self.assertEqual(completed.returncode, 0, completed.stderr)
        result = json.loads(completed.stdout)
        self.assertEqual(result["run_mode_source"], "caller_declaration_not_verified")
        self.assertNotIn("transcript", result)
        self.assertNotIn(str(self.root), completed.stdout)
        self.assertEqual(completed.stderr, "")


if __name__ == "__main__":
    unittest.main()
