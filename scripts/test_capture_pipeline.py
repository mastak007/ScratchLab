#!/usr/bin/env python3
from __future__ import annotations

import array
import csv
import json
import os
import shutil
import struct
import subprocess
import sys
import tempfile
import unittest
import wave
from pathlib import Path
from unittest import mock

from capture_pipeline_common import (
    ALLOWED_BPMS,
    MIN_WATCH_DATA_ROWS,
    SCRATCH_TYPE,
    SEGMENT_COUNT,
    TAKE_LOG_COLUMNS,
    WATCH_CSV_HEADER,
    build_artifact_record,
    default_manifest,
)


REPO_ROOT = Path(__file__).resolve().parent.parent
SCRIPTS_DIR = REPO_ROOT / "scripts"
FIXTURES_DIR = SCRIPTS_DIR / "fixtures" / "capture_pipeline"
DJ_NAME = "DJ Fixture"
DJ_TOKEN = "DJFIXTURE"
SESSION_DATE = "2026-04-16"


class CapturePipelineFixtureTests(unittest.TestCase):
    maxDiff = None

    def setUp(self) -> None:
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.temp_root = Path(self.temporary_directory.name)
        self.sessions_root = self.temp_root / "sessions"
        self.session_dir = self.sessions_root / DJ_TOKEN / SESSION_DATE / "baby_scratch"
        self.manifest_path = self.session_dir / "manifests" / "session_manifest.json"
        self.take_log_path = self.session_dir / "manifests" / "take_log.csv"
        self.validation_report_path = self.session_dir / "manifests" / "validation_report.txt"
        self.env = os.environ.copy()
        self.ffprobe_bin_dir = self.temp_root / "bin"
        self.ffprobe_bin_dir.mkdir(parents=True, exist_ok=True)
        ffprobe_target = self.ffprobe_bin_dir / "ffprobe"
        shutil.copyfile(FIXTURES_DIR / "ffprobe_stub.py", ffprobe_target)
        ffprobe_target.chmod(0o755)
        self.env["PATH"] = f"{self.ffprobe_bin_dir}{os.pathsep}{self.env.get('PATH', '')}"

    def tearDown(self) -> None:
        self.temporary_directory.cleanup()

    def run_script(self, script_name: str, *args: object, expect_success: bool = True) -> subprocess.CompletedProcess[str]:
        result = subprocess.run(
            [sys.executable, str(SCRIPTS_DIR / script_name), *(str(item) for item in args)],
            cwd=REPO_ROOT,
            env=self.env,
            capture_output=True,
            text=True,
            check=False,
        )
        if expect_success and result.returncode != 0:
            self.fail(
                f"{script_name} failed with exit code {result.returncode}\n"
                f"stdout:\n{result.stdout}\n"
                f"stderr:\n{result.stderr}"
            )
        return result

    def create_session(self) -> None:
        self.run_script(
            "create_session.py",
            DJ_NAME,
            SESSION_DATE,
            "--sessions-root",
            self.sessions_root,
        )

    def install_take_log_fixture(self, fixture_name: str) -> None:
        shutil.copyfile(FIXTURES_DIR / fixture_name, self.take_log_path)

    def stage_raw_media(self, *, audio_frame_counts: dict[str, int] | None = None) -> None:
        raw_dir = self.session_dir / "raw"
        raw_dir.mkdir(parents=True, exist_ok=True)
        cam_fixture = FIXTURES_DIR / "camA_stub.mov"
        watch_fixture = FIXTURES_DIR / "watch_stub.csv"
        audio_frame_counts = audio_frame_counts or {}

        for bpm in ("70", "90", "110"):
            shutil.copyfile(cam_fixture, raw_dir / f"camA_{bpm}.mov")
            self.write_wav_fixture(
                raw_dir / f"audio_{bpm}.wav",
                frame_count=audio_frame_counts.get(bpm, 44100),
            )

        shutil.copyfile(watch_fixture, raw_dir / "watch_70.csv")

    def write_wav_fixture(self, path: Path, *, frame_count: int = 44100) -> None:
        with wave.open(str(path), "wb") as handle:
            handle.setnchannels(2)
            handle.setsampwidth(2)
            handle.setframerate(44100)
            handle.writeframes(b"\x00\x00\x00\x00" * frame_count)

    def read_manifest(self) -> dict[str, object]:
        return json.loads(self.manifest_path.read_text(encoding="utf-8"))

    def write_manifest(self, manifest: dict[str, object]) -> None:
        self.manifest_path.write_text(f"{json.dumps(manifest, indent=2)}\n", encoding="utf-8")

    def read_repo_text(self, relative_path: str) -> str:
        return (REPO_ROOT / relative_path).read_text(encoding="utf-8")

    def write_watch_csv(self, path: Path, *, data_rows: list[str]) -> None:
        header = (
            "elapsed_time,core_motion_timestamp,attitude_roll,attitude_pitch,attitude_yaw,"
            "quaternion_x,quaternion_y,quaternion_z,quaternion_w,gravity_x,gravity_y,gravity_z,"
            "user_accel_x,user_accel_y,user_accel_z,rotation_rate_x,rotation_rate_y,rotation_rate_z"
        )
        payload = "\n".join([header, *data_rows]) + "\n"
        path.write_text(payload, encoding="utf-8")

    def write_take_log_rows(self, rows: list[str]) -> None:
        payload = "\n".join([",".join(TAKE_LOG_COLUMNS), *rows]) + "\n"
        self.take_log_path.write_text(payload, encoding="utf-8")

    def replace_in_take_log(self, old: str, new: str, *, count: int = 1) -> None:
        contents = self.take_log_path.read_text(encoding="utf-8")
        self.take_log_path.write_text(contents.replace(old, new, count), encoding="utf-8")

    def assert_report_contains(self, expected_text: str) -> None:
        report = self.validation_report_path.read_text(encoding="utf-8")
        self.assertIn(expected_text, report)

    def assert_create_session_fails(self, *args: object) -> str:
        result = self.run_script(
            "create_session.py",
            *args,
            "--sessions-root",
            self.sessions_root,
            expect_success=False,
        )
        self.assertNotEqual(result.returncode, 0)
        return f"{result.stdout}\n{result.stderr}"

    def expected_take_sources(self, take: dict[str, object]) -> list[str]:
        camera_id = take["camera_id"]
        if camera_id == "camA":
            sources = ["camA"]
        elif camera_id == "camA+camB":
            sources = ["camA", "camB"]
        else:  # pragma: no cover - defensive path for template drift
            self.fail(f"Unexpected camera_id in example manifest template: {camera_id!r}")

        self.assertEqual(take["audio_source"], "serato")
        sources.append("serato")

        watch_source = take["watch_source"]
        self.assertIn(watch_source, {"watch", "none"})
        if watch_source == "watch":
            sources.append("watch")
        return sources

    def assert_notation_file_valid(self, relative_path: str) -> None:
        notation_path = self.session_dir / relative_path
        self.assertTrue(notation_path.exists(), f"Missing notation file {relative_path}")
        payload = json.loads(notation_path.read_text(encoding="utf-8"))
        self.assertEqual(payload["schemaVersion"], "scratchlab_detected_notation_v1")
        self.assertIsInstance(payload["sessionID"], str)
        self.assertIsInstance(payload["takeID"], str)
        self.assertEqual(payload["scratchType"], "baby_scratch")
        self.assertEqual(payload["notationSource"], "unavailable")
        self.assertIsInstance(payload["recordMovementEvents"], list)
        self.assertIsInstance(payload["faderEvents"], list)
        self.assertIsInstance(payload["mixerMidiEvents"], list)
        self.assertFalse(payload["recordMovementEvents"], "Unavailable notation must not invent stroke data")

    def test_manifest_example_template_matches_current_take_shape(self) -> None:
        template_path = REPO_ROOT / "templates" / "session_manifest_example.json"
        template = json.loads(template_path.read_text(encoding="utf-8"))

        self.assertEqual(template["scratch_type"], SCRATCH_TYPE)
        self.assertEqual(template["allowed_bpms"], list(ALLOWED_BPMS))
        self.assertEqual(template["segment_count"], SEGMENT_COUNT)

        takes = template["takes"]
        self.assertEqual(len(takes), len(ALLOWED_BPMS))
        self.assertEqual({take["bpm"] for take in takes}, set(ALLOWED_BPMS))

        for take in takes:
            self.assertEqual(take["dj_name"], template["dj_name"])
            self.assertEqual(take["date"], template["date"])
            self.assertEqual(take["scratch_type"], SCRATCH_TYPE)
            self.assertEqual(take["segment_count"], SEGMENT_COUNT)

            expected_sources = self.expected_take_sources(take)
            self.assertEqual(sorted(take["files"]), sorted(expected_sources + ["notation"]))
            self.assertEqual(sorted(take["artifacts"]), expected_sources)
            self.assertTrue(str(take["files"]["notation"]).startswith("notation/take-"))

            for source in expected_sources:
                self.assertEqual(take["artifacts"][source]["path"], take["files"][source])

    def test_take_log_template_matches_current_columns(self) -> None:
        template_path = REPO_ROOT / "templates" / "take_log_template.csv"
        with template_path.open("r", encoding="utf-8", newline="") as handle:
            reader = csv.reader(handle)
            rows = list(reader)

        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0], TAKE_LOG_COLUMNS)

    def test_session_manifest_template_matches_default_manifest(self) -> None:
        template_path = REPO_ROOT / "templates" / "session_manifest_template.json"
        template = json.loads(template_path.read_text(encoding="utf-8"))
        self.assertEqual(template, default_manifest())

    def test_capture_session_config_and_setup_model_keep_required_shared_fields(self) -> None:
        capture_core = self.read_repo_text("ScratchLab/Models/CaptureCore.swift")

        required_fields = (
            "var performerName: String",
            "var bpm: Int?",
            "var scratchType: CaptureSessionScratchType?",
            "var drillMode: CaptureSessionDrillMode?",
            "var takeDurationSeconds: Double?",
            "var takeCount: Int",
            "var handedness: CaptureSessionHandedness?",
            "var notes: String",
            "var sessionID: String",
            "var createdAt: Date",
            "var updatedAt: Date",
        )
        for field in required_fields:
            self.assertIn(field, capture_core)

        self.assertIn('case .iosCompanion:\n                self.config = .guidedCaptureDefaults()', capture_core)
        self.assertIn("case .macRoutine:", capture_core)
        self.assertIn("self.config = .routineCapture(", capture_core)
        self.assertIn('messages.append("Choose a scratch type before recording.")', capture_core)
        self.assertNotIn('messages.append("Add performer name before starting capture.")', capture_core)
        self.assertNotIn('messages.append("Enter BPM before starting capture.")', capture_core)

    def test_export_paths_use_shared_session_config_resolver_on_ios_and_routine_capture(self) -> None:
        export_coordinator = self.read_repo_text("ScratchLab/Services/SessionExportCoordinator.swift")
        companion_view = self.read_repo_text("ScratchLab/Views/CompanionCameraView.swift")

        self.assertIn("enum SessionExportMetadataResolver {", export_coordinator)
        self.assertIn("static func validatedSessionConfig(", export_coordinator)
        self.assertIn("static func sessionMatchedPreferredConfig(", export_coordinator)
        self.assertIn("let seedConfig = validatedSessionConfig(from: seedSidecar)", export_coordinator)
        self.assertIn("let sidecarConfig = sidecars.compactMap(validatedSessionConfig(from:)).first", export_coordinator)
        self.assertIn("var config = seedConfig", export_coordinator)
        self.assertIn("?? sidecarConfig", export_coordinator)
        self.assertIn("?? matchedPreferredConfig", export_coordinator)
        self.assertIn("?? CaptureSessionConfig.routineCapture(", export_coordinator)
        self.assertIn("let config = SessionExportMetadataResolver.mergedConfig(", export_coordinator)
        self.assertIn("seedSidecar: seedSidecar", export_coordinator)
        self.assertIn("let metadata = SessionExportMetadata(\n            config: config,", export_coordinator)
        self.assertIn("let config = SessionExportMetadataResolver.mergedConfig(", companion_view)
        self.assertIn("seedSidecar: seedSidecar", companion_view)

    def test_export_validation_fails_closed_when_session_metadata_is_missing_or_invalid(self) -> None:
        export_coordinator = self.read_repo_text("ScratchLab/Services/SessionExportCoordinator.swift")

        self.assertIn("case invalidSessionMetadata", export_coordinator)
        self.assertIn("guard package.metadata.takeCount == package.takes.count,", export_coordinator)
        self.assertIn("!package.metadata.sessionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty", export_coordinator)
        self.assertIn("guard sidecar.sessionID == package.metadata.sessionID,", export_coordinator)
        self.assertIn("guard SessionExportMetadataResolver.metadataMatchesSidecars(", export_coordinator)
        self.assertIn("throw SessionExportError.invalidSessionMetadata", export_coordinator)

    def test_create_session_manifest_matches_default_manifest_for_requested_session(self) -> None:
        self.create_session()
        self.assertEqual(
            self.read_manifest(),
            default_manifest(
                dj_name=DJ_NAME,
                dj_token=DJ_TOKEN,
                date_string=SESSION_DATE,
                session_dir=self.session_dir,
            ),
        )

    def test_create_session_take_log_matches_template_for_requested_session(self) -> None:
        self.create_session()
        template_path = REPO_ROOT / "templates" / "take_log_template.csv"
        self.assertEqual(
            self.take_log_path.read_text(encoding="utf-8"),
            template_path.read_text(encoding="utf-8"),
        )

    def test_create_session_rerun_keeps_matching_scaffold_files_byte_identical(self) -> None:
        self.create_session()
        original_manifest = self.manifest_path.read_bytes()
        original_take_log = self.take_log_path.read_bytes()

        rerun = self.run_script(
            "create_session.py",
            DJ_NAME,
            SESSION_DATE,
            "--sessions-root",
            self.sessions_root,
        )

        self.assertIn("Kept existing files:", rerun.stdout)
        self.assertEqual(self.manifest_path.read_bytes(), original_manifest)
        self.assertEqual(self.take_log_path.read_bytes(), original_take_log)

    def test_create_session_fails_closed_when_existing_manifest_is_invalid_json(self) -> None:
        self.create_session()
        original_take_log = self.take_log_path.read_bytes()
        self.manifest_path.write_text("{\n", encoding="utf-8")
        original_manifest = self.manifest_path.read_bytes()

        combined_output = self.assert_create_session_fails(DJ_NAME, SESSION_DATE)
        self.assertIn("could not read existing manifest", combined_output)
        self.assertEqual(self.manifest_path.read_bytes(), original_manifest)
        self.assertEqual(self.take_log_path.read_bytes(), original_take_log)

    def test_create_session_fails_closed_when_existing_take_log_is_invalid(self) -> None:
        self.create_session()
        original_manifest = self.manifest_path.read_bytes()
        self.take_log_path.write_text("bpm,take_number\n70,1\n", encoding="utf-8")
        original_take_log = self.take_log_path.read_bytes()

        combined_output = self.assert_create_session_fails(DJ_NAME, SESSION_DATE)
        self.assertIn("existing take log is invalid", combined_output)
        self.assertIn("Take log is missing required columns", combined_output)
        self.assertEqual(self.manifest_path.read_bytes(), original_manifest)
        self.assertEqual(self.take_log_path.read_bytes(), original_take_log)

    def test_create_session_fails_closed_when_existing_manifest_is_not_an_object(self) -> None:
        self.create_session()
        original_take_log = self.take_log_path.read_bytes()
        self.manifest_path.write_text("[1, 2, 3]\n", encoding="utf-8")
        original_manifest = self.manifest_path.read_bytes()

        combined_output = self.assert_create_session_fails(DJ_NAME, SESSION_DATE)
        self.assertIn("existing manifest must contain a JSON object", combined_output)
        self.assertEqual(self.manifest_path.read_bytes(), original_manifest)
        self.assertEqual(self.take_log_path.read_bytes(), original_take_log)

    def test_create_session_fails_closed_when_existing_take_log_has_only_blank_rows(self) -> None:
        self.create_session()
        original_manifest = self.manifest_path.read_bytes()
        self.write_take_log_rows([",,,,,,,,", "  ,  ,  ,  ,  ,  ,  ,  ,  "])
        original_take_log = self.take_log_path.read_bytes()

        combined_output = self.assert_create_session_fails(DJ_NAME, SESSION_DATE)
        self.assertIn("existing take log is invalid", combined_output)
        self.assertIn("contains no non-empty take rows", combined_output)
        self.assertEqual(self.manifest_path.read_bytes(), original_manifest)
        self.assertEqual(self.take_log_path.read_bytes(), original_take_log)

    def test_create_session_fails_closed_when_existing_take_log_has_invalid_bpm(self) -> None:
        self.create_session()
        original_manifest = self.manifest_path.read_bytes()
        self.write_take_log_rows(["75,1,camA.mov,,audio.wav,,true,true,notes"])
        original_take_log = self.take_log_path.read_bytes()

        combined_output = self.assert_create_session_fails(DJ_NAME, SESSION_DATE)
        self.assertIn("existing take log is invalid: take row 1", combined_output)
        self.assertIn("BPM must be one of 70, 90, 110.", combined_output)
        self.assertEqual(self.manifest_path.read_bytes(), original_manifest)
        self.assertEqual(self.take_log_path.read_bytes(), original_take_log)

    def test_create_session_fails_closed_when_existing_take_log_has_invalid_take_number(self) -> None:
        self.create_session()
        original_manifest = self.manifest_path.read_bytes()
        self.write_take_log_rows(["70,0,camA.mov,,audio.wav,,true,true,notes"])
        original_take_log = self.take_log_path.read_bytes()

        combined_output = self.assert_create_session_fails(DJ_NAME, SESSION_DATE)
        self.assertIn("existing take log is invalid: take row 1", combined_output)
        self.assertIn("Take number must be 1 or greater.", combined_output)
        self.assertEqual(self.manifest_path.read_bytes(), original_manifest)
        self.assertEqual(self.take_log_path.read_bytes(), original_take_log)

    def test_create_session_fails_closed_when_existing_take_log_has_blank_required_boolean(self) -> None:
        self.create_session()
        original_manifest = self.manifest_path.read_bytes()
        self.write_take_log_rows(["70,1,camA.mov,,audio.wav,,,true,notes"])
        original_take_log = self.take_log_path.read_bytes()

        combined_output = self.assert_create_session_fails(DJ_NAME, SESSION_DATE)
        self.assertIn("existing take log is invalid: take row 1", combined_output)
        self.assertIn("verbal_slate_used is required and cannot be blank.", combined_output)
        self.assertEqual(self.manifest_path.read_bytes(), original_manifest)
        self.assertEqual(self.take_log_path.read_bytes(), original_take_log)

    def test_create_session_fails_closed_when_existing_take_log_has_duplicate_take_identity(self) -> None:
        self.create_session()
        original_manifest = self.manifest_path.read_bytes()
        self.write_take_log_rows(
            [
                "70,1,camA_a.mov,,audio_a.wav,,true,true,first",
                "70,1,camA_b.mov,,audio_b.wav,,true,true,second",
            ]
        )
        original_take_log = self.take_log_path.read_bytes()

        combined_output = self.assert_create_session_fails(DJ_NAME, SESSION_DATE)
        self.assertIn("existing take log is invalid: take row 2", combined_output)
        self.assertIn("duplicate entry for 70 BPM take 01.", combined_output)
        self.assertEqual(self.manifest_path.read_bytes(), original_manifest)
        self.assertEqual(self.take_log_path.read_bytes(), original_take_log)

    def test_create_session_fails_closed_when_existing_take_log_has_invalid_source_extension(self) -> None:
        self.create_session()
        original_manifest = self.manifest_path.read_bytes()
        self.write_take_log_rows(["70,1,camA.mov,,audio.mp3,,true,true,notes"])
        original_take_log = self.take_log_path.read_bytes()

        combined_output = self.assert_create_session_fails(DJ_NAME, SESSION_DATE)
        self.assertIn("existing take log is invalid: take row 1", combined_output)
        self.assertIn("audio.mp3 must use one of these extensions for serato: .wav", combined_output)
        self.assertEqual(self.manifest_path.read_bytes(), original_manifest)
        self.assertEqual(self.take_log_path.read_bytes(), original_take_log)

    def test_create_session_fails_closed_when_existing_take_log_uses_absolute_raw_path(self) -> None:
        self.create_session()
        original_manifest = self.manifest_path.read_bytes()
        outside_audio = self.temp_root / "outside.wav"
        self.write_take_log_rows([f"70,1,camA.mov,,{outside_audio},,true,true,notes"])
        original_take_log = self.take_log_path.read_bytes()

        combined_output = self.assert_create_session_fails(DJ_NAME, SESSION_DATE)
        self.assertIn("existing take log is invalid: take row 1", combined_output)
        self.assertIn("Raw source paths must stay inside the session raw/ folder", combined_output)
        self.assertEqual(self.manifest_path.read_bytes(), original_manifest)
        self.assertEqual(self.take_log_path.read_bytes(), original_take_log)

    def test_create_session_fails_closed_when_existing_take_log_escapes_raw_folder(self) -> None:
        self.create_session()
        original_manifest = self.manifest_path.read_bytes()
        self.write_take_log_rows(["70,1,camA.mov,,../outside.wav,,true,true,notes"])
        original_take_log = self.take_log_path.read_bytes()

        combined_output = self.assert_create_session_fails(DJ_NAME, SESSION_DATE)
        self.assertIn("existing take log is invalid: take row 1", combined_output)
        self.assertIn("Raw source paths must stay inside the session raw/ folder: ../outside.wav", combined_output)
        self.assertEqual(self.manifest_path.read_bytes(), original_manifest)
        self.assertEqual(self.take_log_path.read_bytes(), original_take_log)

    def test_create_session_scaffolds_expected_layout(self) -> None:
        self.create_session()

        for directory_name in ("raw", "70bpm", "90bpm", "110bpm", "audio", "video", "watch", "manifests"):
            self.assertTrue((self.session_dir / directory_name).is_dir(), directory_name)

        manifest = self.read_manifest()
        self.assertEqual(manifest["dj_name"], DJ_NAME)
        self.assertEqual(manifest["dj_token"], DJ_TOKEN)
        self.assertEqual(manifest["date"], SESSION_DATE)
        self.assertEqual(manifest["takes"], [])

        rerun = self.run_script(
            "create_session.py",
            DJ_NAME,
            SESSION_DATE,
            "--sessions-root",
            self.sessions_root,
        )
        self.assertIn("Kept existing files:", rerun.stdout)

    def test_create_session_fails_when_existing_manifest_targets_a_different_session(self) -> None:
        self.create_session()

        manifest = self.read_manifest()
        manifest["date"] = "2026-04-17"
        self.write_manifest(manifest)

        combined_output = self.assert_create_session_fails(DJ_NAME, SESSION_DATE)
        self.assertIn("existing manifest does not match the requested session", combined_output)
        self.assertIn("date is '2026-04-17', expected '2026-04-16'", combined_output)

    def test_create_session_fails_when_take_log_exists_without_matching_manifest(self) -> None:
        self.create_session()
        self.manifest_path.unlink()

        combined_output = self.assert_create_session_fails(DJ_NAME, SESSION_DATE)
        self.assertIn(
            "cannot keep an existing take log without an existing manifest that matches the requested session",
            combined_output,
        )

    def test_happy_path_fixture_renames_and_validates(self) -> None:
        self.create_session()
        self.stage_raw_media()
        self.install_take_log_fixture("happy_path_take_log.csv")

        rename_result = self.run_script("rename_files.py", self.session_dir)
        self.assertIn("Updated manifest with 3 take record(s)", rename_result.stdout)

        manifest = self.read_manifest()
        self.assertEqual(len(manifest["takes"]), 3)
        takes_by_bpm = {take["bpm"]: take for take in manifest["takes"]}
        self.assertEqual(set(takes_by_bpm), {70, 90, 110})
        self.assertEqual(takes_by_bpm[70]["watch_source"], "watch")
        self.assertEqual(takes_by_bpm[90]["watch_source"], "none")
        self.assertEqual(takes_by_bpm[110]["camera_id"], "camA")
        self.assertEqual(takes_by_bpm[70]["artifacts"]["camA"]["probe"]["kind"], "video")
        self.assertEqual(takes_by_bpm[70]["artifacts"]["serato"]["probe"]["kind"], "audio")
        self.assertEqual(takes_by_bpm[70]["artifacts"]["watch"]["probe"]["kind"], "csv")

        self.assertTrue((self.session_dir / "video" / "DJFIXTURE_baby_070_take01_camA.mov").exists())
        self.assertTrue((self.session_dir / "audio" / "DJFIXTURE_baby_090_take01_serato.wav").exists())
        self.assertTrue((self.session_dir / "watch" / "DJFIXTURE_baby_070_take01_watch.csv").exists())
        self.assertTrue((self.session_dir / "notation" / "take-001_detected_notation.json").exists())
        self.assertTrue((self.session_dir / "70bpm" / "take01.txt").exists())
        self.assertTrue((self.session_dir / "90bpm" / "take01.txt").exists())
        self.assertTrue((self.session_dir / "110bpm" / "take01.txt").exists())
        self.assertEqual(
            takes_by_bpm[70]["files"]["notation"],
            "notation/take-001_detected_notation.json",
        )
        self.assert_notation_file_valid("notation/take-001_detected_notation.json")

        validate_result = self.run_script("validate_session.py", self.session_dir)
        self.assertIn("Status: PASS", validate_result.stdout)
        self.assert_report_contains("Status: PASS")
        self.assert_report_contains("- 70 BPM: 1 valid take(s), 1 renamed take(s)")
        self.assert_report_contains("- 90 BPM: 1 valid take(s), 1 renamed take(s)")
        self.assert_report_contains("- 110 BPM: 1 valid take(s), 1 renamed take(s)")
        self.assert_report_contains("70 BPM take 01: notationSource is unavailable.")

    def test_validate_accepts_empty_fader_events(self) -> None:
        self.create_session()
        self.stage_raw_media()
        self.install_take_log_fixture("happy_path_take_log.csv")
        self.run_script("rename_files.py", self.session_dir)

        validate_result = self.run_script("validate_session.py", self.session_dir)
        self.assertEqual(validate_result.returncode, 0)
        self.assert_report_contains("Status: PASS")

    def test_validate_accepts_manifest_declared_95_bpm_app_export(self) -> None:
        self.create_session()
        (self.session_dir / "95bpm").mkdir()
        video_path = self.session_dir / "video" / "DJFIXTURE_baby_095_take02_camA.mov"
        audio_path = self.session_dir / "audio" / "DJFIXTURE_baby_095_take02_scratch_only.wav"
        notation_path = self.session_dir / "notation" / "take-002_detected_notation.json"
        shutil.copyfile(FIXTURES_DIR / "camA_stub.mov", video_path)
        self.write_wav_fixture(audio_path)
        notation_path.write_text(
            json.dumps(
                {
                    "schemaVersion": "scratchlab_detected_notation_v1",
                    "sessionID": "session-95",
                    "takeID": "take-002",
                    "scratchType": "baby_scratch",
                    "notationSource": "unavailable",
                    "recordMovementEvents": [],
                    "audioEvents": [],
                    "faderEvents": [],
                    "mixerMidiEvents": [],
                }
            ),
            encoding="utf-8",
        )
        video_relative = str(video_path.relative_to(self.session_dir))
        audio_relative = str(audio_path.relative_to(self.session_dir))
        with mock.patch.dict(os.environ, {"PATH": self.env["PATH"]}):
            video_artifact = build_artifact_record(self.session_dir, video_path, "camA")
            serato_artifact = build_artifact_record(self.session_dir, audio_path, "serato")
            scratch_artifact = build_artifact_record(self.session_dir, audio_path, "scratch_only")
        self.write_manifest(
            {
                "spec_version": "capture_spec_v1",
                "dj_name": DJ_NAME,
                "dj_token": DJ_TOKEN,
                "date": SESSION_DATE,
                "scratch_type": SCRATCH_TYPE,
                "allowed_bpms": [95],
                "segment_count": SEGMENT_COUNT,
                "verbal_slate_required": False,
                "sync_clap_required": False,
                "session_root": self.session_dir.name,
                "notes": "",
                "takes": [
                    {
                        "dj_name": DJ_NAME,
                        "date": SESSION_DATE,
                        "scratch_type": SCRATCH_TYPE,
                        "bpm": 95,
                        "take_number": 2,
                        "segment_count": SEGMENT_COUNT,
                        "camera_id": "camA",
                        "audio_source": "scratchlab_output",
                        "watch_source": "none",
                        "verbal_slate_used": False,
                        "sync_clap_used": False,
                        "notes": "",
                        "files": {
                            "camA": video_relative,
                            "serato": audio_relative,
                            "scratch_only": audio_relative,
                            "notation": str(notation_path.relative_to(self.session_dir)),
                        },
                        "artifacts": {
                            "camA": video_artifact,
                            "serato": serato_artifact,
                            "scratch_only": scratch_artifact,
                        },
                    }
                ],
            }
        )
        self.write_take_log_rows(
            [f"95,2,{video_relative},,{audio_relative},,false,false,"]
        )

        validate_result = self.run_script("validate_session.py", self.session_dir)
        self.assertEqual(validate_result.returncode, 0)
        self.assert_report_contains("Status: PASS")
        self.assert_report_contains("- 95 BPM: 1 valid take(s), 1 renamed take(s)")

    def test_validate_accepts_midi_fader_events_when_present(self) -> None:
        self.create_session()
        self.stage_raw_media()
        self.install_take_log_fixture("happy_path_take_log.csv")
        self.run_script("rename_files.py", self.session_dir)

        notation_path = self.session_dir / "notation" / "take-001_detected_notation.json"
        payload = json.loads(notation_path.read_text(encoding="utf-8"))
        payload["faderEvents"] = [
            {
                "startTime": 0.10,
                "endTime": 0.18,
                "eventKind": "cut",
                "control": "crossfader",
                "fromValue": 0.0,
                "toValue": 1.0,
                "source": "midi",
                "confidence": 0.89,
            }
        ]
        payload["mixerMidiEvents"] = [
            {
                "takeRelativeTime": 0.10,
                "deviceName": "IAC Driver Bus 1",
                "channel": 0,
                "controller": 7,
                "value": 0,
                "normalizedValue": 0.0,
                "mappedControl": "crossfader",
            },
            {
                "takeRelativeTime": 0.18,
                "deviceName": "IAC Driver Bus 1",
                "channel": 0,
                "controller": 7,
                "value": 127,
                "normalizedValue": 1.0,
                "mappedControl": "crossfader",
            },
        ]
        payload["detectionSources"] = ["midi"]
        notation_path.write_text(json.dumps(payload, indent=2), encoding="utf-8")

        validate_result = self.run_script("validate_session.py", self.session_dir)
        self.assertEqual(validate_result.returncode, 0)
        self.assert_report_contains("Status: PASS")

    def test_rename_fixture_fails_closed_on_blank_boolean(self) -> None:
        self.create_session()
        self.stage_raw_media()
        self.install_take_log_fixture("blank_boolean_take_log.csv")

        rename_result = self.run_script("rename_files.py", self.session_dir, expect_success=False)
        combined_output = f"{rename_result.stdout}\n{rename_result.stderr}"
        self.assertNotEqual(rename_result.returncode, 0)
        self.assertIn("verbal_slate_used is required and cannot be blank", combined_output)

        manifest = self.read_manifest()
        self.assertEqual(manifest["takes"], [])

    def test_rename_fixture_rolls_back_copied_files_when_a_later_row_fails(self) -> None:
        self.create_session()
        self.stage_raw_media()
        self.install_take_log_fixture("partial_failure_take_log.csv")

        rename_result = self.run_script("rename_files.py", self.session_dir, expect_success=False)
        combined_output = f"{rename_result.stdout}\n{rename_result.stderr}"
        self.assertNotEqual(rename_result.returncode, 0)
        self.assertIn("Each take needs a primary camA video file.", combined_output)
        self.assertIn("Rolled back copied files from this run:", combined_output)

        manifest = self.read_manifest()
        self.assertEqual(manifest["takes"], [])

        self.assertFalse((self.session_dir / "video" / "DJFIXTURE_baby_070_take01_camA.mov").exists())
        self.assertFalse((self.session_dir / "audio" / "DJFIXTURE_baby_070_take01_serato.wav").exists())
        self.assertFalse((self.session_dir / "watch" / "DJFIXTURE_baby_070_take01_watch.csv").exists())
        self.assertFalse((self.session_dir / "audio" / "DJFIXTURE_baby_090_take01_serato.wav").exists())

    def test_rename_fixture_fails_when_take_log_uses_absolute_raw_path(self) -> None:
        self.create_session()
        self.stage_raw_media()
        self.install_take_log_fixture("happy_path_take_log.csv")
        outside_audio = self.temp_root / "outside_audio.wav"
        self.write_wav_fixture(outside_audio)
        self.replace_in_take_log("audio_70.wav", str(outside_audio))

        rename_result = self.run_script("rename_files.py", self.session_dir, expect_success=False)
        combined_output = f"{rename_result.stdout}\n{rename_result.stderr}"
        self.assertNotEqual(rename_result.returncode, 0)
        self.assertIn("Raw source paths must stay inside the session raw/ folder", combined_output)

        manifest = self.read_manifest()
        self.assertEqual(manifest["takes"], [])

    def test_validate_fixture_fails_when_take_log_raw_path_escapes_session(self) -> None:
        self.create_session()
        self.stage_raw_media()
        self.install_take_log_fixture("happy_path_take_log.csv")
        self.replace_in_take_log("audio_70.wav", "../outside_audio.wav")

        validate_result = self.run_script("validate_session.py", self.session_dir, expect_success=False)
        self.assertNotEqual(validate_result.returncode, 0)
        self.assert_report_contains("Status: FAIL")
        self.assert_report_contains(
            "take log line 2: Take log media paths must stay inside the session folder: ../outside_audio.wav"
        )

    def test_validate_fixture_fails_when_manifest_is_missing(self) -> None:
        self.create_session()
        self.stage_raw_media()
        self.install_take_log_fixture("happy_path_take_log.csv")
        self.run_script("rename_files.py", self.session_dir)
        self.manifest_path.unlink()

        validate_result = self.run_script("validate_session.py", self.session_dir, expect_success=False)
        self.assertNotEqual(validate_result.returncode, 0)
        self.assert_report_contains("Status: FAIL")
        self.assert_report_contains("Missing manifest file: manifests/session_manifest.json")

    def test_validate_fixture_fails_when_manifest_artifact_source_is_missing(self) -> None:
        self.create_session()
        self.stage_raw_media()
        self.install_take_log_fixture("happy_path_take_log.csv")
        self.run_script("rename_files.py", self.session_dir)

        manifest = self.read_manifest()
        del manifest["takes"][0]["artifacts"]["serato"]
        self.write_manifest(manifest)

        validate_result = self.run_script("validate_session.py", self.session_dir, expect_success=False)
        self.assertNotEqual(validate_result.returncode, 0)
        self.assert_report_contains("Status: FAIL")
        self.assert_report_contains("70 BPM take 01: manifest artifacts are missing source entries for: serato.")

    def test_validate_fixture_fails_when_manifest_file_source_is_missing(self) -> None:
        self.create_session()
        self.stage_raw_media()
        self.install_take_log_fixture("happy_path_take_log.csv")
        self.run_script("rename_files.py", self.session_dir)

        manifest = self.read_manifest()
        del manifest["takes"][0]["files"]["serato"]
        self.write_manifest(manifest)

        validate_result = self.run_script("validate_session.py", self.session_dir, expect_success=False)
        self.assertNotEqual(validate_result.returncode, 0)
        self.assert_report_contains("Status: FAIL")
        self.assert_report_contains("70 BPM take 01: manifest files are missing source entries for: serato.")

    def test_validate_fixture_fails_when_manifest_notation_file_source_is_missing(self) -> None:
        self.create_session()
        self.stage_raw_media()
        self.install_take_log_fixture("happy_path_take_log.csv")
        self.run_script("rename_files.py", self.session_dir)

        manifest = self.read_manifest()
        del manifest["takes"][0]["files"]["notation"]
        self.write_manifest(manifest)

        validate_result = self.run_script("validate_session.py", self.session_dir, expect_success=False)
        self.assertNotEqual(validate_result.returncode, 0)
        self.assert_report_contains("Status: FAIL")
        self.assert_report_contains("70 BPM take 01: manifest files are missing source entries for: notation.")

    def test_validate_fixture_fails_when_manifest_file_path_is_stale(self) -> None:
        self.create_session()
        self.stage_raw_media()
        self.install_take_log_fixture("happy_path_take_log.csv")
        self.run_script("rename_files.py", self.session_dir)

        manifest = self.read_manifest()
        manifest["takes"][0]["files"]["serato"] = "audio/DJFIXTURE_baby_070_take99_serato.wav"
        self.write_manifest(manifest)

        validate_result = self.run_script("validate_session.py", self.session_dir, expect_success=False)
        self.assertNotEqual(validate_result.returncode, 0)
        self.assert_report_contains("Status: FAIL")
        self.assert_report_contains(
            "70 BPM take 01: manifest file path for serato is 'audio/DJFIXTURE_baby_070_take99_serato.wav', expected 'audio/DJFIXTURE_baby_070_take01_serato.wav'."
        )

    def test_validate_fixture_accepts_video_probe_container_duration_variance(self) -> None:
        self.create_session()
        self.stage_raw_media()
        self.install_take_log_fixture("happy_path_take_log.csv")
        self.run_script("rename_files.py", self.session_dir)

        manifest = self.read_manifest()
        cam_a_probe = manifest["takes"][0]["artifacts"]["camA"]["probe"]
        cam_a_probe["duration_seconds"] = 1.18
        cam_a_probe["frame_rate_fps"] = 30.0004
        self.write_manifest(manifest)

        validate_result = self.run_script("validate_session.py", self.session_dir)
        self.assertEqual(validate_result.returncode, 0)
        self.assert_report_contains("Status: PASS")

    def test_validate_fixture_fails_when_audio_probe_bit_depth_is_wrong(self) -> None:
        self.create_session()
        self.stage_raw_media()
        self.install_take_log_fixture("happy_path_take_log.csv")
        self.run_script("rename_files.py", self.session_dir)

        manifest = self.read_manifest()
        manifest["takes"][0]["artifacts"]["serato"]["probe"]["sample_width_bytes"] = 4
        self.write_manifest(manifest)

        validate_result = self.run_script("validate_session.py", self.session_dir, expect_success=False)
        self.assertNotEqual(validate_result.returncode, 0)
        self.assert_report_contains("Status: FAIL")
        self.assert_report_contains("70 BPM take 01: artifact probe metadata for serato does not match the file on disk.")

    def test_validate_fixture_fails_when_primary_audio_is_too_short(self) -> None:
        self.create_session()
        self.stage_raw_media(audio_frame_counts={"70": 11025})
        self.install_take_log_fixture("happy_path_take_log.csv")
        self.run_script("rename_files.py", self.session_dir)

        validate_result = self.run_script("validate_session.py", self.session_dir, expect_success=False)
        self.assertNotEqual(validate_result.returncode, 0)
        self.assert_report_contains("Status: FAIL")
        self.assert_report_contains("70 BPM take 01: serato duration is 0.250s, below the minimum 0.500s.")

    def test_validate_fixture_fails_when_camA_and_serato_durations_drift(self) -> None:
        self.create_session()
        self.stage_raw_media(audio_frame_counts={"70": 88200})
        self.install_take_log_fixture("happy_path_take_log.csv")
        self.run_script("rename_files.py", self.session_dir)

        validate_result = self.run_script("validate_session.py", self.session_dir, expect_success=False)
        self.assertNotEqual(validate_result.returncode, 0)
        self.assert_report_contains("Status: FAIL")
        self.assert_report_contains(
            "70 BPM take 01: camA and serato durations differ by 1.000s (1.000s vs 2.000s; max 0.500s)."
        )

    def test_validate_fixture_fails_when_watch_csv_header_is_invalid(self) -> None:
        self.create_session()
        self.stage_raw_media()
        self.install_take_log_fixture("happy_path_take_log.csv")
        self.run_script("rename_files.py", self.session_dir)

        watch_path = self.session_dir / "watch" / "DJFIXTURE_baby_070_take01_watch.csv"
        watch_path.write_text("elapsed_time,core_motion_timestamp,attitude_roll\n0.0,12.5,0.10\n", encoding="utf-8")

        validate_result = self.run_script("validate_session.py", self.session_dir, expect_success=False)
        self.assertNotEqual(validate_result.returncode, 0)
        self.assert_report_contains("Status: FAIL")
        self.assert_report_contains(
            "70 BPM take 01: could not probe artifact metadata for watch: DJFIXTURE_baby_070_take01_watch.csv does not match the expected watch CSV header."
        )

    def test_validate_fixture_fails_when_watch_csv_has_too_few_samples(self) -> None:
        self.create_session()
        self.stage_raw_media()
        self.install_take_log_fixture("happy_path_take_log.csv")
        self.run_script("rename_files.py", self.session_dir)

        watch_path = self.session_dir / "watch" / "DJFIXTURE_baby_070_take01_watch.csv"
        self.write_watch_csv(
            watch_path,
            data_rows=[
                "0.00,100.00,0.10,0.20,0.30,0.01,0.02,0.03,0.99,0.00,-1.00,0.00,0.10,0.00,-0.10,1.00,2.00,3.00",
                "0.01,100.01,0.11,0.21,0.31,0.01,0.02,0.03,0.99,0.00,-1.00,0.00,0.11,0.00,-0.11,1.10,2.10,3.10",
            ],
        )

        validate_result = self.run_script("validate_session.py", self.session_dir, expect_success=False)
        self.assertNotEqual(validate_result.returncode, 0)
        self.assert_report_contains("Status: FAIL")
        self.assert_report_contains(
            "70 BPM take 01: could not probe artifact metadata for watch: DJFIXTURE_baby_070_take01_watch.csv has only 2 watch samples; expected at least 10."
        )

    # --- stem export tests ---

    def _setup_renamed_session(self) -> dict:
        """Return the manifest for a fully renamed session."""
        self.create_session()
        self.stage_raw_media()
        self.install_take_log_fixture("happy_path_take_log.csv")
        self.run_script("rename_files.py", self.session_dir)
        return self.read_manifest()

    def test_validate_accepts_scratch_only_wav_as_serato_alias(self) -> None:
        """A _scratch_only.wav file in audio/ is accepted by the validator as the serato audio."""
        manifest = self._setup_renamed_session()

        # Rename the 70bpm serato wav to _scratch_only.wav (simulating Swift export coordinator output)
        old_path = self.session_dir / "audio" / "DJFIXTURE_baby_070_take01_serato.wav"
        new_path = self.session_dir / "audio" / "DJFIXTURE_baby_070_take01_scratch_only.wav"
        old_path.rename(new_path)

        # Update the manifest to point to the new filename
        for take in manifest["takes"]:
            if take["bpm"] == 70:
                take["files"]["serato"] = "audio/DJFIXTURE_baby_070_take01_scratch_only.wav"
                take["files"]["scratch_only"] = "audio/DJFIXTURE_baby_070_take01_scratch_only.wav"
                take["artifacts"]["serato"]["path"] = "audio/DJFIXTURE_baby_070_take01_scratch_only.wav"
        self.write_manifest(manifest)

        validate_result = self.run_script("validate_session.py", self.session_dir)
        self.assertEqual(validate_result.returncode, 0)
        self.assert_report_contains("Status: PASS")

    def test_validate_accepts_stem_availability_with_unavailable_beat_stems(self) -> None:
        """stem_availability with unavailable beat_only/scratch_with_beat passes validation."""
        manifest = self._setup_renamed_session()

        for take in manifest["takes"]:
            # Mirror the Swift export coordinator: files.scratch_only aliases files.serato
            serato_path = take["files"].get("serato", "")
            take["files"]["scratch_only"] = serato_path
            take["stem_availability"] = {
                "scratch_only": "available",
                "beat_only": "unavailable",
                "scratch_with_beat": "unavailable",
            }
        self.write_manifest(manifest)

        validate_result = self.run_script("validate_session.py", self.session_dir)
        self.assertEqual(validate_result.returncode, 0)
        self.assert_report_contains("Status: PASS")

    def test_validate_fails_when_stem_marked_available_but_missing_from_files(self) -> None:
        """stem_availability marks beat_only as available but files.beat_only is absent."""
        manifest = self._setup_renamed_session()

        for take in manifest["takes"]:
            if take["bpm"] == 70:
                take["stem_availability"] = {
                    "scratch_only": "available",
                    "beat_only": "available",
                    "scratch_with_beat": "unavailable",
                }
                # deliberately omit files["beat_only"]
        self.write_manifest(manifest)

        validate_result = self.run_script("validate_session.py", self.session_dir, expect_success=False)
        self.assertNotEqual(validate_result.returncode, 0)
        self.assert_report_contains("Status: FAIL")
        self.assert_report_contains(
            "70 BPM take 01: stem_availability marks beat_only as available but files.beat_only is missing."
        )

    def test_validate_fails_when_stem_marked_available_but_file_missing_on_disk(self) -> None:
        """stem_availability marks beat_only as available and files has a path, but the file is absent."""
        manifest = self._setup_renamed_session()

        for take in manifest["takes"]:
            if take["bpm"] == 70:
                take["stem_availability"] = {
                    "scratch_only": "available",
                    "beat_only": "available",
                    "scratch_with_beat": "unavailable",
                }
                take["files"]["beat_only"] = "audio/DJFIXTURE_baby_070_take01_beat_only.wav"
        self.write_manifest(manifest)

        # file does not exist on disk
        validate_result = self.run_script("validate_session.py", self.session_dir, expect_success=False)
        self.assertNotEqual(validate_result.returncode, 0)
        self.assert_report_contains("Status: FAIL")
        self.assert_report_contains(
            "70 BPM take 01: stem_availability marks beat_only as available"
            " but the file is missing on disk: audio/DJFIXTURE_baby_070_take01_beat_only.wav"
        )

    def test_validate_fails_when_stem_availability_has_invalid_value(self) -> None:
        """stem_availability with an unrecognised status value is an error."""
        manifest = self._setup_renamed_session()

        for take in manifest["takes"]:
            if take["bpm"] == 70:
                take["stem_availability"] = {
                    "scratch_only": "available",
                    "beat_only": "pending",
                }
        self.write_manifest(manifest)

        validate_result = self.run_script("validate_session.py", self.session_dir, expect_success=False)
        self.assertNotEqual(validate_result.returncode, 0)
        self.assert_report_contains("Status: FAIL")
        self.assert_report_contains(
            "70 BPM take 01: stem_availability.beat_only has invalid value 'pending';"
            " must be 'available' or 'unavailable'."
        )

    def test_validate_scratch_only_availability_requires_files_entry(self) -> None:
        """stem_availability marks scratch_only as available but files.scratch_only is absent."""
        manifest = self._setup_renamed_session()

        for take in manifest["takes"]:
            if take["bpm"] == 70:
                take["stem_availability"] = {
                    "scratch_only": "available",
                    "beat_only": "unavailable",
                    "scratch_with_beat": "unavailable",
                }
                # Remove scratch_only from files to trigger the validation
                take["files"].pop("scratch_only", None)
        self.write_manifest(manifest)

        validate_result = self.run_script("validate_session.py", self.session_dir, expect_success=False)
        self.assertNotEqual(validate_result.returncode, 0)
        self.assert_report_contains("Status: FAIL")
        self.assert_report_contains(
            "70 BPM take 01: stem_availability marks scratch_only as available but files.scratch_only is missing."
        )


class AppExportValidationTests(unittest.TestCase):
    """Regressions for the shape a real ScratchLab macOS export produces.

    Modelled on session_2026_09_04_h_baby_scratch_95_bpm: IEEE Float32 stems
    with JUNK/FLLR header padding, canonical `video/` + `audio/` take-log
    paths, optional slate/clap, and frame-identical stems.
    """

    maxDiff = None

    DJ_NAME = "h"
    DJ_TOKEN = "H"
    BPM = 95
    SESSION_DATE = "2026-09-04"
    FOLDER_DATE = "2026_09_04"
    FRAME_COUNT = 44100

    def setUp(self) -> None:
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.temp_root = Path(self.temporary_directory.name)
        self.session_dir = self.temp_root / f"session_{self.FOLDER_DATE}_h_baby_scratch_95_bpm"
        self.manifest_path = self.session_dir / "manifests" / "session_manifest.json"
        self.take_log_path = self.session_dir / "manifests" / "take_log.csv"
        self.validation_report_path = self.session_dir / "manifests" / "validation_report.txt"

        self.env = os.environ.copy()
        self.ffprobe_bin_dir = self.temp_root / "bin"
        self.ffprobe_bin_dir.mkdir(parents=True, exist_ok=True)
        ffprobe_target = self.ffprobe_bin_dir / "ffprobe"
        shutil.copyfile(FIXTURES_DIR / "ffprobe_stub.py", ffprobe_target)
        ffprobe_target.chmod(0o755)
        self.env["PATH"] = f"{self.ffprobe_bin_dir}{os.pathsep}{self.env.get('PATH', '')}"

    def tearDown(self) -> None:
        self.temporary_directory.cleanup()

    # -- fixture construction ------------------------------------------------

    def write_float32_wav(self, path: Path, *, frame_count: int, peak: float) -> None:
        """Write a two-channel IEEE Float32 WAV with a JUNK/FLLR header area.

        Mirrors what AVAudioFile emits: format tag 3, and padding chunks
        between `fmt ` and `data` that a naive reader walks straight past.
        """
        path.parent.mkdir(parents=True, exist_ok=True)
        channels = 2
        sample_rate = 44100
        block_align = channels * 4

        samples = array.array("f", [0.0] * (frame_count * channels))
        for frame in range(frame_count):
            value = peak if frame % 2 == 0 else -peak * 0.5
            samples[frame * channels] = value
            samples[frame * channels + 1] = value
        payload = samples.tobytes()

        fmt_chunk = struct.pack(
            "<HHIIHH", 3, channels, sample_rate, sample_rate * block_align, block_align, 32
        )
        junk = b"JUNK" + struct.pack("<I", 28) + (b"\x00" * 28)
        fllr = b"FLLR" + struct.pack("<I", 64) + (b"\x00" * 64)
        body = (
            b"WAVE"
            + junk
            + b"fmt " + struct.pack("<I", len(fmt_chunk)) + fmt_chunk
            + fllr
            + b"data" + struct.pack("<I", len(payload)) + payload
        )
        path.write_bytes(b"RIFF" + struct.pack("<I", len(body)) + body)

    def artifact(self, path: Path, source: str) -> dict[str, object]:
        with mock.patch.dict(os.environ, {"PATH": self.env["PATH"]}):
            return build_artifact_record(self.session_dir, path, source)

    def build_export(
        self,
        *,
        beat_peak: float = 0.5,
        mixed_peak: float = 0.8,
        beat_frame_count: int | None = None,
        manifest_date: str | None = None,
        verbal_slate_required: bool = False,
        sync_clap_required: bool = False,
        watch_duration_seconds: float | None = None,
    ) -> None:
        for directory in ("raw", "audio", "video", "watch", "notation", "manifests", f"{self.BPM}bpm"):
            (self.session_dir / directory).mkdir(parents=True, exist_ok=True)

        stem = f"{self.DJ_TOKEN}_baby_{self.BPM:03d}_take01"
        video_path = self.session_dir / "video" / f"{stem}_camA.mov"
        shutil.copyfile(FIXTURES_DIR / "camA_stub.mov", video_path)

        scratch_path = self.session_dir / "audio" / f"{stem}_scratch_only.wav"
        beat_path = self.session_dir / "audio" / f"{stem}_beat_only.wav"
        mixed_path = self.session_dir / "audio" / f"{stem}_scratch_with_beat.wav"
        self.write_float32_wav(scratch_path, frame_count=self.FRAME_COUNT, peak=0.7)
        self.write_float32_wav(
            beat_path,
            frame_count=beat_frame_count if beat_frame_count is not None else self.FRAME_COUNT,
            peak=beat_peak,
        )
        self.write_float32_wav(mixed_path, frame_count=self.FRAME_COUNT, peak=mixed_peak)

        notation_path = self.session_dir / "notation" / "take-001_detected_notation.json"
        notation_path.write_text(
            json.dumps(
                {
                    "schemaVersion": "scratchlab_detected_notation_v1",
                    "sessionID": "fixture-session",
                    "takeID": "take-001",
                    "scratchType": "baby_scratch",
                    "notationSource": "detected",
                    "recordMovementEvents": [],
                    "audioEvents": [],
                    "faderEvents": [],
                    "mixerMidiEvents": [],
                }
            ),
            encoding="utf-8",
        )

        watch_path: Path | None = None
        if watch_duration_seconds is not None:
            watch_path = self.session_dir / "watch" / f"{stem}_watch.csv"
            self.write_watch_csv(watch_path, duration_seconds=watch_duration_seconds)

        def relative(path: Path) -> str:
            return str(path.relative_to(self.session_dir))

        session_date = manifest_date or self.SESSION_DATE
        manifest = {
            "spec_version": "capture_spec_v1",
            "dj_name": self.DJ_NAME,
            "dj_token": self.DJ_TOKEN,
            "date": session_date,
            "scratch_type": SCRATCH_TYPE,
            "allowed_bpms": [self.BPM],
            "segment_count": SEGMENT_COUNT,
            "verbal_slate_required": verbal_slate_required,
            "sync_clap_required": sync_clap_required,
            "session_root": self.session_dir.name,
            "notes": "",
            "takes": [
                {
                    "dj_name": self.DJ_NAME,
                    "date": session_date,
                    "scratch_type": SCRATCH_TYPE,
                    "bpm": self.BPM,
                    "take_number": 1,
                    "segment_count": SEGMENT_COUNT,
                    "camera_id": "camA",
                    "audio_source": "scratchlab_output",
                    "watch_source": "none" if watch_path is None else "watch",
                    "verbal_slate_used": False,
                    "sync_clap_used": False,
                    "notes": "",
                    "stem_availability": {
                        "scratch_only": "available",
                        "beat_only": "available",
                        "scratch_with_beat": "available",
                    },
                    "files": {
                        "camA": relative(video_path),
                        "serato": relative(scratch_path),
                        "scratch_only": relative(scratch_path),
                        "beat_only": relative(beat_path),
                        "scratch_with_beat": relative(mixed_path),
                        "notation": relative(notation_path),
                    },
                    "artifacts": {
                        "camA": self.artifact(video_path, "camA"),
                        "serato": self.artifact(scratch_path, "serato"),
                        "scratch_only": self.artifact(scratch_path, "scratch_only"),
                        "beat_only": self.artifact(beat_path, "beat_only"),
                        "scratch_with_beat": self.artifact(mixed_path, "scratch_with_beat"),
                    },
                }
            ],
        }
        if watch_path is not None:
            take = manifest["takes"][0]
            take["files"]["watch"] = relative(watch_path)
            take["artifacts"]["watch"] = self.artifact(watch_path, "watch")

        self.manifest_path.write_text(f"{json.dumps(manifest, indent=2)}\n", encoding="utf-8")
        watch_cell = relative(watch_path) if watch_path is not None else ""
        self.take_log_path.write_text(
            "\n".join(
                [
                    ",".join(TAKE_LOG_COLUMNS),
                    f'"{self.BPM}","1","{relative(video_path)}","","{relative(scratch_path)}","{watch_cell}","false","false",""',
                ]
            )
            + "\n",
            encoding="utf-8",
        )

    def write_watch_csv(self, path: Path, *, duration_seconds: float) -> None:
        """Write a canonical-header Watch motion CSV spanning `duration_seconds`.

        Sampled at 100 Hz like the real recorder, so `elapsed_time` runs from
        0.0 to `duration_seconds`.
        """
        path.parent.mkdir(parents=True, exist_ok=True)
        sample_count = max(MIN_WATCH_DATA_ROWS, int(round(duration_seconds * 100)) + 1)
        step = duration_seconds / (sample_count - 1)
        rows = [",".join(WATCH_CSV_HEADER)]
        for index in range(sample_count):
            elapsed = index * step
            rows.append(
                ",".join([repr(round(elapsed, 6)), repr(round(elapsed, 6))] + ["0.0"] * 16)
            )
        path.write_text("\n".join(rows) + "\n", encoding="utf-8")

    # -- helpers -------------------------------------------------------------

    def run_validate(self, *, expect_success: bool, env: dict[str, str] | None = None) -> str:
        result = subprocess.run(
            [sys.executable, str(SCRIPTS_DIR / "validate_session.py"), str(self.session_dir)],
            cwd=REPO_ROOT,
            env=env or self.env,
            capture_output=True,
            text=True,
            check=False,
        )
        if expect_success:
            self.assertEqual(
                result.returncode, 0, f"stdout:\n{result.stdout}\nstderr:\n{result.stderr}"
            )
        else:
            self.assertNotEqual(result.returncode, 0)
        return self.validation_report_path.read_text(encoding="utf-8")

    # -- tests ---------------------------------------------------------------

    def test_validate_accepts_float32_app_export(self) -> None:
        self.build_export()
        report = self.run_validate(expect_success=True)
        self.assertIn("Status: PASS", report)
        self.assertNotIn("is not a readable WAV file", report)

    def test_validate_reads_float32_wav_without_ffprobe(self) -> None:
        self.build_export()
        env = self.env.copy()
        # Make ffprobe refuse WAV input so only the RIFF fallback can answer,
        # while video probing (which genuinely needs ffprobe) still works.
        env["FFPROBE_STUB_FAIL_WAV"] = "1"
        report = self.run_validate(expect_success=True, env=env)
        self.assertIn("Status: PASS", report)
        self.assertNotIn("is not a readable WAV file", report)

    def test_canonical_take_log_paths_are_not_rerooted_under_raw(self) -> None:
        self.build_export()
        report = self.run_validate(expect_success=True)
        self.assertNotIn("/raw/video/", report)
        self.assertNotIn("/raw/audio/", report)
        self.assertNotIn("take log source file is missing", report)

    def test_optional_slate_and_clap_do_not_warn(self) -> None:
        self.build_export()
        report = self.run_validate(expect_success=True)
        self.assertNotIn("verbal_slate_used is false.", report)
        self.assertNotIn("sync_clap_used is false.", report)

    def test_required_slate_and_clap_still_warn_when_unused(self) -> None:
        self.build_export(verbal_slate_required=True, sync_clap_required=True)
        report = self.run_validate(expect_success=True)
        self.assertIn("verbal_slate_used is false.", report)
        self.assertIn("sync_clap_used is false.", report)

    def test_validate_rejects_beat_stem_above_full_scale(self) -> None:
        self.build_export(beat_peak=1.218279)
        report = self.run_validate(expect_success=False)
        self.assertIn("beat_only peaks at 1.218279", report)
        self.assertIn("above full scale", report)

    def test_validate_rejects_generated_stem_without_headroom(self) -> None:
        # 0.99 is inside full scale but leaves less than 1 dB of headroom.
        self.build_export(beat_peak=0.99)
        report = self.run_validate(expect_success=False)
        self.assertIn("above the -1.0 dBFS headroom ceiling", report)

    def test_validate_rejects_mixed_stem_at_or_above_full_scale(self) -> None:
        self.build_export(mixed_peak=1.5)
        report = self.run_validate(expect_success=False)
        self.assertIn("scratch_with_beat peaks at 1.500000", report)

    def test_validate_rejects_stem_frame_count_drift(self) -> None:
        self.build_export(beat_frame_count=self.FRAME_COUNT - 1)
        report = self.run_validate(expect_success=False)
        self.assertIn("audio stem frame counts differ", report)

    # -- the watch must stop when the take stops -----------------------------
    #
    # BVB regression (2026-09-04): a 19.4 s take whose Watch CSV ran to
    # 37.894 s because the Mac's Stop never reached the Watch.
    #
    # The quantity is the gap between the two *ends*, not the difference of the
    # two durations. Session `1ce25396-…` proved why: 15.411 s of motion against
    # a 10.000 s take, yet the Watch stopped in the same second it was asked to.
    # The whole 5.411 s was a lead-in, and a duration comparison called it an
    # overrun.

    TAKE_START = "2026-09-04T03:39:20Z"
    TAKE_STOP = "2026-09-04T03:39:30Z"

    def alignment(
        self,
        *,
        watch_start: str,
        watch_end: str,
        take_start: str | None = None,
        take_stop: str | None = None,
    ) -> dict[str, object]:
        return {
            "takeStartedAt": take_start or self.TAKE_START,
            "takeStopRequestedAt": take_stop or self.TAKE_STOP,
            "watchCaptureStartedAt": watch_start,
            "watchCaptureEndedAt": watch_end,
        }

    def test_watch_that_kept_recording_after_the_take_is_rejected(self) -> None:
        # The BVB shape: stopped 18.494 s after the stop was requested.
        self.build_export(watch_duration_seconds=19.494)
        self.write_session_metadata(
            self.alignment(
                watch_start="2026-09-04T03:39:20Z",
                watch_end="2026-09-04T03:39:48.494Z",
            )
        )
        report = self.run_validate(expect_success=False)
        self.assertIn("watch motion stopped 18.494s after the take's stop was requested", report)
        self.assertIn("kept recording after the take ended", report)

    def test_a_long_lead_in_is_not_an_overrun(self) -> None:
        # Session `1ce25396-…` exactly: 5.411 s longer than the take, but it
        # stopped on time. This must pass.
        self.build_export(watch_duration_seconds=15.411)
        self.write_session_metadata(
            self.alignment(
                watch_start="2026-09-04T03:39:15Z",
                watch_end=self.TAKE_STOP,
            )
        )
        report = self.run_validate(expect_success=True)
        self.assertIn("Status: PASS", report)
        self.assertNotIn("kept recording after the take ended", report)
        # The lead-in is still surfaced, because it points at a stalling start.
        self.assertIn("began 5.000s before the take's media", report)

    def test_a_short_lead_in_is_silent(self) -> None:
        self.build_export(watch_duration_seconds=11.0)
        self.write_session_metadata(
            self.alignment(
                watch_start="2026-09-04T03:39:19Z",
                watch_end=self.TAKE_STOP,
            )
        )
        report = self.run_validate(expect_success=True)
        self.assertIn("Status: PASS", report)
        self.assertNotIn("before the take's media", report)

    def test_watch_stop_within_finalization_latency_is_accepted(self) -> None:
        self.build_export(watch_duration_seconds=11.5)
        self.write_session_metadata(
            self.alignment(
                watch_start="2026-09-04T03:39:20Z",
                watch_end="2026-09-04T03:39:31.5Z",
            )
        )
        report = self.run_validate(expect_success=True)
        self.assertIn("Status: PASS", report)
        self.assertNotIn("after the take's stop was requested", report)

    def test_watch_stop_at_the_error_boundary_warns_but_passes(self) -> None:
        # Exactly the full bounded handshake: slow, still explicable.
        self.build_export(watch_duration_seconds=14.0)
        self.write_session_metadata(
            self.alignment(
                watch_start="2026-09-04T03:39:20Z",
                watch_end="2026-09-04T03:39:34Z",
            )
        )
        report = self.run_validate(expect_success=True)
        self.assertIn("Status: PASS", report)
        self.assertIn("slower than a healthy acknowledgement", report)

    def test_watch_stop_past_the_handshake_bound_is_rejected(self) -> None:
        self.build_export(watch_duration_seconds=15.0)
        self.write_session_metadata(
            self.alignment(
                watch_start="2026-09-04T03:39:20Z",
                watch_end="2026-09-04T03:39:35Z",
            )
        )
        report = self.run_validate(expect_success=False)
        self.assertIn("kept recording after the take ended", report)

    def test_an_archive_without_alignment_never_asserts_an_overrun(self) -> None:
        # Every export written before the alignment instants existed. The
        # difference is real but unattributable, and must not be reported as a
        # late stop.
        self.build_export(watch_duration_seconds=19.494)
        report = self.run_validate(expect_success=True)
        self.assertIn("Status: PASS", report)
        self.assertIn("records no watch/take alignment", report)
        self.assertNotIn("kept recording after the take ended", report)

    def test_watch_overrun_check_preserves_every_captured_sample(self) -> None:
        # The bug is reported, never hidden by editing the evidence.
        self.build_export(watch_duration_seconds=19.494)
        self.write_session_metadata(
            self.alignment(
                watch_start="2026-09-04T03:39:20Z",
                watch_end="2026-09-04T03:39:48.494Z",
            )
        )
        watch_path = next((self.session_dir / "watch").glob("*_watch.csv"))
        before = watch_path.read_bytes()
        self.run_validate(expect_success=False)
        self.assertEqual(watch_path.read_bytes(), before)

    def test_session_without_a_watch_is_unaffected(self) -> None:
        self.build_export()
        report = self.run_validate(expect_success=True)
        self.assertIn("Status: PASS", report)
        self.assertNotIn("watch motion", report)

    # -- exported watch stop diagnostics -------------------------------------

    def test_degraded_watch_stop_outcome_survives_into_session_metadata(self) -> None:
        # `watch_source` cannot say why motion is absent or late; these fields
        # can, and the validator must not choke on them.
        self.build_export()
        self.write_session_metadata(
            {
                "stopReason": "manual",
                "actualTakeDurationSeconds": 1.0,
                "watchSyncState": "acknowledged",
                "watchLinkedMotionFileName": "scratch-motion-live-1.json",
                "watchMotionExported": True,
                "watchStopOutcome": "timedOut",
                "watchStopDetail": "Watch stop was not acknowledged within 2 seconds.",
                "watchMotionTransferState": "completed",
            }
        )
        report = self.run_validate(expect_success=True)
        self.assertIn("Status: PASS", report)

    # -- stop reason gates the planned/actual duration check -----------------

    def write_session_metadata(self, take: dict[str, object]) -> None:
        (self.session_dir / "manifests" / "session_metadata.json").write_text(
            json.dumps(
                {
                    "session": {"sessionID": "fixture-session", "totalDurationSeconds": 16.7},
                    "takes": [{"takeID": "take-001", "takeNumber": 1, **take}],
                },
                indent=2,
            )
            + "\n",
            encoding="utf-8",
        )

    def test_manual_stop_under_a_cap_is_not_a_duration_shortfall(self) -> None:
        # The kk regression: 16.70 s of media under a 64 s safety cap, stopped
        # by hand. Nothing was planned, so nothing came up short.
        self.build_export()
        self.write_session_metadata(
            {
                "stopReason": "manual",
                "plannedTakeDurationSeconds": None,
                "maximumTakeDurationSeconds": 64,
                "actualTakeDurationSeconds": 16.7,
            }
        )
        report = self.run_validate(expect_success=True)
        self.assertIn("Status: PASS", report)
        self.assertNotIn("planned", report.lower())

    def test_media_limit_stop_is_not_a_duration_shortfall(self) -> None:
        self.build_export()
        self.write_session_metadata(
            {
                "stopReason": "media_limit",
                "maximumTakeDurationSeconds": 64,
                "actualTakeDurationSeconds": 64.0,
            }
        )
        report = self.run_validate(expect_success=True)
        self.assertIn("Status: PASS", report)

    def test_planned_duration_reached_flags_a_real_shortfall(self) -> None:
        self.build_export()
        self.write_session_metadata(
            {
                "stopReason": "planned_duration_reached",
                "plannedTakeDurationSeconds": 24,
                "maximumTakeDurationSeconds": 64,
                "actualTakeDurationSeconds": 16.7,
            }
        )
        report = self.run_validate(expect_success=False)
        self.assertIn("planned 24.000s but captured 16.700s", report)

    def test_planned_duration_reached_accepts_frame_tolerance(self) -> None:
        self.build_export()
        self.write_session_metadata(
            {
                "stopReason": "planned_duration_reached",
                "plannedTakeDurationSeconds": 24,
                "actualTakeDurationSeconds": 23.98,
            }
        )
        report = self.run_validate(expect_success=True)
        self.assertIn("Status: PASS", report)

    def test_planned_duration_reached_without_a_plan_is_an_error(self) -> None:
        self.build_export()
        self.write_session_metadata(
            {"stopReason": "planned_duration_reached", "actualTakeDurationSeconds": 16.7}
        )
        report = self.run_validate(expect_success=False)
        self.assertIn("no plannedTakeDurationSeconds is recorded", report)

    def test_unknown_stop_reason_is_rejected(self) -> None:
        self.build_export()
        self.write_session_metadata({"stopReason": "gave_up", "actualTakeDurationSeconds": 16.7})
        report = self.run_validate(expect_success=False)
        self.assertIn("stopReason 'gave_up' is not one of", report)

    def test_missing_stop_reason_warns_without_failing(self) -> None:
        # Takes recorded before stop reasons existed must still validate.
        self.build_export()
        self.write_session_metadata({"actualTakeDurationSeconds": 16.7})
        report = self.run_validate(expect_success=True)
        self.assertIn("Status: PASS", report)
        self.assertIn("no stopReason recorded", report)

    def test_a_plan_that_did_not_elapse_warns_rather_than_failing(self) -> None:
        self.build_export()
        self.write_session_metadata(
            {
                "stopReason": "manual",
                "plannedTakeDurationSeconds": 24,
                "actualTakeDurationSeconds": 16.7,
            }
        )
        report = self.run_validate(expect_success=True)
        self.assertIn("Status: PASS", report)
        self.assertIn("the planned duration did not elapse", report)

    # -- Watch sync state stays truthful ------------------------------------

    def test_timed_out_watch_is_reported_not_silently_absent(self) -> None:
        # The BBBB regression: 2,346 samples captured and matched, but the
        # routine sidecar kept `timedOut` and no link, so the manifest said
        # `none` and nothing said why.
        self.build_export()
        self.write_session_metadata(
            {
                "stopReason": "manual",
                "actualTakeDurationSeconds": 16.5,
                "watchSyncState": "timedOut",
                "watchLinkedMotionFileName": None,
                "watchMotionExported": False,
            }
        )
        report = self.run_validate(expect_success=True)
        self.assertIn("Status: PASS", report)
        self.assertIn("sync state is 'timedOut'", report)
        self.assertIn("not Watch-synchronised", report)

    def test_not_requested_watch_does_not_warn(self) -> None:
        self.build_export()
        self.write_session_metadata(
            {
                "stopReason": "manual",
                "actualTakeDurationSeconds": 16.5,
                "watchSyncState": "notRequested",
                "watchMotionExported": False,
            }
        )
        report = self.run_validate(expect_success=True)
        self.assertIn("Status: PASS", report)
        self.assertNotIn("not Watch-synchronised", report)

    def test_linked_watch_motion_that_did_not_export_is_an_error(self) -> None:
        self.build_export()
        self.write_session_metadata(
            {
                "stopReason": "manual",
                "actualTakeDurationSeconds": 16.5,
                "watchSyncState": "acknowledged",
                "watchLinkedMotionFileName": "scratch-motion-live-ABC.json",
                "watchMotionExported": False,
            }
        )
        report = self.run_validate(expect_success=False)
        self.assertIn("but it was not exported", report)

    def test_acknowledged_watch_without_a_link_is_an_error(self) -> None:
        self.build_export()
        self.write_session_metadata(
            {
                "stopReason": "manual",
                "actualTakeDurationSeconds": 16.5,
                "watchSyncState": "acknowledged",
                "watchLinkedMotionFileName": None,
                "watchMotionExported": False,
            }
        )
        report = self.run_validate(expect_success=False)
        self.assertIn("no Watch motion is linked", report)

    def test_unknown_watch_sync_state_is_rejected(self) -> None:
        self.build_export()
        self.write_session_metadata(
            {"stopReason": "manual", "actualTakeDurationSeconds": 16.5, "watchSyncState": "vibes"}
        )
        report = self.run_validate(expect_success=False)
        self.assertIn("watchSyncState 'vibes' is not one of", report)

    def test_missing_watch_sync_state_is_silent_for_legacy_exports(self) -> None:
        self.build_export()
        self.write_session_metadata({"stopReason": "manual", "actualTakeDurationSeconds": 16.5})
        report = self.run_validate(expect_success=True)
        self.assertIn("Status: PASS", report)
        self.assertNotIn("watchSyncState", report)

    def test_validate_rejects_folder_and_manifest_date_disagreement(self) -> None:
        self.build_export(manifest_date="2026-09-03")
        report = self.run_validate(expect_success=False)
        self.assertIn(
            "Session folder date 2026-09-04 does not match manifest date 2026-09-03",
            report,
        )


if __name__ == "__main__":
    unittest.main()
