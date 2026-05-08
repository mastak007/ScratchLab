#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import shutil
import subprocess
import sys
import tempfile
import warnings
import uuid
import wave
import zipfile
from collections import Counter, defaultdict
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

with warnings.catch_warnings():
    warnings.simplefilter("ignore", DeprecationWarning)
    try:
        import aifc  # type: ignore[attr-defined]
    except ModuleNotFoundError:  # pragma: no cover - removed in newer Python versions
        aifc = None


AUDIO_SUFFIXES = {".wav", ".aiff", ".mp3", ".m4a"}
VIDEO_SUFFIXES = {".mp4", ".mov"}
MEDIA_SUFFIXES = AUDIO_SUFFIXES | VIDEO_SUFFIXES

SCRATCH_TYPE_ALIASES: dict[str, set[str]] = {
    "baby": {"baby", "baby_scratch", "baby scratch"},
    "forward_scratch": {"forward_scratch", "forward scratch"},
    "backward_scratch": {
        "backward_scratch",
        "backward scratch",
        "reverse_cutting",
        "reverse cutting",
        "reversecutting",
    },
    "release_scratch": {"release_scratch", "release scratch"},
    "tear": {"tear"},
    "chirp": {"chirp"},
    "scribble": {"scribble"},
    "stab": {
        "stab",
        "tip",
        "tips",
    },
    "transform": {"transform"},
    "crab": {"crab"},
    "flare_1click": {
        "flare_1click",
        "1 click flare",
        "1-click flare",
        "flare1click",
        "originalflare",
        "original_flare",
        "original flare",
        "original 1-click flare",
    },
    "orbit": {"orbit"},
    "flare_2click": {"flare_2click", "2 click flare", "2-click flare", "flare2click"},
    "twiddle": {"twiddle"},
    "boomerang": {"boomerang"},
    "hydroplane": {"hydroplane"},
    "flare_3click": {"flare_3click", "3 click flare", "3-click flare", "flare3click"},
    "autobahn": {"autobahn"},
    "military": {"military"},
    "prizm": {"prizm"},
    "combo_l1": {"combo_l1", "combo l1"},
    "combo_l2": {"combo_l2", "combo l2"},
    "combo_l3": {"combo_l3", "combo l3"},
    "combo_l4": {"combo_l4", "combo l4"},
    "combo_l5": {"combo_l5", "combo l5"},
}

SCRATCH_TYPE_LOOKUP: dict[str, str] = {}
for canonical_name, aliases in SCRATCH_TYPE_ALIASES.items():
    for alias in aliases | {canonical_name}:
        normalized_alias = "".join(
            character if character.isalnum() else "_"
            for character in alias.strip().lower()
        )
        while "__" in normalized_alias:
            normalized_alias = normalized_alias.replace("__", "_")
        SCRATCH_TYPE_LOOKUP[normalized_alias.strip("_")] = canonical_name

REQUIRED_LOOSE_FIELDS = (
    "performer",
    "scratchType",
    "bpm",
    "beatMode",
    "labelSource",
    "confidence",
    "notes",
    "startTime",
    "endTime",
)

PROCESSOR_SCHEMA_VERSION = "scratchlab_dataset_processor_v1"


@dataclass
class CopySpec:
    source: Path
    target_name: str


@dataclass
class CandidateResult:
    metadata: dict[str, Any]
    source_paths: list[Path]
    process_copy_specs: list[CopySpec] = field(default_factory=list)
    warnings: list[str] = field(default_factory=list)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Validate or process ScratchLab exports and labeled loose clips into an offline dataset."
    )
    parser.add_argument("--input", required=True, help="Path to a directory containing ZIP exports and/or loose clips.")
    parser.add_argument("--output", required=True, help="Path to the processed dataset output directory.")
    parser.add_argument(
        "--mode",
        required=True,
        choices=("validate", "process"),
        help="Use validate to inspect inputs without copying media, or process to materialize accepted/rejected output.",
    )
    parser.add_argument(
        "--allow-loose-clips",
        action="store_true",
        help="Allow loose audio/video clips with sidecar metadata to be scanned.",
    )
    parser.add_argument(
        "--allow-unlabeled",
        action="store_true",
        help="Permit unlabeled loose clips to be scanned and routed into rejected/unlabeled instead of failing early.",
    )
    return parser.parse_args()


def iso8601_now() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def write_json(path: Path, payload: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temp_path = path.parent / f".{path.name}.tmp"
    with temp_path.open("w", encoding="utf-8") as handle:
        json.dump(payload, handle, indent=2, sort_keys=True)
        handle.write("\n")
    temp_path.replace(path)


def read_json(path: Path) -> Any:
    with path.open("r", encoding="utf-8") as handle:
        return json.load(handle)


def normalize_label(value: str) -> str:
    normalized = "".join(character if character.isalnum() else "_" for character in value.strip().lower())
    while "__" in normalized:
        normalized = normalized.replace("__", "_")
    return normalized.strip("_")


def normalize_scratch_type(value: Any) -> str | None:
    if not isinstance(value, str):
        return None
    token = normalize_label(value)
    return SCRATCH_TYPE_LOOKUP.get(token)


def is_unlabeled_metadata(payload: dict[str, Any]) -> bool:
    scratch_token = normalize_label(str(payload.get("scratchType", "")))
    label_source_token = normalize_label(str(payload.get("labelSource", "")))
    return scratch_token == "unlabeled" or label_source_token == "unlabeled"


def sanitize_path_token(value: str) -> str:
    token = "".join(character if character.isalnum() or character in {"-", "_"} else "_" for character in value)
    while "__" in token:
        token = token.replace("__", "_")
    token = token.strip("_")
    return token or "item"


def maybe_relative_to(path: Path, root: Path) -> str:
    try:
        return str(path.relative_to(root))
    except ValueError:
        return path.name


def parse_optional_float(value: Any, *, field_name: str) -> tuple[float | None, str | None]:
    if value is None:
        return None, None
    if isinstance(value, (int, float)):
        return float(value), None
    try:
        return float(str(value)), None
    except (TypeError, ValueError):
        return None, f"{field_name} must be a number or null."


def probe_duration_seconds(path: Path, ffprobe_path: str | None) -> float | None:
    suffix = path.suffix.lower()

    if suffix == ".wav":
        try:
            with wave.open(str(path), "rb") as handle:
                frame_rate = handle.getframerate()
                if frame_rate <= 0:
                    return None
                return handle.getnframes() / float(frame_rate)
        except (wave.Error, OSError):
            return None

    if suffix == ".aiff" and aifc is not None:
        try:
            with aifc.open(str(path), "rb") as handle:
                frame_rate = handle.getframerate()
                if frame_rate <= 0:
                    return None
                return handle.getnframes() / float(frame_rate)
        except (aifc.Error, OSError):
            return None

    if ffprobe_path is None:
        return None

    try:
        result = subprocess.run(
            [
                ffprobe_path,
                "-v",
                "error",
                "-show_entries",
                "format=duration",
                "-of",
                "json",
                str(path),
            ],
            capture_output=True,
            text=True,
            check=False,
            timeout=10,
        )
    except (OSError, subprocess.SubprocessError):
        return None

    if result.returncode != 0:
        return None

    try:
        payload = json.loads(result.stdout or "{}")
        duration_value = payload.get("format", {}).get("duration")
        if duration_value is None:
            return None
        return float(duration_value)
    except (TypeError, ValueError, json.JSONDecodeError):
        return None


class DatasetProcessor:
    def __init__(self, args: argparse.Namespace) -> None:
        self.input_path = Path(args.input).expanduser().resolve()
        self.output_path = Path(args.output).expanduser().resolve()
        self.mode = args.mode
        self.allow_loose_clips = bool(args.allow_loose_clips)
        self.allow_unlabeled = bool(args.allow_unlabeled)
        self.ffprobe_path = shutil.which("ffprobe")
        self.accepted_manifest_entries: list[dict[str, Any]] = []
        self.rejected_manifest_entries: list[dict[str, Any]] = []
        self.accepted_counters: Counter[tuple[str, int]] = Counter()
        self.rejected_counters: Counter[str] = Counter()
        self.total_warnings = 0

    def run(self) -> int:
        if not self.input_path.exists():
            print(f"Input path does not exist: {self.input_path}", file=sys.stderr)
            return 1

        self.output_path.mkdir(parents=True, exist_ok=True)

        zip_paths, loose_groups = self.find_inputs()
        if not zip_paths and not loose_groups:
            self.write_manifest()
            print("No supported input files were found.", file=sys.stderr)
            return 1

        for zip_path in zip_paths:
            self.process_scratchlab_zip(zip_path)

        for group in loose_groups:
            self.process_loose_group(group)

        manifest_path = self.write_manifest()

        print(f"Accepted items: {len(self.accepted_manifest_entries)}")
        print(f"Rejected items: {len(self.rejected_manifest_entries)}")
        print(f"Manifest written to: {manifest_path}")

        if self.mode == "validate" and self.rejected_manifest_entries:
            print("Validation found rejected items.", file=sys.stderr)
            return 1

        return 0

    def find_inputs(self) -> tuple[list[Path], list[dict[str, Any]]]:
        if self.input_path.is_file():
            if self.input_path.suffix.lower() == ".zip":
                return [self.input_path], []
            return [], self.find_loose_groups([self.input_path])

        zip_paths: list[Path] = []
        loose_files: list[Path] = []
        for path in sorted(self.input_path.rglob("*")):
            if not path.is_file():
                continue
            if self.is_ignored_path(path):
                continue

            suffix = path.suffix.lower()
            lower_name = path.name.lower()
            if suffix == ".zip":
                zip_paths.append(path)
            elif suffix in MEDIA_SUFFIXES or lower_name.endswith(".meta.json") or lower_name.endswith(".motion.json"):
                loose_files.append(path)

        return zip_paths, self.find_loose_groups(loose_files)

    def is_ignored_path(self, path: Path) -> bool:
        try:
            path.relative_to(self.output_path)
            return True
        except ValueError:
            return False

    def find_loose_groups(self, candidate_paths: list[Path]) -> list[dict[str, Any]]:
        groups: dict[tuple[Path, str], dict[str, Any]] = {}

        for path in candidate_paths:
            lower_name = path.name.lower()
            group_base_name: str | None = None
            if lower_name.endswith(".meta.json"):
                group_base_name = path.name[: -len(".meta.json")]
            elif lower_name.endswith(".motion.json"):
                group_base_name = path.name[: -len(".motion.json")]
            elif path.suffix.lower() in MEDIA_SUFFIXES:
                group_base_name = path.stem

            if group_base_name is None:
                continue

            key = (path.parent, group_base_name)
            group = groups.setdefault(
                key,
                {
                    "base_name": group_base_name,
                    "directory": path.parent,
                    "audio": [],
                    "video": [],
                    "meta": None,
                    "motion": None,
                },
            )

            if lower_name.endswith(".meta.json"):
                group["meta"] = path
            elif lower_name.endswith(".motion.json"):
                group["motion"] = path
            elif path.suffix.lower() in AUDIO_SUFFIXES:
                group["audio"].append(path)
            elif path.suffix.lower() in VIDEO_SUFFIXES:
                group["video"].append(path)

        return sorted(
            groups.values(),
            key=lambda group: (
                maybe_relative_to(group["directory"], self.input_path),
                group["base_name"],
            ),
        )

    def process_loose_group(self, group: dict[str, Any]) -> None:
        media_paths = sorted(group["audio"]) + sorted(group["video"])
        if not media_paths:
            return

        sidecar_paths = [path for path in [group["meta"], group["motion"]] if isinstance(path, Path)]
        all_source_paths = media_paths + sidecar_paths
        primary_source = sorted(group["video"] or group["audio"])[0]
        base_metadata = self.base_metadata(
            source_type="loose_clip",
            source_file=primary_source.name,
            source_files=[path.name for path in sorted(all_source_paths)],
            performer="unknown",
            scratch_type=None,
            bpm=None,
            beat_mode=None,
            label_source=None,
            confidence=None,
            session_id=None,
            take_id=None,
            has_audio=bool(group["audio"]),
            has_video=bool(group["video"]),
            has_motion=group["motion"] is not None,
            start_time=None,
            end_time=None,
            duration=None,
            notes="",
            segmentation="whole_clip",
        )

        if not self.allow_loose_clips:
            self.record_rejected(
                CandidateResult(
                    metadata={
                        **base_metadata,
                        "validationStatus": "rejected",
                        "rejectionReason": "loose_clips_not_allowed",
                    },
                    source_paths=all_source_paths,
                ),
                reason="loose_clips_not_allowed",
            )
            return

        if len(group["audio"]) > 1:
            self.record_rejected(
                CandidateResult(
                    metadata={
                        **base_metadata,
                        "validationStatus": "rejected",
                        "rejectionReason": "duplicate_audio_sources",
                    },
                    source_paths=all_source_paths,
                ),
                reason="duplicate_audio_sources",
            )
            return

        if len(group["video"]) > 1:
            self.record_rejected(
                CandidateResult(
                    metadata={
                        **base_metadata,
                        "validationStatus": "rejected",
                        "rejectionReason": "duplicate_video_sources",
                    },
                    source_paths=all_source_paths,
                ),
                reason="duplicate_video_sources",
            )
            return

        meta_path = group["meta"]
        if meta_path is None:
            rejection_reason = "unlabeled" if self.allow_unlabeled else "missing_metadata"
            self.record_rejected(
                CandidateResult(
                    metadata={
                        **base_metadata,
                        "validationStatus": "rejected",
                        "rejectionReason": rejection_reason,
                    },
                    source_paths=all_source_paths,
                ),
                reason=rejection_reason,
            )
            return

        try:
            loose_metadata = read_json(meta_path)
        except (OSError, json.JSONDecodeError):
            self.record_rejected(
                CandidateResult(
                    metadata={
                        **base_metadata,
                        "validationStatus": "rejected",
                        "rejectionReason": "invalid_metadata_json",
                    },
                    source_paths=all_source_paths,
                ),
                reason="invalid_metadata_json",
            )
            return

        metadata_errors, normalized_fields, rejection_reason = self.validate_loose_metadata(loose_metadata)
        if rejection_reason is not None:
            self.record_rejected(
                CandidateResult(
                    metadata={
                        **base_metadata,
                        **normalized_fields,
                        "validationStatus": "rejected",
                        "rejectionReason": rejection_reason,
                        "validationErrors": metadata_errors,
                    },
                    source_paths=all_source_paths,
                ),
                reason=rejection_reason,
            )
            return

        duration_candidates = [
            probe_duration_seconds(path, self.ffprobe_path)
            for path in [*(group["video"]), *(group["audio"])]
        ]
        duration = next((value for value in duration_candidates if value is not None), None)
        warnings: list[str] = []
        if duration is None:
            warnings.append("duration_unavailable")

        copy_specs: list[CopySpec] = []
        if group["audio"]:
            audio_path = group["audio"][0]
            copy_specs.append(CopySpec(audio_path, f"audio{audio_path.suffix.lower()}"))
        if group["video"]:
            video_path = group["video"][0]
            copy_specs.append(CopySpec(video_path, f"video{video_path.suffix.lower()}"))
        if group["motion"] is not None:
            motion_path = group["motion"]
            copy_specs.append(CopySpec(motion_path, f"motion{motion_path.suffix.lower()}"))

        candidate = CandidateResult(
            metadata={
                **base_metadata,
                **normalized_fields,
                "duration": duration,
                "validationStatus": "accepted",
                "rejectionReason": None,
            },
            source_paths=all_source_paths,
            process_copy_specs=copy_specs,
            warnings=warnings,
        )
        self.record_accepted(candidate)

    def validate_loose_metadata(self, payload: Any) -> tuple[list[str], dict[str, Any], str | None]:
        errors: list[str] = []
        normalized: dict[str, Any] = {}

        if not isinstance(payload, dict):
            return ["Loose sidecar must be a JSON object."], normalized, "invalid_metadata"

        for field_name in REQUIRED_LOOSE_FIELDS:
            if field_name not in payload:
                errors.append(f"{field_name} is required.")

        performer = str(payload.get("performer", "")).strip()
        if not performer:
            errors.append("performer is required.")
        normalized["performer"] = performer or "unknown"

        beat_mode = str(payload.get("beatMode", "")).strip()
        if not beat_mode:
            errors.append("beatMode is required.")
        normalized["beatMode"] = beat_mode or None

        label_source = str(payload.get("labelSource", "")).strip()
        if not label_source:
            errors.append("labelSource is required.")
        normalized["labelSource"] = label_source or None

        try:
            bpm = int(payload.get("bpm"))
            if bpm <= 0:
                raise ValueError
            normalized["bpm"] = bpm
        except (TypeError, ValueError):
            errors.append("bpm must be a positive integer.")
            normalized["bpm"] = None

        try:
            confidence = float(payload.get("confidence"))
            if confidence < 0 or confidence > 1:
                raise ValueError
            normalized["confidence"] = confidence
        except (TypeError, ValueError):
            errors.append("confidence must be a number between 0.0 and 1.0.")
            normalized["confidence"] = None

        notes = payload.get("notes", "")
        if notes is None:
            notes = ""
        if not isinstance(notes, str):
            errors.append("notes must be a string.")
            notes = str(notes)
        normalized["notes"] = notes

        start_time, start_time_error = parse_optional_float(payload.get("startTime"), field_name="startTime")
        if start_time_error or start_time is None:
            errors.append(start_time_error or "startTime is required.")
        normalized["startTime"] = start_time

        end_time, end_time_error = parse_optional_float(payload.get("endTime"), field_name="endTime")
        if end_time_error:
            errors.append(end_time_error)
        if start_time is not None and end_time is not None and end_time < start_time:
            errors.append("endTime cannot be earlier than startTime.")
        normalized["endTime"] = end_time

        scratch_type = normalize_scratch_type(payload.get("scratchType"))
        unlabeled = is_unlabeled_metadata(payload)
        if unlabeled:
            return errors, normalized, "unlabeled"
        if scratch_type is None:
            errors.append("scratchType must use a supported ScratchLab scratch label.")
            return errors, normalized, "unknown_scratch_type"
        normalized["scratchType"] = scratch_type

        if errors:
            return errors, normalized, "invalid_metadata"

        return errors, normalized, None

    def process_scratchlab_zip(self, zip_path: Path) -> None:
        with tempfile.TemporaryDirectory(prefix="scratchlab_dataset_zip_") as temporary_directory:
            extraction_root = Path(temporary_directory) / "unzipped"
            try:
                with zipfile.ZipFile(zip_path, "r") as archive:
                    archive.extractall(extraction_root)
            except (OSError, zipfile.BadZipFile):
                self.record_rejected(
                    CandidateResult(
                        metadata={
                            **self.base_metadata(
                                source_type="scratchlab_zip",
                                source_file=zip_path.name,
                                source_files=[zip_path.name],
                                performer="unknown",
                                scratch_type=None,
                                bpm=None,
                                beat_mode=None,
                                label_source="scratchlab_export",
                                confidence=1.0,
                                session_id=None,
                                take_id=None,
                                has_audio=False,
                                has_video=False,
                                has_motion=False,
                                start_time=None,
                                end_time=None,
                                duration=None,
                                notes="",
                                segmentation="whole_take",
                            ),
                            "validationStatus": "rejected",
                            "rejectionReason": "invalid_scratchlab_zip",
                        },
                        source_paths=[zip_path],
                    ),
                    reason="invalid_scratchlab_zip",
                )
                return

            manifest_paths = [
                path for path in extraction_root.rglob("session_manifest.json") if path.parent.name == "manifests"
            ]
            if len(manifest_paths) != 1:
                self.record_rejected(
                    CandidateResult(
                        metadata={
                            **self.base_metadata(
                                source_type="scratchlab_zip",
                                source_file=zip_path.name,
                                source_files=[zip_path.name],
                                performer="unknown",
                                scratch_type=None,
                                bpm=None,
                                beat_mode=None,
                                label_source="scratchlab_export",
                                confidence=1.0,
                                session_id=None,
                                take_id=None,
                                has_audio=False,
                                has_video=False,
                                has_motion=False,
                                start_time=None,
                                end_time=None,
                                duration=None,
                                notes="",
                                segmentation="whole_take",
                            ),
                            "validationStatus": "rejected",
                            "rejectionReason": "invalid_scratchlab_zip",
                        },
                        source_paths=[zip_path],
                    ),
                    reason="invalid_scratchlab_zip",
                )
                return

            session_root = manifest_paths[0].parent.parent
            manifest_path = manifest_paths[0]
            take_log_path = manifest_path.parent / "take_log.csv"
            session_metadata_path = manifest_path.parent / "session_metadata.json"

            if not take_log_path.exists() or not session_metadata_path.exists():
                self.record_rejected(
                    CandidateResult(
                        metadata={
                            **self.base_metadata(
                                source_type="scratchlab_zip",
                                source_file=zip_path.name,
                                source_files=[zip_path.name],
                                performer="unknown",
                                scratch_type=None,
                                bpm=None,
                                beat_mode=None,
                                label_source="scratchlab_export",
                                confidence=1.0,
                                session_id=None,
                                take_id=None,
                                has_audio=False,
                                has_video=False,
                                has_motion=False,
                                start_time=None,
                                end_time=None,
                                duration=None,
                                notes="",
                                segmentation="whole_take",
                            ),
                            "validationStatus": "rejected",
                            "rejectionReason": "invalid_scratchlab_zip",
                        },
                        source_paths=[zip_path],
                    ),
                    reason="invalid_scratchlab_zip",
                )
                return

            try:
                session_manifest = read_json(manifest_path)
                session_metadata_document = read_json(session_metadata_path)
            except (OSError, json.JSONDecodeError):
                self.record_rejected(
                    CandidateResult(
                        metadata={
                            **self.base_metadata(
                                source_type="scratchlab_zip",
                                source_file=zip_path.name,
                                source_files=[zip_path.name],
                                performer="unknown",
                                scratch_type=None,
                                bpm=None,
                                beat_mode=None,
                                label_source="scratchlab_export",
                                confidence=1.0,
                                session_id=None,
                                take_id=None,
                                has_audio=False,
                                has_video=False,
                                has_motion=False,
                                start_time=None,
                                end_time=None,
                                duration=None,
                                notes="",
                                segmentation="whole_take",
                            ),
                            "validationStatus": "rejected",
                            "rejectionReason": "invalid_scratchlab_zip",
                        },
                        source_paths=[zip_path],
                    ),
                    reason="invalid_scratchlab_zip",
                )
                return

            session_section = session_metadata_document.get("session")
            take_sections = session_metadata_document.get("takes")
            if not isinstance(session_section, dict) or not isinstance(take_sections, list):
                self.record_rejected(
                    CandidateResult(
                        metadata={
                            **self.base_metadata(
                                source_type="scratchlab_zip",
                                source_file=zip_path.name,
                                source_files=[zip_path.name],
                                performer="unknown",
                                scratch_type=None,
                                bpm=None,
                                beat_mode=None,
                                label_source="scratchlab_export",
                                confidence=1.0,
                                session_id=None,
                                take_id=None,
                                has_audio=False,
                                has_video=False,
                                has_motion=False,
                                start_time=None,
                                end_time=None,
                                duration=None,
                                notes="",
                                segmentation="whole_take",
                            ),
                            "validationStatus": "rejected",
                            "rejectionReason": "invalid_scratchlab_zip",
                        },
                        source_paths=[zip_path],
                    ),
                    reason="invalid_scratchlab_zip",
                )
                return

            session_id = str(session_section.get("sessionID", "")).strip()
            if not session_id:
                self.record_rejected(
                    CandidateResult(
                        metadata={
                            **self.base_metadata(
                                source_type="scratchlab_zip",
                                source_file=zip_path.name,
                                source_files=[zip_path.name],
                                performer="unknown",
                                scratch_type=None,
                                bpm=None,
                                beat_mode=None,
                                label_source="scratchlab_export",
                                confidence=1.0,
                                session_id=None,
                                take_id=None,
                                has_audio=False,
                                has_video=False,
                                has_motion=False,
                                start_time=None,
                                end_time=None,
                                duration=None,
                                notes="",
                                segmentation="whole_take",
                            ),
                            "validationStatus": "rejected",
                            "rejectionReason": "invalid_scratchlab_zip",
                        },
                        source_paths=[zip_path],
                    ),
                    reason="invalid_scratchlab_zip",
                )
                return

            take_lookup: dict[tuple[int | None, int | None], dict[str, Any]] = {}
            for take_section in take_sections:
                if not isinstance(take_section, dict):
                    continue
                bpm_value = take_section.get("bpm")
                take_number_value = take_section.get("takeNumber")
                try:
                    take_key = (
                        int(bpm_value) if bpm_value is not None else None,
                        int(take_number_value) if take_number_value is not None else None,
                    )
                except (TypeError, ValueError):
                    continue
                take_lookup[take_key] = take_section

            takes = session_manifest.get("takes")
            if not isinstance(takes, list):
                self.record_rejected(
                    CandidateResult(
                        metadata={
                            **self.base_metadata(
                                source_type="scratchlab_zip",
                                source_file=zip_path.name,
                                source_files=[zip_path.name],
                                performer="unknown",
                                scratch_type=None,
                                bpm=None,
                                beat_mode=None,
                                label_source="scratchlab_export",
                                confidence=1.0,
                                session_id=session_id,
                                take_id=None,
                                has_audio=False,
                                has_video=False,
                                has_motion=False,
                                start_time=None,
                                end_time=None,
                                duration=None,
                                notes="",
                                segmentation="whole_take",
                            ),
                            "validationStatus": "rejected",
                            "rejectionReason": "invalid_scratchlab_zip",
                        },
                        source_paths=[zip_path],
                    ),
                    reason="invalid_scratchlab_zip",
                )
                return

            for take_record in takes:
                self.process_scratchlab_take(
                    zip_path=zip_path,
                    session_root=session_root,
                    session_section=session_section,
                    take_record=take_record,
                    take_lookup=take_lookup,
                )

    def process_scratchlab_take(
        self,
        *,
        zip_path: Path,
        session_root: Path,
        session_section: dict[str, Any],
        take_record: Any,
        take_lookup: dict[tuple[int | None, int | None], dict[str, Any]],
    ) -> None:
        performer = str(session_section.get("performerName") or "unknown").strip() or "unknown"
        session_id = str(session_section.get("sessionID") or "").strip() or None
        notes = str(session_section.get("notes") or "").strip()
        beat_mode = str(session_section.get("beatEngineMode") or "").strip() or None

        if not isinstance(take_record, dict):
            self.record_rejected(
                CandidateResult(
                    metadata={
                        **self.base_metadata(
                            source_type="scratchlab_zip",
                            source_file=zip_path.name,
                            source_files=[zip_path.name],
                            performer=performer,
                            scratch_type=None,
                            bpm=None,
                            beat_mode=beat_mode,
                            label_source="scratchlab_export",
                            confidence=1.0,
                            session_id=session_id,
                            take_id=None,
                            has_audio=False,
                            has_video=False,
                            has_motion=False,
                            start_time=0.0,
                            end_time=None,
                            duration=None,
                            notes=notes,
                            segmentation="whole_take",
                        ),
                        "validationStatus": "rejected",
                        "rejectionReason": "invalid_scratchlab_zip",
                    },
                    source_paths=[zip_path],
                ),
                reason="invalid_scratchlab_zip",
            )
            return

        try:
            bpm = int(take_record.get("bpm"))
            take_number = int(take_record.get("take_number"))
        except (TypeError, ValueError):
            self.record_rejected(
                CandidateResult(
                    metadata={
                        **self.base_metadata(
                            source_type="scratchlab_zip",
                            source_file=zip_path.name,
                            source_files=[zip_path.name],
                            performer=performer,
                            scratch_type=None,
                            bpm=None,
                            beat_mode=beat_mode,
                            label_source="scratchlab_export",
                            confidence=1.0,
                            session_id=session_id,
                            take_id=None,
                            has_audio=False,
                            has_video=False,
                            has_motion=False,
                            start_time=0.0,
                            end_time=None,
                            duration=None,
                            notes=notes,
                            segmentation="whole_take",
                        ),
                        "validationStatus": "rejected",
                        "rejectionReason": "invalid_scratchlab_zip",
                    },
                    source_paths=[zip_path],
                ),
                reason="invalid_scratchlab_zip",
            )
            return

        take_section = take_lookup.get((bpm, take_number), {})
        take_id = str(take_section.get("takeID") or "").strip() or None
        take_beat_mode = str(take_section.get("beatEngineMode") or beat_mode or "").strip() or None
        scratch_type = normalize_scratch_type(
            take_record.get("scratch_type")
            or session_section.get("scratchTypeID")
            or session_section.get("scratchTypeName")
        )

        base_metadata = self.base_metadata(
            source_type="scratchlab_zip",
            source_file=zip_path.name,
            source_files=[zip_path.name],
            performer=performer,
            scratch_type=scratch_type,
            bpm=bpm,
            beat_mode=take_beat_mode,
            label_source="scratchlab_export",
            confidence=1.0,
            session_id=session_id,
            take_id=take_id,
            has_audio=False,
            has_video=False,
            has_motion=False,
            start_time=0.0,
            end_time=None,
            duration=None,
            notes=notes,
            segmentation="whole_take",
        )

        if scratch_type is None:
            self.record_rejected(
                CandidateResult(
                    metadata={
                        **base_metadata,
                        "validationStatus": "rejected",
                        "rejectionReason": "unknown_scratch_type",
                    },
                    source_paths=[zip_path],
                ),
                reason="unknown_scratch_type",
            )
            return

        files = take_record.get("files") if isinstance(take_record.get("files"), dict) else {}
        artifacts = take_record.get("artifacts") if isinstance(take_record.get("artifacts"), dict) else {}

        def relative_asset_path(source_key: str) -> str | None:
            value = files.get(source_key)
            if isinstance(value, str) and value:
                return value
            artifact_record = artifacts.get(source_key)
            if isinstance(artifact_record, dict):
                artifact_path = artifact_record.get("path")
                if isinstance(artifact_path, str) and artifact_path:
                    return artifact_path
            return None

        video_relative = relative_asset_path("camA")
        secondary_video_relative = relative_asset_path("camB")
        audio_relative = relative_asset_path("serato")
        motion_relative = relative_asset_path("watch")

        if not video_relative or not audio_relative:
            self.record_rejected(
                CandidateResult(
                    metadata={
                        **base_metadata,
                        "validationStatus": "rejected",
                        "rejectionReason": "missing_required_files",
                    },
                    source_paths=[zip_path],
                ),
                reason="missing_required_files",
            )
            return

        video_path = session_root / video_relative
        audio_path = session_root / audio_relative
        secondary_video_path = session_root / secondary_video_relative if secondary_video_relative else None
        motion_path = session_root / motion_relative if motion_relative else None

        if not video_path.exists() or not audio_path.exists():
            self.record_rejected(
                CandidateResult(
                    metadata={
                        **base_metadata,
                        "validationStatus": "rejected",
                        "rejectionReason": "missing_required_files",
                    },
                    source_paths=[zip_path],
                ),
                reason="missing_required_files",
            )
            return

        motion_expected = str(take_record.get("watch_source") or "").strip().lower() == "watch"
        if motion_expected and (motion_path is None or not motion_path.exists()):
            self.record_rejected(
                CandidateResult(
                    metadata={
                        **base_metadata,
                        "validationStatus": "rejected",
                        "rejectionReason": "missing_motion_artifact",
                    },
                    source_paths=[zip_path],
                ),
                reason="missing_motion_artifact",
            )
            return

        duration = self.take_duration_from_artifacts(artifacts, audio_path=audio_path, video_path=video_path)
        warnings: list[str] = []
        if duration is None:
            warnings.append("duration_unavailable")

        source_files = [zip_path.name, video_relative, audio_relative]
        copy_specs = [
            CopySpec(audio_path, f"audio{audio_path.suffix.lower()}"),
            CopySpec(video_path, f"video{video_path.suffix.lower()}"),
        ]

        if secondary_video_path is not None and secondary_video_path.exists():
            source_files.append(secondary_video_relative or secondary_video_path.name)
            copy_specs.append(CopySpec(secondary_video_path, f"video_camB{secondary_video_path.suffix.lower()}"))

        if motion_path is not None and motion_path.exists():
            source_files.append(motion_relative or motion_path.name)
            copy_specs.append(CopySpec(motion_path, f"motion{motion_path.suffix.lower()}"))

        candidate = CandidateResult(
            metadata={
                **base_metadata,
                "sourceFiles": source_files,
                "hasAudio": True,
                "hasVideo": True,
                "hasMotion": motion_path is not None and motion_path.exists(),
                "duration": duration,
                "validationStatus": "accepted",
                "rejectionReason": None,
            },
            source_paths=[zip_path],
            process_copy_specs=copy_specs,
            warnings=warnings,
        )
        self.record_accepted(candidate)

    def take_duration_from_artifacts(
        self,
        artifacts: dict[str, Any],
        *,
        audio_path: Path,
        video_path: Path,
    ) -> float | None:
        for source_key in ("serato", "camA"):
            artifact_record = artifacts.get(source_key)
            if not isinstance(artifact_record, dict):
                continue
            probe = artifact_record.get("probe")
            if not isinstance(probe, dict):
                continue
            duration_value = probe.get("duration_seconds")
            if isinstance(duration_value, (int, float)):
                return float(duration_value)

        return probe_duration_seconds(audio_path, self.ffprobe_path) or probe_duration_seconds(video_path, self.ffprobe_path)

    def base_metadata(
        self,
        *,
        source_type: str,
        source_file: str,
        source_files: list[str],
        performer: str,
        scratch_type: str | None,
        bpm: int | None,
        beat_mode: str | None,
        label_source: str | None,
        confidence: float | None,
        session_id: str | None,
        take_id: str | None,
        has_audio: bool,
        has_video: bool,
        has_motion: bool,
        start_time: float | None,
        end_time: float | None,
        duration: float | None,
        notes: str,
        segmentation: str,
    ) -> dict[str, Any]:
        return {
            "datasetItemID": uuid.uuid4().hex,
            "sourceType": source_type,
            "sourceFile": source_file,
            "sourceFiles": source_files,
            "performer": performer,
            "scratchType": scratch_type,
            "bpm": bpm,
            "beatMode": beat_mode,
            "labelSource": label_source,
            "confidence": confidence,
            "sessionID": session_id,
            "takeID": take_id,
            "hasAudio": has_audio,
            "hasVideo": has_video,
            "hasMotion": has_motion,
            "startTime": start_time,
            "endTime": end_time,
            "duration": duration,
            "notes": notes,
            "segmentation": segmentation,
        }

    def record_accepted(self, candidate: CandidateResult) -> None:
        output_relative_path = self.allocate_accepted_output_path(candidate.metadata)
        candidate.metadata["outputPath"] = str(output_relative_path)
        if candidate.warnings:
            candidate.metadata["validationWarnings"] = candidate.warnings
            self.total_warnings += len(candidate.warnings)

        if self.mode == "process":
            self.materialize_candidate(candidate, self.output_path / output_relative_path)

        self.accepted_manifest_entries.append(candidate.metadata)

    def record_rejected(self, candidate: CandidateResult, *, reason: str) -> None:
        output_relative_path = self.allocate_rejected_output_path(reason, candidate.metadata["sourceFile"])
        candidate.metadata["outputPath"] = str(output_relative_path)
        candidate.metadata.setdefault("validationStatus", "rejected")
        candidate.metadata["rejectionReason"] = reason
        if candidate.warnings:
            candidate.metadata["validationWarnings"] = candidate.warnings
            self.total_warnings += len(candidate.warnings)

        if self.mode == "process":
            self.materialize_candidate(candidate, self.output_path / output_relative_path)

        self.rejected_manifest_entries.append(candidate.metadata)

    def allocate_accepted_output_path(self, metadata: dict[str, Any]) -> Path:
        scratch_type = str(metadata["scratchType"] or "unknown")
        bpm = int(metadata["bpm"] or 0)
        counter_key = (scratch_type, bpm)
        counter_value = self.accepted_counters[counter_key]

        while True:
            counter_value += 1
            candidate = Path("accepted") / scratch_type / f"{bpm}bpm" / f"take_{counter_value:04d}"
            if not (self.output_path / candidate).exists():
                self.accepted_counters[counter_key] = counter_value
                return candidate

    def allocate_rejected_output_path(self, reason: str, source_file_name: str) -> Path:
        counter_value = self.rejected_counters[reason]
        source_slug = sanitize_path_token(Path(source_file_name).stem)

        while True:
            counter_value += 1
            candidate = Path("rejected") / reason / f"{source_slug}_{counter_value:04d}"
            if not (self.output_path / candidate).exists():
                self.rejected_counters[reason] = counter_value
                return candidate

    def materialize_candidate(self, candidate: CandidateResult, destination_directory: Path) -> None:
        destination_directory.mkdir(parents=True, exist_ok=True)
        for copy_spec in candidate.process_copy_specs:
            shutil.copy2(copy_spec.source, destination_directory / copy_spec.target_name)

        if not candidate.process_copy_specs:
            for source_path in candidate.source_paths:
                shutil.copy2(source_path, destination_directory / source_path.name)

        write_json(destination_directory / "meta.json", candidate.metadata)

    def write_manifest(self) -> Path:
        summary = {
            "acceptedCount": len(self.accepted_manifest_entries),
            "rejectedCount": len(self.rejected_manifest_entries),
            "warningCount": self.total_warnings,
            "acceptedByScratchType": self.count_by_key(self.accepted_manifest_entries, "scratchType"),
            "rejectedByReason": self.count_by_key(self.rejected_manifest_entries, "rejectionReason"),
        }
        manifest = {
            "schemaVersion": PROCESSOR_SCHEMA_VERSION,
            "generatedAt": iso8601_now(),
            "mode": self.mode,
            "inputPath": str(self.input_path),
            "outputPath": str(self.output_path),
            "allowLooseClips": self.allow_loose_clips,
            "allowUnlabeled": self.allow_unlabeled,
            "ffprobeAvailable": self.ffprobe_path is not None,
            "summary": summary,
            "accepted": self.accepted_manifest_entries,
            "rejected": self.rejected_manifest_entries,
        }
        manifest_path = self.output_path / "manifest.json"
        write_json(manifest_path, manifest)
        return manifest_path

    def count_by_key(self, records: list[dict[str, Any]], key: str) -> dict[str, int]:
        counts: defaultdict[str, int] = defaultdict(int)
        for record in records:
            value = record.get(key)
            counts[str(value) if value is not None else "none"] += 1
        return dict(sorted(counts.items()))


def main() -> int:
    args = parse_args()
    processor = DatasetProcessor(args)
    return processor.run()


if __name__ == "__main__":
    sys.exit(main())
