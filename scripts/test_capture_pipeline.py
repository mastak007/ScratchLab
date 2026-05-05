#!/usr/bin/env python3
from __future__ import annotations

import csv
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
import wave
from pathlib import Path

from capture_pipeline_common import ALLOWED_BPMS, SCRATCH_TYPE, SEGMENT_COUNT, TAKE_LOG_COLUMNS, default_manifest


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
        self.assertIn('messages.append("Choose the scratch type before starting capture.")', capture_core)
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
            "take log line 2: Raw source paths must stay inside the session raw/ folder: ../outside_audio.wav"
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


if __name__ == "__main__":
    unittest.main()
