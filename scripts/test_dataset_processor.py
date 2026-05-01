#!/usr/bin/env python3
from __future__ import annotations

import argparse
import importlib.util
import io
import json
import subprocess
import sys
import tempfile
import unittest
import wave
import zipfile
from pathlib import Path
from unittest import mock


REPO_ROOT = Path(__file__).resolve().parent.parent
PROCESSOR_SCRIPT = REPO_ROOT / "scripts" / "dataset_processor" / "process_dataset.py"
LABEL_SCRIPT = REPO_ROOT / "scripts" / "dataset_processor" / "label_clip.py"
INGEST_MEDIA_SCRIPT = REPO_ROOT / "scripts" / "dataset_processor" / "ingest_media_scratch.py"


def load_module(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"Unable to load module from {path}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


INGEST_MEDIA_MODULE = load_module("ingest_media_scratch_test_module", INGEST_MEDIA_SCRIPT)


class DatasetProcessorTests(unittest.TestCase):
    maxDiff = None

    def setUp(self) -> None:
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.temp_root = Path(self.temporary_directory.name)
        self.input_root = self.temp_root / "input"
        self.output_root = self.temp_root / "output"
        self.input_root.mkdir(parents=True, exist_ok=True)

    def tearDown(self) -> None:
        self.temporary_directory.cleanup()

    def run_processor(self, *args: str, expect_success: bool = True) -> subprocess.CompletedProcess[str]:
        result = subprocess.run(
            [
                sys.executable,
                str(PROCESSOR_SCRIPT),
                "--input",
                str(self.input_root),
                "--output",
                str(self.output_root),
                *args,
            ],
            cwd=REPO_ROOT,
            capture_output=True,
            text=True,
            check=False,
        )
        if expect_success and result.returncode != 0:
            self.fail(
                f"Dataset processor failed with exit code {result.returncode}\n"
                f"stdout:\n{result.stdout}\n"
                f"stderr:\n{result.stderr}"
            )
        return result

    def run_labeler(self, *args: str, expect_success: bool = True) -> subprocess.CompletedProcess[str]:
        result = subprocess.run(
            [
                sys.executable,
                str(LABEL_SCRIPT),
                *args,
            ],
            cwd=REPO_ROOT,
            capture_output=True,
            text=True,
            check=False,
        )
        if expect_success and result.returncode != 0:
            self.fail(
                f"Label CLI failed with exit code {result.returncode}\n"
                f"stdout:\n{result.stdout}\n"
                f"stderr:\n{result.stderr}"
            )
        return result

    def write_text_file(self, path: Path, contents: str) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(contents, encoding="utf-8")

    def write_binary_file(self, path: Path, contents: bytes) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(contents)

    def write_audio_map_file(self, payload: dict[str, object]) -> Path:
        path = self.temp_root / "audio_map.json"
        self.write_text_file(path, json.dumps(payload, indent=2) + "\n")
        return path

    def write_fake_media_file(self, path: Path) -> None:
        self.write_binary_file(path, b"fake media bytes")

    def write_wav_file(self, path: Path, *, frame_count: int = 22_050) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        with wave.open(str(path), "wb") as handle:
            handle.setnchannels(1)
            handle.setsampwidth(2)
            handle.setframerate(44_100)
            handle.writeframes(b"\x00\x00" * frame_count)

    def write_loose_metadata(
        self,
        path: Path,
        *,
        performer: str = "DJ Fixture",
        scratch_type: str = "baby",
        bpm: int = 90,
        beat_mode: str = "withBeat",
        label_source: str = "manual",
        confidence: float = 1.0,
        notes: str = "",
        start_time: float = 0.0,
        end_time: float | None = None,
    ) -> None:
        payload = {
            "performer": performer,
            "scratchType": scratch_type,
            "bpm": bpm,
            "beatMode": beat_mode,
            "labelSource": label_source,
            "confidence": confidence,
            "notes": notes,
            "startTime": start_time,
            "endTime": end_time,
        }
        self.write_text_file(path, json.dumps(payload, indent=2) + "\n")

    def write_scratchlab_export_zip(self, archive_path: Path) -> None:
        session_root = self.temp_root / "session_export"
        audio_rel = "audio/DJFIXTURE_baby_090_take01_serato.wav"
        video_rel = "video/DJFIXTURE_baby_090_take01_camA.mov"
        watch_rel = "watch/DJFIXTURE_baby_090_take01_watch.csv"

        self.write_wav_file(session_root / audio_rel)
        self.write_binary_file(session_root / video_rel, b"fake mov bytes")
        self.write_text_file(
            session_root / watch_rel,
            "elapsed_time,core_motion_timestamp,attitude_roll,attitude_pitch,attitude_yaw,quaternion_x,quaternion_y,quaternion_z,quaternion_w,gravity_x,gravity_y,gravity_z,user_accel_x,user_accel_y,user_accel_z,rotation_rate_x,rotation_rate_y,rotation_rate_z\n"
            "0.0,0.0,0,0,0,0,0,0,1,0,-1,0,0,0,0,0,0,0\n",
        )

        session_manifest = {
            "dj_name": "DJ Fixture",
            "scratch_type": "baby",
            "takes": [
                {
                    "scratch_type": "baby",
                    "bpm": 90,
                    "take_number": 1,
                    "camera_id": "camA",
                    "audio_source": "serato",
                    "watch_source": "watch",
                    "files": {
                        "camA": video_rel,
                        "serato": audio_rel,
                        "watch": watch_rel,
                    },
                    "artifacts": {
                        "camA": {
                            "path": video_rel,
                            "probe": {
                                "kind": "video",
                                "duration_seconds": 1.25,
                            },
                        },
                        "serato": {
                            "path": audio_rel,
                            "probe": {
                                "kind": "audio",
                                "duration_seconds": 0.5,
                            },
                        },
                        "watch": {
                            "path": watch_rel,
                            "probe": {
                                "kind": "csv",
                                "row_count": 2,
                            },
                        },
                    },
                }
            ],
        }
        session_metadata = {
            "session": {
                "sessionID": "session-zip-001",
                "performerName": "DJ Fixture",
                "scratchTypeID": "baby_scratch",
                "scratchTypeName": "Baby Scratch",
                "beatEngineMode": "click_track",
                "notes": "Exported from ScratchLab",
            },
            "takes": [
                {
                    "takeID": "take-001",
                    "takeNumber": 1,
                    "bpm": 90,
                    "beatEngineMode": "click_track",
                }
            ],
        }
        take_log = (
            "bpm,take_number,raw_camA,raw_camB,raw_audio,raw_watch,verbal_slate_used,sync_clap_used,notes\n"
            "90,1,raw/camA.mov,,raw/audio.wav,raw/watch.csv,true,true,\n"
        )

        self.write_text_file(
            session_root / "manifests" / "session_manifest.json",
            json.dumps(session_manifest, indent=2) + "\n",
        )
        self.write_text_file(
            session_root / "manifests" / "session_metadata.json",
            json.dumps(session_metadata, indent=2) + "\n",
        )
        self.write_text_file(session_root / "manifests" / "take_log.csv", take_log)

        archive_path.parent.mkdir(parents=True, exist_ok=True)
        with zipfile.ZipFile(archive_path, "w") as archive:
            for file_path in session_root.rglob("*"):
                if file_path.is_file():
                    archive.write(file_path, arcname=str(Path("ScratchLabExport") / file_path.relative_to(session_root)))

    def load_manifest(self) -> dict[str, object]:
        manifest_path = self.output_root / "manifest.json"
        self.assertTrue(manifest_path.exists(), "manifest.json was not written")
        return json.loads(manifest_path.read_text(encoding="utf-8"))

    def make_ingest_args(self, **overrides: object) -> argparse.Namespace:
        defaults = {
            "input_root": str(self.input_root),
            "output_root": str(self.output_root),
            "audio_map": None,
            "inspect_streams": False,
            "force": False,
            "dry_run": False,
            "performer": "CXL Dataset",
        }
        defaults.update(overrides)
        return argparse.Namespace(**defaults)

    def make_ingester(self, **overrides: object):
        return INGEST_MEDIA_MODULE.MediaScratchIngester(self.make_ingest_args(**overrides))

    def test_valid_loose_video_metadata_accepted(self) -> None:
        self.write_binary_file(self.input_root / "clip_001.mov", b"video bytes")
        self.write_loose_metadata(self.input_root / "clip_001.meta.json")

        self.run_processor("--mode", "process", "--allow-loose-clips")

        accepted_take_dir = self.output_root / "accepted" / "baby" / "90bpm" / "take_0001"
        self.assertTrue((accepted_take_dir / "video.mov").exists())
        metadata = json.loads((accepted_take_dir / "meta.json").read_text(encoding="utf-8"))
        self.assertEqual(metadata["sourceType"], "loose_clip")
        self.assertEqual(metadata["sourceFile"], "clip_001.mov")
        self.assertEqual(metadata["scratchType"], "baby")
        self.assertTrue(metadata["hasVideo"])
        self.assertFalse(metadata["hasAudio"])

    def test_loose_clip_without_metadata_rejected(self) -> None:
        self.write_binary_file(self.input_root / "clip_002.mov", b"video bytes")

        self.run_processor("--mode", "process", "--allow-loose-clips")

        manifest = self.load_manifest()
        self.assertEqual(manifest["summary"]["rejectedByReason"]["missing_metadata"], 1)
        rejected_files = list((self.output_root / "rejected" / "missing_metadata").rglob("clip_002.mov"))
        self.assertTrue(rejected_files)

    def test_unknown_scratch_type_rejected(self) -> None:
        self.write_binary_file(self.input_root / "clip_003.mov", b"video bytes")
        self.write_loose_metadata(
            self.input_root / "clip_003.meta.json",
            scratch_type="banana",
        )

        self.run_processor("--mode", "process", "--allow-loose-clips")

        manifest = self.load_manifest()
        self.assertEqual(manifest["summary"]["rejectedByReason"]["unknown_scratch_type"], 1)

    def test_scratchlab_zip_structure_validates(self) -> None:
        self.write_scratchlab_export_zip(self.input_root / "session_export.zip")

        result = self.run_processor("--mode", "validate")
        self.assertEqual(result.returncode, 0, result.stderr)

        manifest = self.load_manifest()
        self.assertEqual(manifest["summary"]["acceptedCount"], 1)
        self.assertEqual(manifest["summary"]["rejectedCount"], 0)

    def test_manifest_json_is_written(self) -> None:
        self.write_binary_file(self.input_root / "clip_004.mov", b"video bytes")
        self.write_loose_metadata(self.input_root / "clip_004.meta.json")

        self.run_processor("--mode", "process", "--allow-loose-clips")

        manifest = self.load_manifest()
        self.assertEqual(manifest["summary"]["acceptedCount"], 1)

    def test_accepted_output_uses_canonical_folder_structure(self) -> None:
        self.write_binary_file(self.input_root / "nested" / "clip_005.mov", b"video bytes")
        self.write_loose_metadata(self.input_root / "nested" / "clip_005.meta.json", bpm=110)

        self.run_processor("--mode", "process", "--allow-loose-clips")

        expected_take_dir = self.output_root / "accepted" / "baby" / "110bpm" / "take_0001"
        self.assertTrue(expected_take_dir.exists())
        self.assertTrue((expected_take_dir / "video.mov").exists())
        self.assertTrue((expected_take_dir / "meta.json").exists())

    def test_label_clip_creates_sidecar_for_single_file(self) -> None:
        clip_path = self.input_root / "clip_006.mov"
        self.write_binary_file(clip_path, b"video bytes")

        self.run_labeler(
            str(clip_path),
            "--performer",
            "CXL Dataset",
            "--scratch-type",
            "baby",
            "--bpm",
            "90",
            "--beat-mode",
            "withBeat",
            "--confidence",
            "0.9",
        )

        sidecar_path = self.input_root / "clip_006.meta.json"
        self.assertTrue(sidecar_path.exists())
        metadata = json.loads(sidecar_path.read_text(encoding="utf-8"))
        self.assertEqual(metadata["performer"], "CXL Dataset")
        self.assertEqual(metadata["scratchType"], "baby")
        self.assertEqual(metadata["bpm"], 90)
        self.assertEqual(metadata["beatMode"], "withBeat")
        self.assertEqual(metadata["labelSource"], "manual")
        self.assertEqual(metadata["confidence"], 0.9)
        self.assertEqual(metadata["startTime"], 0.0)
        self.assertIsNone(metadata["endTime"])

    def test_label_clip_refuses_overwrite_without_force(self) -> None:
        clip_path = self.input_root / "clip_007.mov"
        sidecar_path = self.input_root / "clip_007.meta.json"
        self.write_binary_file(clip_path, b"video bytes")
        self.write_loose_metadata(sidecar_path, performer="Original")

        result = self.run_labeler(
            str(clip_path),
            "--performer",
            "CXL Dataset",
            "--scratch-type",
            "baby",
            "--bpm",
            "90",
            "--beat-mode",
            "withBeat",
            "--confidence",
            "0.9",
            expect_success=False,
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("already exists", result.stderr)
        metadata = json.loads(sidecar_path.read_text(encoding="utf-8"))
        self.assertEqual(metadata["performer"], "Original")

    def test_label_clip_overwrites_with_force(self) -> None:
        clip_path = self.input_root / "clip_008.mov"
        sidecar_path = self.input_root / "clip_008.meta.json"
        self.write_binary_file(clip_path, b"video bytes")
        self.write_loose_metadata(sidecar_path, performer="Original")

        result = self.run_labeler(
            str(clip_path),
            "--performer",
            "CXL Dataset",
            "--scratch-type",
            "baby",
            "--bpm",
            "90",
            "--beat-mode",
            "withBeat",
            "--confidence",
            "0.9",
            "--force",
        )

        self.assertEqual(result.returncode, 0)
        metadata = json.loads(sidecar_path.read_text(encoding="utf-8"))
        self.assertEqual(metadata["performer"], "CXL Dataset")

    def test_label_clip_rejects_invalid_confidence(self) -> None:
        clip_path = self.input_root / "clip_009.mov"
        self.write_binary_file(clip_path, b"video bytes")

        result = self.run_labeler(
            str(clip_path),
            "--performer",
            "CXL Dataset",
            "--scratch-type",
            "baby",
            "--bpm",
            "90",
            "--beat-mode",
            "withBeat",
            "--confidence",
            "1.5",
            expect_success=False,
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("confidence must be between 0.0 and 1.0.", result.stderr)
        self.assertFalse((self.input_root / "clip_009.meta.json").exists())

    def test_label_clip_batch_mode_labels_multiple_clips(self) -> None:
        batch_root = self.input_root / "batch"
        self.write_binary_file(batch_root / "clip_010.mov", b"video bytes")
        self.write_wav_file(batch_root / "clip_011.wav")

        result = self.run_labeler(
            "--input-dir",
            str(batch_root),
            "--performer",
            "CXL Dataset",
            "--scratch-type",
            "baby",
            "--bpm",
            "90",
            "--beat-mode",
            "withBeat",
            "--label-source",
            "batch_manual",
            "--confidence",
            "0.9",
        )

        self.assertEqual(result.returncode, 0)
        self.assertTrue((batch_root / "clip_010.meta.json").exists())
        self.assertTrue((batch_root / "clip_011.meta.json").exists())
        first_metadata = json.loads((batch_root / "clip_010.meta.json").read_text(encoding="utf-8"))
        self.assertEqual(first_metadata["labelSource"], "batch_manual")

    def test_label_clip_no_beat_allows_null_bpm(self) -> None:
        clip_path = self.input_root / "clip_012.mov"
        self.write_binary_file(clip_path, b"video bytes")

        self.run_labeler(
            str(clip_path),
            "--performer",
            "CXL Dataset",
            "--scratch-type",
            "baby",
            "--beat-mode",
            "noBeat",
            "--confidence",
            "0.9",
        )

        metadata = json.loads((self.input_root / "clip_012.meta.json").read_text(encoding="utf-8"))
        self.assertEqual(metadata["beatMode"], "noBeat")
        self.assertIsNone(metadata["bpm"])

    def test_ingest_folder_name_parsing_with_bpm(self) -> None:
        descriptor = INGEST_MEDIA_MODULE.parse_folder_descriptor("Chirp flare_92bpm")

        self.assertEqual(descriptor.scratch_display_name, "Chirp flare")
        self.assertEqual(descriptor.scratch_type, "chirp_flare")
        self.assertEqual(descriptor.bpm, 92)
        self.assertEqual(descriptor.bpm_source, "folder_name")
        self.assertEqual(descriptor.warnings, [])

    def test_ingest_folder_name_parsing_without_bpm(self) -> None:
        descriptor = INGEST_MEDIA_MODULE.parse_folder_descriptor("Transformer")

        self.assertEqual(descriptor.scratch_display_name, "Transformer")
        self.assertEqual(descriptor.scratch_type, "transformer")
        self.assertIsNone(descriptor.bpm)
        self.assertEqual(descriptor.bpm_source, "missing")
        self.assertTrue(descriptor.warnings)

    def test_ingest_filename_classification_variants(self) -> None:
        self.assertEqual(
            INGEST_MEDIA_MODULE.classify_filename("Angle 1 beat performance.mov"),
            INGEST_MEDIA_MODULE.AUDIO_ROLE_WITH_BEAT,
        )
        self.assertEqual(
            INGEST_MEDIA_MODULE.classify_filename("Angle 3 no beat performance.mov"),
            INGEST_MEDIA_MODULE.AUDIO_ROLE_NO_BEAT,
        )

    def test_ingest_assigns_camera_angles_deterministically(self) -> None:
        source_clips = [
            INGEST_MEDIA_MODULE.SourceClip(
                source_path=Path(name),
                probe_info=INGEST_MEDIA_MODULE.MediaProbeInfo(
                    has_video=True,
                    video_stream_index=0,
                    audio_streams=[
                        INGEST_MEDIA_MODULE.AudioStreamInfo(stream_index=1, codec_name="aac", duration=30.0)
                    ],
                ),
            )
            for name in ("d_cam.mov", "b_cam.mov", "a_cam.mov", "c_cam.mov")
        ]

        available_angles = INGEST_MEDIA_MODULE.assign_camera_angles(source_clips)

        self.assertEqual(available_angles, ["angle_1", "angle_2", "angle_3", "angle_4"])
        by_name = {clip.source_path.name: clip.camera_angle for clip in source_clips}
        self.assertEqual(by_name["a_cam.mov"], "angle_1")
        self.assertEqual(by_name["b_cam.mov"], "angle_2")
        self.assertEqual(by_name["c_cam.mov"], "angle_3")
        self.assertEqual(by_name["d_cam.mov"], "angle_4")

    def test_ingest_ignores_generated_files(self) -> None:
        scratch_root = self.input_root / "Dicing_85bpm"
        self.write_fake_media_file(scratch_root / "angle_1_no_beat.mov")
        self.write_fake_media_file(scratch_root / "angle_1_no_beat_performance.mov")
        self.write_fake_media_file(scratch_root / "angle_1_no_beat_performance_clean.mov")
        self.write_fake_media_file(scratch_root / "angle_1_no_beat_instruction.mov")

        found = self.make_ingester().find_source_folders()

        self.assertIn(scratch_root.resolve(), found)
        self.assertEqual([path.name for path in found[scratch_root.resolve()]], ["angle_1_no_beat.mov"])

    def test_ingest_generated_metadata_fields(self) -> None:
        folder_descriptor = INGEST_MEDIA_MODULE.parse_folder_descriptor("Chirp flare_92bpm")
        metadata = INGEST_MEDIA_MODULE.build_audio_metadata(
            source_path=self.input_root / "Chirp flare_92bpm" / "angle_a.mov",
            input_root=self.input_root,
            source_folder_name="Chirp flare_92bpm",
            performer="CXL Dataset",
            folder_descriptor=folder_descriptor,
            camera_angle="angle_1",
            camera_angle_count=4,
            linked_video_file="angle_1_video.mov",
            audio_stream=INGEST_MEDIA_MODULE.AudioStreamInfo(stream_index=2, codec_name="aac", duration=42.75),
            audio_stream_role=INGEST_MEDIA_MODULE.AUDIO_ROLE_NO_BEAT,
        )

        self.assertEqual(metadata["sourceType"], "media_file_ingest")
        self.assertEqual(metadata["scratchDisplayName"], "Chirp flare")
        self.assertEqual(metadata["scratchType"], "chirp_flare")
        self.assertEqual(metadata["bpm"], 92)
        self.assertEqual(metadata["bpmSource"], "folder_name")
        self.assertEqual(metadata["beatMode"], "noBeat")
        self.assertEqual(metadata["audioStreamRole"], "noBeat")
        self.assertEqual(metadata["audioStreamIndex"], 2)
        self.assertEqual(metadata["linkedVideoFile"], "angle_1_video.mov")
        self.assertEqual(metadata["cameraAngle"], "angle_1")
        self.assertEqual(metadata["cameraAngleCount"], 4)
        self.assertEqual(metadata["trainingUse"], "primary_training")
        self.assertTrue(metadata["hasVideo"])
        self.assertTrue(metadata["hasAudio"])
        self.assertTrue(metadata["hasExtractedWav"])

    def test_ingest_multistream_clip_creates_three_wavs(self) -> None:
        scratch_root = self.input_root / "Chirp flare_92bpm"
        self.write_fake_media_file(scratch_root / "angle_a.mov")
        audio_map_path = self.write_audio_map_file(
            {
                "default": {
                    "0:1": "withBeat",
                    "0:2": "noBeat",
                    "0:3": "beatOnly",
                }
            }
        )

        ingester = self.make_ingester(audio_map=str(audio_map_path))

        def fake_probe(source_path: Path):
            return INGEST_MEDIA_MODULE.MediaProbeInfo(
                has_video=True,
                video_stream_index=0,
                audio_streams=[
                    INGEST_MEDIA_MODULE.AudioStreamInfo(stream_index=1, codec_name="aac", duration=30.0),
                    INGEST_MEDIA_MODULE.AudioStreamInfo(stream_index=2, codec_name="aac", duration=30.0),
                    INGEST_MEDIA_MODULE.AudioStreamInfo(stream_index=3, codec_name="aac", duration=30.0),
                ],
                title=source_path.stem,
            )

        def fake_extract_video(source_path: Path, video_stream_index: int, output_path: Path) -> None:
            output_path.parent.mkdir(parents=True, exist_ok=True)
            output_path.write_bytes(b"video output")

        def fake_extract_audio(source_path: Path, stream_index: int, output_path: Path) -> None:
            self.write_wav_file(output_path, frame_count=4_800)

        with mock.patch.object(ingester, "ensure_tools", return_value=None), mock.patch.object(
            ingester,
            "probe_media_info",
            side_effect=fake_probe,
        ), mock.patch.object(
            ingester,
            "extract_video_copy",
            side_effect=fake_extract_video,
        ), mock.patch.object(
            ingester,
            "extract_audio_stream",
            side_effect=fake_extract_audio,
        ):
            result = ingester.run()

        self.assertEqual(result, 0)
        output_directory = self.output_root / "chirp_flare" / "92bpm"
        self.assertTrue((output_directory / "angle_1_video.mov").exists())
        self.assertTrue((output_directory / "angle_1_withBeat.wav").exists())
        self.assertTrue((output_directory / "angle_1_noBeat.wav").exists())
        self.assertTrue((output_directory / "angle_1_beatOnly.wav").exists())
        self.assertTrue((output_directory / "angle_1_withBeat.meta.json").exists())
        self.assertTrue((output_directory / "angle_1_noBeat.meta.json").exists())
        self.assertTrue((output_directory / "angle_1_beatOnly.meta.json").exists())

    def test_ingest_metadata_records_stream_index_and_role(self) -> None:
        scratch_root = self.input_root / "Crabs_92bpm"
        self.write_fake_media_file(scratch_root / "angle_a.mov")
        audio_map_path = self.write_audio_map_file(
            {"default": {"0:1": "withBeat", "0:2": "noBeat", "0:3": "beatOnly"}}
        )
        ingester = self.make_ingester(audio_map=str(audio_map_path))

        def fake_probe(source_path: Path):
            return INGEST_MEDIA_MODULE.MediaProbeInfo(
                has_video=True,
                video_stream_index=0,
                audio_streams=[
                    INGEST_MEDIA_MODULE.AudioStreamInfo(stream_index=1, codec_name="aac", duration=30.0),
                    INGEST_MEDIA_MODULE.AudioStreamInfo(stream_index=2, codec_name="aac", duration=30.0),
                    INGEST_MEDIA_MODULE.AudioStreamInfo(stream_index=3, codec_name="aac", duration=30.0),
                ],
                title=source_path.stem,
            )

        def fake_extract_video(source_path: Path, video_stream_index: int, output_path: Path) -> None:
            output_path.parent.mkdir(parents=True, exist_ok=True)
            output_path.write_bytes(b"video output")

        def fake_extract_audio(source_path: Path, stream_index: int, output_path: Path) -> None:
            self.write_wav_file(output_path, frame_count=4_800)

        with mock.patch.object(ingester, "ensure_tools", return_value=None), mock.patch.object(
            ingester, "probe_media_info", side_effect=fake_probe
        ), mock.patch.object(ingester, "extract_video_copy", side_effect=fake_extract_video), mock.patch.object(
            ingester, "extract_audio_stream", side_effect=fake_extract_audio
        ):
            result = ingester.run()

        self.assertEqual(result, 0)
        output_directory = self.output_root / "crabs" / "92bpm"
        with_beat_meta = json.loads((output_directory / "angle_1_withBeat.meta.json").read_text(encoding="utf-8"))
        no_beat_meta = json.loads((output_directory / "angle_1_noBeat.meta.json").read_text(encoding="utf-8"))
        beat_only_meta = json.loads((output_directory / "angle_1_beatOnly.meta.json").read_text(encoding="utf-8"))

        self.assertEqual(with_beat_meta["audioStreamIndex"], 1)
        self.assertEqual(with_beat_meta["audioStreamRole"], "withBeat")
        self.assertEqual(with_beat_meta["trainingUse"], "timing_reference")
        self.assertEqual(no_beat_meta["audioStreamIndex"], 2)
        self.assertEqual(no_beat_meta["audioStreamRole"], "noBeat")
        self.assertEqual(no_beat_meta["trainingUse"], "primary_training")
        self.assertEqual(beat_only_meta["audioStreamIndex"], 3)
        self.assertEqual(beat_only_meta["audioStreamRole"], "beatOnly")
        self.assertEqual(beat_only_meta["trainingUse"], "beat_reference")
        self.assertEqual(with_beat_meta["linkedVideoFile"], "angle_1_video.mov")

    def test_ingest_manifest_generation(self) -> None:
        scratch_root = self.input_root / "Chirp flare_92bpm"
        self.write_fake_media_file(scratch_root / "angle_a.mov")
        audio_map_path = self.write_audio_map_file(
            {"default": {"0:1": "withBeat", "0:2": "noBeat", "0:3": "beatOnly"}}
        )
        ingester = self.make_ingester(audio_map=str(audio_map_path))

        def fake_probe(source_path: Path):
            return INGEST_MEDIA_MODULE.MediaProbeInfo(
                has_video=True,
                video_stream_index=0,
                audio_streams=[
                    INGEST_MEDIA_MODULE.AudioStreamInfo(stream_index=1, codec_name="aac", duration=30.0),
                    INGEST_MEDIA_MODULE.AudioStreamInfo(stream_index=2, codec_name="aac", duration=30.0),
                    INGEST_MEDIA_MODULE.AudioStreamInfo(stream_index=3, codec_name="aac", duration=30.0),
                ],
                title=source_path.stem,
            )

        def fake_extract_video(source_path: Path, video_stream_index: int, output_path: Path) -> None:
            output_path.parent.mkdir(parents=True, exist_ok=True)
            output_path.write_bytes(b"video output")

        def fake_extract_audio(source_path: Path, stream_index: int, output_path: Path) -> None:
            self.write_wav_file(output_path, frame_count=4_800)

        with mock.patch.object(ingester, "ensure_tools", return_value=None), mock.patch.object(
            ingester, "probe_media_info", side_effect=fake_probe
        ), mock.patch.object(ingester, "extract_video_copy", side_effect=fake_extract_video), mock.patch.object(
            ingester, "extract_audio_stream", side_effect=fake_extract_audio
        ):
            result = ingester.run()

        self.assertEqual(result, 0)
        output_directory = self.output_root / "chirp_flare" / "92bpm"
        manifest = json.loads((output_directory / "manifest.json").read_text(encoding="utf-8"))
        self.assertEqual(manifest["scratchDisplayName"], "Chirp flare")
        self.assertEqual(manifest["scratchType"], "chirp_flare")
        self.assertEqual(manifest["bpm"], 92)
        self.assertEqual(manifest["bpmSource"], "folder_name")
        self.assertEqual(manifest["angleCount"], 1)
        self.assertEqual(len(manifest["generatedItems"]), 3)
        self.assertEqual(
            {item["audioStreamRole"] for item in manifest["generatedItems"]},
            {"withBeat", "noBeat", "beatOnly"},
        )
        self.assertTrue(all(item["video"] == "angle_1_video.mov" for item in manifest["generatedItems"]))

    def test_ingest_dry_run_writes_nothing(self) -> None:
        scratch_root = self.input_root / "Transformer_85bpm"
        self.write_fake_media_file(scratch_root / "angle_1.mov")
        audio_map_path = self.write_audio_map_file(
            {"default": {"0:1": "withBeat", "0:2": "noBeat", "0:3": "beatOnly"}}
        )
        ingester = self.make_ingester(dry_run=True, audio_map=str(audio_map_path))

        with mock.patch.object(ingester, "ensure_tools", return_value=None), mock.patch.object(
            ingester,
            "probe_media_info",
            return_value=INGEST_MEDIA_MODULE.MediaProbeInfo(
                has_video=True,
                video_stream_index=0,
                audio_streams=[
                    INGEST_MEDIA_MODULE.AudioStreamInfo(stream_index=1, codec_name="aac", duration=18.0),
                    INGEST_MEDIA_MODULE.AudioStreamInfo(stream_index=2, codec_name="aac", duration=18.0),
                    INGEST_MEDIA_MODULE.AudioStreamInfo(stream_index=3, codec_name="aac", duration=18.0),
                ],
                title="Title 01",
            ),
        ):
            result = ingester.run()

        self.assertEqual(result, 0)
        self.assertFalse(self.output_root.exists())

    def test_ingest_inspect_streams_writes_nothing(self) -> None:
        scratch_root = self.input_root / "Transformer_85bpm"
        self.write_fake_media_file(scratch_root / "angle_1.mov")
        audio_map_path = self.write_audio_map_file(
            {"default": {"0:1": "withBeat", "0:2": "noBeat", "0:3": "beatOnly"}}
        )
        ingester = self.make_ingester(inspect_streams=True, audio_map=str(audio_map_path))

        stdout = io.StringIO()
        with mock.patch.object(ingester, "ensure_tools", return_value=None), mock.patch.object(
            ingester,
            "probe_media_info",
            return_value=INGEST_MEDIA_MODULE.MediaProbeInfo(
                has_video=True,
                video_stream_index=0,
                audio_streams=[
                    INGEST_MEDIA_MODULE.AudioStreamInfo(stream_index=1, codec_name="aac", duration=18.0),
                    INGEST_MEDIA_MODULE.AudioStreamInfo(stream_index=2, codec_name="aac", duration=18.0),
                    INGEST_MEDIA_MODULE.AudioStreamInfo(stream_index=3, codec_name="aac", duration=18.0),
                ],
                title="Title 01",
            ),
        ), mock.patch("sys.stdout", stdout):
            result = ingester.run()

        self.assertEqual(result, 0)
        self.assertIn("proposedRole=withBeat", stdout.getvalue())
        self.assertIn("proposedRole=noBeat", stdout.getvalue())
        self.assertIn("proposedRole=beatOnly", stdout.getvalue())
        self.assertFalse(self.output_root.exists())

    def test_ingest_filename_only_classification_is_not_used_when_multiple_audio_streams_exist(self) -> None:
        source_clip = INGEST_MEDIA_MODULE.SourceClip(
            source_path=self.input_root / "Crabs_92bpm" / "beat performance.mov",
            probe_info=INGEST_MEDIA_MODULE.MediaProbeInfo(
                has_video=True,
                video_stream_index=0,
                audio_streams=[
                    INGEST_MEDIA_MODULE.AudioStreamInfo(stream_index=1, codec_name="aac", duration=30.0),
                    INGEST_MEDIA_MODULE.AudioStreamInfo(stream_index=2, codec_name="aac", duration=30.0),
                    INGEST_MEDIA_MODULE.AudioStreamInfo(stream_index=3, codec_name="aac", duration=30.0),
                ],
            ),
            camera_angle="angle_1",
        )
        ingester = self.make_ingester()

        resolved_role = ingester.resolve_audio_stream_role(
            folder_path=self.input_root / "Crabs_92bpm",
            source_clip=source_clip,
            audio_stream=source_clip.probe_info.audio_streams[0],
        )

        self.assertIsNone(resolved_role)

    def test_ingest_isolated_scratch_is_not_emitted_anywhere(self) -> None:
        scratch_root = self.input_root / "Dicing_85bpm"
        self.write_fake_media_file(scratch_root / "angle_a.mov")
        audio_map_path = self.write_audio_map_file(
            {"default": {"0:1": "withBeat", "0:2": "noBeat", "0:3": "beatOnly"}}
        )
        ingester = self.make_ingester(audio_map=str(audio_map_path))

        def fake_probe(source_path: Path):
            return INGEST_MEDIA_MODULE.MediaProbeInfo(
                has_video=True,
                video_stream_index=0,
                audio_streams=[
                    INGEST_MEDIA_MODULE.AudioStreamInfo(stream_index=1, codec_name="aac", duration=30.0),
                    INGEST_MEDIA_MODULE.AudioStreamInfo(stream_index=2, codec_name="aac", duration=30.0),
                    INGEST_MEDIA_MODULE.AudioStreamInfo(stream_index=3, codec_name="aac", duration=30.0),
                ],
                title=source_path.stem,
            )

        def fake_extract_video(source_path: Path, video_stream_index: int, output_path: Path) -> None:
            output_path.parent.mkdir(parents=True, exist_ok=True)
            output_path.write_bytes(b"video output")

        def fake_extract_audio(source_path: Path, stream_index: int, output_path: Path) -> None:
            self.write_wav_file(output_path, frame_count=4_800)

        with mock.patch.object(ingester, "ensure_tools", return_value=None), mock.patch.object(
            ingester, "probe_media_info", side_effect=fake_probe
        ), mock.patch.object(ingester, "extract_video_copy", side_effect=fake_extract_video), mock.patch.object(
            ingester, "extract_audio_stream", side_effect=fake_extract_audio
        ):
            result = ingester.run()

        self.assertEqual(result, 0)
        output_directory = self.output_root / "dicing" / "85bpm"
        output_names = {path.name for path in output_directory.iterdir()}
        self.assertFalse(any("isolatedScratch" in name for name in output_names))


if __name__ == "__main__":
    unittest.main()
