#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import shutil
import subprocess
import sys
import uuid
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any


SOURCE_TYPE = "media_file_ingest"
DEFAULT_PERFORMER = "CXL Dataset"
SUPPORTED_SUFFIX = ".mov"
IGNORED_GENERATED_SUFFIXES = (
    "_performance.mov",
    "_performance_clean.mov",
    "_instruction.mov",
)
DEFAULT_AUDIO_MAP_KEY = "default"
FOLDER_FILE_SEPARATOR = "/"

AUDIO_ROLE_WITH_BEAT = "withBeat"
AUDIO_ROLE_NO_BEAT = "noBeat"
AUDIO_ROLE_BEAT_ONLY = "beatOnly"
VALID_AUDIO_ROLES = frozenset(
    {
        AUDIO_ROLE_WITH_BEAT,
        AUDIO_ROLE_NO_BEAT,
        AUDIO_ROLE_BEAT_ONLY,
    }
)

TRAINING_USE_BY_ROLE = {
    AUDIO_ROLE_WITH_BEAT: "timing_reference",
    AUDIO_ROLE_NO_BEAT: "primary_training",
    AUDIO_ROLE_BEAT_ONLY: "beat_reference",
}

BEAT_MODE_BY_ROLE = {
    AUDIO_ROLE_WITH_BEAT: "withBeat",
    AUDIO_ROLE_NO_BEAT: "noBeat",
    AUDIO_ROLE_BEAT_ONLY: "beatOnly",
}

NO_BEAT_TOKENS = ("no beat", "nobeat", "without beat", "withoutbeat")


@dataclass
class FolderDescriptor:
    scratch_display_name: str
    scratch_type: str
    bpm: int | None
    bpm_source: str
    warnings: list[str] = field(default_factory=list)


@dataclass
class AudioStreamInfo:
    stream_index: int
    codec_name: str | None
    duration: float | None


@dataclass
class MediaProbeInfo:
    has_video: bool
    video_stream_index: int | None
    audio_streams: list[AudioStreamInfo]
    title: str | None = None
    duration: float | None = None

    @property
    def has_audio(self) -> bool:
        return bool(self.audio_streams)


@dataclass
class SourceClip:
    source_path: Path
    probe_info: MediaProbeInfo
    camera_angle: str | None = None


@dataclass
class VideoPlan:
    source_clip: SourceClip
    output_directory: Path
    output_filename: str

    @property
    def output_path(self) -> Path:
        return self.output_directory / self.output_filename


@dataclass
class AudioPlan:
    source_clip: SourceClip
    audio_stream: AudioStreamInfo
    audio_stream_role: str
    output_directory: Path
    output_stem: str
    linked_video_file: str
    metadata: dict[str, Any]

    @property
    def wav_output_path(self) -> Path:
        return self.output_directory / f"{self.output_stem}.wav"

    @property
    def meta_output_path(self) -> Path:
        return self.output_directory / f"{self.output_stem}.meta.json"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Ingest source media scratch folders into canonical per-angle video and per-stream audio outputs."
    )
    parser.add_argument("--input-root", required=True, help="Root directory containing source media scratch folders.")
    parser.add_argument("--output-root", required=True, help="Directory where processed outputs should be written.")
    parser.add_argument("--performer", default=DEFAULT_PERFORMER, help="Performer label to write into metadata.")
    parser.add_argument("--audio-map", help="Optional JSON file mapping media audio stream indexes to stream roles.")
    parser.add_argument("--inspect-streams", action="store_true", help="Inspect media stream roles without writing output.")
    parser.add_argument("--force", action="store_true", help="Overwrite existing generated outputs.")
    parser.add_argument("--dry-run", action="store_true", help="Print planned work without writing output files.")
    return parser.parse_args()


def write_json(path: Path, payload: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary_path = path.parent / f".{path.name}.tmp"
    with temporary_path.open("w", encoding="utf-8") as handle:
        json.dump(payload, handle, indent=2, sort_keys=True)
        handle.write("\n")
    temporary_path.replace(path)


def maybe_relative_to(path: Path, root: Path) -> str:
    try:
        return str(path.relative_to(root))
    except ValueError:
        return str(path)


def normalize_to_snake_case(value: str) -> str:
    normalized = "".join(character if character.isalnum() else "_" for character in value.strip().lower())
    while "__" in normalized:
        normalized = normalized.replace("__", "_")
    return normalized.strip("_") or "unknown"


def parse_optional_float(value: Any) -> float | None:
    if value is None:
        return None
    try:
        return float(value)
    except (TypeError, ValueError):
        return None


def format_duration(duration: float | None) -> str:
    if duration is None:
        return "unknown"
    return f"{duration:.3f}s"


def parse_folder_descriptor(folder_name: str) -> FolderDescriptor:
    warnings: list[str] = []
    bpm: int | None = None
    bpm_source = "missing"
    scratch_display_name = folder_name

    lower_name = folder_name.lower()
    if lower_name.endswith("bpm"):
        prefix, _, suffix = folder_name.rpartition("_")
        numeric_token = suffix[:-3]
        if prefix and numeric_token.isdigit():
            scratch_display_name = prefix
            bpm = int(numeric_token)
            bpm_source = "folder_name"

    if bpm is None:
        warnings.append(f"Folder '{folder_name}' is missing a BPM suffix.")

    scratch_display_name = scratch_display_name.strip(" _-") or folder_name.strip() or "Unknown"
    return FolderDescriptor(
        scratch_display_name=scratch_display_name,
        scratch_type=normalize_to_snake_case(scratch_display_name),
        bpm=bpm,
        bpm_source=bpm_source,
        warnings=warnings,
    )


def classify_filename(filename: str) -> str:
    lowered = filename.lower().replace("-", " ").replace("_", " ")
    if any(token in lowered for token in NO_BEAT_TOKENS):
        return AUDIO_ROLE_NO_BEAT
    if "beat" in lowered:
        return AUDIO_ROLE_WITH_BEAT
    return AUDIO_ROLE_NO_BEAT


def assign_camera_angles(source_clips: list[SourceClip]) -> list[str]:
    ordered_clips = sorted(source_clips, key=lambda clip: clip.source_path.name.lower())
    for index, clip in enumerate(ordered_clips, start=1):
        clip.camera_angle = f"angle_{index}"
    return [clip.camera_angle or f"angle_{index}" for index, clip in enumerate(ordered_clips, start=1)]


def bpm_directory_name(bpm: int | None) -> str:
    return f"{bpm}bpm" if bpm is not None else "unknown_bpm"


def stable_dataset_item_id(
    *,
    scratch_type: str,
    bpm: int | None,
    camera_angle: str,
    audio_stream_role: str,
    audio_stream_index: int,
    original_file: str,
) -> str:
    token = "|".join(
        [
            scratch_type,
            "none" if bpm is None else str(bpm),
            camera_angle,
            audio_stream_role,
            str(audio_stream_index),
            original_file,
        ]
    )
    return uuid.uuid5(uuid.NAMESPACE_URL, token).hex


def load_audio_map(path: Path | None) -> dict[str, dict[str, str]]:
    if path is None:
        return {}

    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError as error:
        raise RuntimeError(f"Audio map file does not exist: {path}") from error
    except json.JSONDecodeError as error:
        raise RuntimeError(f"Audio map file is not valid JSON: {path}: {error}") from error

    if not isinstance(payload, dict):
        raise RuntimeError("Audio map JSON must be an object keyed by scope.")

    normalized: dict[str, dict[str, str]] = {}
    for scope_key, mapping in payload.items():
        if not isinstance(scope_key, str) or not isinstance(mapping, dict):
            raise RuntimeError("Audio map scopes must be string keys with object values.")
        normalized_mapping: dict[str, str] = {}
        for stream_key, role in mapping.items():
            if not isinstance(stream_key, str) or not isinstance(role, str):
                raise RuntimeError("Audio map stream keys and roles must be strings.")
            if role not in VALID_AUDIO_ROLES:
                raise RuntimeError(
                    f"Unsupported audio role '{role}' in audio map. Expected one of: {', '.join(sorted(VALID_AUDIO_ROLES))}."
                )
            normalized_mapping[stream_key] = role
        normalized[scope_key] = normalized_mapping
    return normalized


def build_audio_metadata(
    *,
    source_path: Path,
    input_root: Path,
    source_folder_name: str,
    performer: str,
    folder_descriptor: FolderDescriptor,
    camera_angle: str,
    camera_angle_count: int,
    linked_video_file: str,
    audio_stream: AudioStreamInfo,
    audio_stream_role: str,
) -> dict[str, Any]:
    original_file = maybe_relative_to(source_path, input_root)
    return {
        "datasetItemID": stable_dataset_item_id(
            scratch_type=folder_descriptor.scratch_type,
            bpm=folder_descriptor.bpm,
            camera_angle=camera_angle,
            audio_stream_role=audio_stream_role,
            audio_stream_index=audio_stream.stream_index,
            original_file=original_file,
        ),
        "sourceType": SOURCE_TYPE,
        "originalFile": original_file,
        "sourceFolder": source_folder_name,
        "performer": performer,
        "scratchDisplayName": folder_descriptor.scratch_display_name,
        "scratchType": folder_descriptor.scratch_type,
        "bpm": folder_descriptor.bpm,
        "bpmSource": folder_descriptor.bpm_source,
        "cameraAngle": camera_angle,
        "cameraAngleCount": camera_angle_count,
        "audioStreamIndex": audio_stream.stream_index,
        "audioStreamRole": audio_stream_role,
        "beatMode": BEAT_MODE_BY_ROLE[audio_stream_role],
        "linkedVideoFile": linked_video_file,
        "hasVideo": True,
        "hasAudio": True,
        "hasExtractedWav": True,
        "trainingUse": TRAINING_USE_BY_ROLE[audio_stream_role],
        "reviewStatus": "needs_review",
        "labelSource": "folder_name_media_ingest",
        "confidence": 0.9,
        "notes": "",
    }


class MediaScratchIngester:
    def __init__(self, args: argparse.Namespace) -> None:
        self.input_root = Path(args.input_root).expanduser().resolve()
        self.output_root = Path(args.output_root).expanduser().resolve()
        self.performer = args.performer
        self.force = bool(args.force)
        self.dry_run = bool(args.dry_run)
        self.inspect_streams = bool(args.inspect_streams)
        self.audio_map_path = Path(args.audio_map).expanduser().resolve() if args.audio_map else None
        self.audio_map = load_audio_map(self.audio_map_path)
        self.ffmpeg_path = shutil.which("ffmpeg")
        self.ffprobe_path = shutil.which("ffprobe")

    def ensure_tools(self) -> None:
        missing: list[str] = []
        if self.ffmpeg_path is None:
            missing.append("ffmpeg")
        if self.ffprobe_path is None:
            missing.append("ffprobe")
        if missing:
            raise RuntimeError(f"Missing required tool(s): {', '.join(missing)}")

    def should_ignore_source_path(self, path: Path) -> bool:
        lower_name = path.name.lower()
        return lower_name.endswith(IGNORED_GENERATED_SUFFIXES)

    def find_source_folders(self) -> dict[Path, list[Path]]:
        grouped: dict[Path, list[Path]] = {}
        if not self.input_root.exists() or not self.input_root.is_dir():
            return grouped

        for path in sorted(self.input_root.rglob(f"*{SUPPORTED_SUFFIX}")):
            resolved_path = path.resolve()
            if self.output_root in resolved_path.parents:
                continue
            if self.should_ignore_source_path(resolved_path):
                continue
            grouped.setdefault(resolved_path.parent, []).append(resolved_path)
        return grouped

    def probe_media_info(self, source_path: Path) -> MediaProbeInfo:
        result = subprocess.run(
            [
                self.ffprobe_path or "ffprobe",
                "-v",
                "error",
                "-print_format",
                "json",
                "-show_streams",
                "-show_format",
                str(source_path),
            ],
            capture_output=True,
            text=True,
            check=False,
            timeout=30,
        )
        if result.returncode != 0:
            raise RuntimeError(f"ffprobe failed for {source_path}: {result.stderr.strip()}")

        try:
            payload = json.loads(result.stdout or "{}")
        except json.JSONDecodeError as error:
            raise RuntimeError(f"ffprobe returned invalid JSON for {source_path}: {error}") from error

        format_payload = payload.get("format", {}) if isinstance(payload, dict) else {}
        format_duration = parse_optional_float(format_payload.get("duration")) if isinstance(format_payload, dict) else None
        tags = format_payload.get("tags", {}) if isinstance(format_payload, dict) else {}
        title = None
        if isinstance(tags, dict):
            title = tags.get("title") or tags.get("TITLE")

        streams_payload = payload.get("streams", []) if isinstance(payload, dict) else []
        video_stream_index: int | None = None
        audio_streams: list[AudioStreamInfo] = []
        if isinstance(streams_payload, list):
            for stream in streams_payload:
                if not isinstance(stream, dict):
                    continue
                codec_type = stream.get("codec_type")
                stream_index = stream.get("index")
                if not isinstance(stream_index, int):
                    continue
                if codec_type == "video" and video_stream_index is None:
                    video_stream_index = stream_index
                if codec_type == "audio":
                    audio_streams.append(
                        AudioStreamInfo(
                            stream_index=stream_index,
                            codec_name=stream.get("codec_name") if isinstance(stream.get("codec_name"), str) else None,
                            duration=parse_optional_float(stream.get("duration")) or format_duration,
                        )
                    )

        audio_streams.sort(key=lambda stream: stream.stream_index)
        return MediaProbeInfo(
            has_video=video_stream_index is not None,
            video_stream_index=video_stream_index,
            audio_streams=audio_streams,
            title=title,
            duration=format_duration,
        )

    def extract_video_copy(self, source_path: Path, video_stream_index: int, output_path: Path) -> None:
        output_path.parent.mkdir(parents=True, exist_ok=True)
        result = subprocess.run(
            [
                self.ffmpeg_path or "ffmpeg",
                "-y",
                "-i",
                str(source_path),
                "-map",
                f"0:{video_stream_index}",
                "-an",
                "-c",
                "copy",
                str(output_path),
            ],
            capture_output=True,
            text=True,
            check=False,
            timeout=120,
        )
        if result.returncode != 0:
            raise RuntimeError(f"ffmpeg video remux failed for {source_path}: {result.stderr.strip()}")

    def extract_audio_stream(self, source_path: Path, stream_index: int, output_path: Path) -> None:
        output_path.parent.mkdir(parents=True, exist_ok=True)
        result = subprocess.run(
            [
                self.ffmpeg_path or "ffmpeg",
                "-y",
                "-i",
                str(source_path),
                "-map",
                f"0:{stream_index}",
                "-vn",
                "-acodec",
                "pcm_s16le",
                "-ar",
                "48000",
                str(output_path),
            ],
            capture_output=True,
            text=True,
            check=False,
            timeout=120,
        )
        if result.returncode != 0:
            raise RuntimeError(
                f"ffmpeg WAV extraction failed for {source_path} stream 0:{stream_index}: {result.stderr.strip()}"
            )

    def probe_source_clips(self, source_paths: list[Path]) -> list[SourceClip]:
        source_clips: list[SourceClip] = []
        for source_path in sorted(source_paths, key=lambda path: path.name.lower()):
            probe_info = self.probe_media_info(source_path)
            if not probe_info.has_video or probe_info.video_stream_index is None:
                raise RuntimeError(f"{source_path.name} is missing a video stream.")
            if not probe_info.has_audio:
                raise RuntimeError(f"{source_path.name} is missing an audio stream.")
            source_clips.append(SourceClip(source_path=source_path, probe_info=probe_info))
        return source_clips

    def build_output_directory(self, folder_descriptor: FolderDescriptor) -> Path:
        return self.output_root / folder_descriptor.scratch_type / bpm_directory_name(folder_descriptor.bpm)

    def audio_map_scope_keys(self, folder_path: Path, source_path: Path) -> list[str]:
        relative_file = maybe_relative_to(source_path, self.input_root).replace("\\", FOLDER_FILE_SEPARATOR)
        folder_file = f"{folder_path.name}{FOLDER_FILE_SEPARATOR}{source_path.name}"
        scope_keys: list[str] = []
        for key in (relative_file, folder_file, source_path.name, folder_path.name, DEFAULT_AUDIO_MAP_KEY):
            if key in self.audio_map and key not in scope_keys:
                scope_keys.append(key)
        return scope_keys

    def resolve_audio_map_role(
        self,
        *,
        folder_path: Path,
        source_path: Path,
        stream_index: int,
    ) -> str | None:
        stream_keys = (f"0:{stream_index}", str(stream_index))
        for scope_key in self.audio_map_scope_keys(folder_path, source_path):
            mapping = self.audio_map.get(scope_key, {})
            for stream_key in stream_keys:
                role = mapping.get(stream_key)
                if role is not None:
                    return role
        return None

    def resolve_audio_stream_role(
        self,
        *,
        folder_path: Path,
        source_clip: SourceClip,
        audio_stream: AudioStreamInfo,
    ) -> str | None:
        mapped_role = self.resolve_audio_map_role(
            folder_path=folder_path,
            source_path=source_clip.source_path,
            stream_index=audio_stream.stream_index,
        )
        if mapped_role is not None:
            return mapped_role

        if not self.audio_map and len(source_clip.probe_info.audio_streams) <= 1:
            return classify_filename(source_clip.source_path.name)

        return None

    def inspect_folder(
        self,
        *,
        folder_path: Path,
        folder_descriptor: FolderDescriptor,
        source_clips: list[SourceClip],
    ) -> int:
        available_angles = assign_camera_angles(source_clips)
        warnings = list(folder_descriptor.warnings)
        if len(available_angles) != 4:
            warnings.append(f"Expected 4 camera angles but found {len(available_angles)}.")

        print(f"Folder: {folder_path}")
        for source_clip in sorted(source_clips, key=lambda clip: clip.camera_angle or clip.source_path.name.lower()):
            print(f"  {source_clip.camera_angle}: {source_clip.source_path.name}")
            for audio_stream in source_clip.probe_info.audio_streams:
                proposed_role = self.resolve_audio_stream_role(
                    folder_path=folder_path,
                    source_clip=source_clip,
                    audio_stream=audio_stream,
                )
                print(
                    "    "
                    f"stream 0:{audio_stream.stream_index} "
                    f"codec={audio_stream.codec_name or 'unknown'} "
                    f"duration={format_duration(audio_stream.duration)} "
                    f"proposedRole={proposed_role or 'unmapped'}"
                )

        for warning in warnings:
            print(f"warning: {warning}", file=sys.stderr)
        return 0

    def build_plans(
        self,
        *,
        folder_path: Path,
        folder_descriptor: FolderDescriptor,
        source_clips: list[SourceClip],
    ) -> tuple[list[VideoPlan], list[AudioPlan], list[str]]:
        warnings = list(folder_descriptor.warnings)
        available_angles = assign_camera_angles(source_clips)
        angle_count = len(available_angles)
        if angle_count != 4:
            warnings.append(f"Expected 4 camera angles but found {angle_count}.")

        output_directory = self.build_output_directory(folder_descriptor)
        video_plans: list[VideoPlan] = []
        audio_plans: list[AudioPlan] = []

        for source_clip in sorted(source_clips, key=lambda clip: clip.camera_angle or clip.source_path.name.lower()):
            camera_angle = source_clip.camera_angle or "angle_unknown"
            video_plan = VideoPlan(
                source_clip=source_clip,
                output_directory=output_directory,
                output_filename=f"{camera_angle}_video.mov",
            )
            video_plans.append(video_plan)

            role_counts: dict[str, int] = {}
            for audio_stream in source_clip.probe_info.audio_streams:
                audio_stream_role = self.resolve_audio_stream_role(
                    folder_path=folder_path,
                    source_clip=source_clip,
                    audio_stream=audio_stream,
                )
                if audio_stream_role is None:
                    raise RuntimeError(
                        f"{source_clip.source_path.name} stream 0:{audio_stream.stream_index} is unmapped. "
                        "Run --inspect-streams and provide --audio-map before ingest."
                    )

                role_counts[audio_stream_role] = role_counts.get(audio_stream_role, 0) + 1
                output_stem = f"{camera_angle}_{audio_stream_role}"
                if role_counts[audio_stream_role] > 1:
                    output_stem = f"{output_stem}_{role_counts[audio_stream_role]}"
                    warnings.append(
                        f"{source_clip.source_path.name} contains multiple '{audio_stream_role}' streams; "
                        f"wrote {output_stem}.wav for stream 0:{audio_stream.stream_index}."
                    )

                metadata = build_audio_metadata(
                    source_path=source_clip.source_path,
                    input_root=self.input_root,
                    source_folder_name=folder_path.name,
                    performer=self.performer,
                    folder_descriptor=folder_descriptor,
                    camera_angle=camera_angle,
                    camera_angle_count=angle_count,
                    linked_video_file=video_plan.output_filename,
                    audio_stream=audio_stream,
                    audio_stream_role=audio_stream_role,
                )
                audio_plans.append(
                    AudioPlan(
                        source_clip=source_clip,
                        audio_stream=audio_stream,
                        audio_stream_role=audio_stream_role,
                        output_directory=output_directory,
                        output_stem=output_stem,
                        linked_video_file=video_plan.output_filename,
                        metadata=metadata,
                    )
                )

        return video_plans, audio_plans, warnings

    def build_manifest(
        self,
        *,
        folder_path: Path,
        folder_descriptor: FolderDescriptor,
        video_plans: list[VideoPlan],
        audio_plans: list[AudioPlan],
        warnings: list[str],
    ) -> dict[str, Any]:
        generated_items = []
        for audio_plan in audio_plans:
            generated_items.append(
                {
                    "video": audio_plan.linked_video_file,
                    "audio": audio_plan.wav_output_path.name,
                    "meta": audio_plan.meta_output_path.name,
                    "audioStreamIndex": audio_plan.audio_stream.stream_index,
                    "audioStreamRole": audio_plan.audio_stream_role,
                    "beatMode": BEAT_MODE_BY_ROLE[audio_plan.audio_stream_role],
                    "cameraAngle": audio_plan.metadata["cameraAngle"],
                    "trainingUse": TRAINING_USE_BY_ROLE[audio_plan.audio_stream_role],
                }
            )

        return {
            "scratchDisplayName": folder_descriptor.scratch_display_name,
            "scratchType": folder_descriptor.scratch_type,
            "bpm": folder_descriptor.bpm,
            "bpmSource": folder_descriptor.bpm_source,
            "sourceFolder": folder_path.name,
            "angleCount": len(video_plans),
            "generatedItems": generated_items,
            "warnings": warnings,
        }

    def video_output_exists(self, plan: VideoPlan) -> bool:
        return plan.output_path.exists()

    def audio_output_exists(self, plan: AudioPlan) -> bool:
        return plan.wav_output_path.exists() or plan.meta_output_path.exists()

    def process_folder(self, folder_path: Path, source_paths: list[Path]) -> int:
        folder_descriptor = parse_folder_descriptor(folder_path.name)
        source_clips = self.probe_source_clips(source_paths)

        if self.inspect_streams:
            return self.inspect_folder(
                folder_path=folder_path,
                folder_descriptor=folder_descriptor,
                source_clips=source_clips,
            )

        video_plans, audio_plans, warnings = self.build_plans(
            folder_path=folder_path,
            folder_descriptor=folder_descriptor,
            source_clips=source_clips,
        )
        manifest = self.build_manifest(
            folder_path=folder_path,
            folder_descriptor=folder_descriptor,
            video_plans=video_plans,
            audio_plans=audio_plans,
            warnings=warnings,
        )

        output_directory = self.build_output_directory(folder_descriptor)
        manifest_path = output_directory / "manifest.json"

        if self.dry_run:
            print(f"[dry-run] Folder: {folder_path}")
            for video_plan in video_plans:
                print(f"[dry-run] video {video_plan.source_clip.source_path} -> {video_plan.output_path}")
            for audio_plan in audio_plans:
                print(
                    "[dry-run] audio "
                    f"{audio_plan.source_clip.source_path} stream 0:{audio_plan.audio_stream.stream_index} "
                    f"-> {audio_plan.wav_output_path}"
                )
                print(f"[dry-run] meta  {audio_plan.meta_output_path}")
            print(f"[dry-run] manifest {manifest_path}")
            for warning in warnings:
                print(f"[dry-run] warning: {warning}", file=sys.stderr)
            return 0

        for video_plan in video_plans:
            if self.video_output_exists(video_plan) and not self.force:
                print(
                    f"Skipping existing video output for {video_plan.source_clip.source_path.name}; pass --force to overwrite.",
                    file=sys.stderr,
                )
            else:
                if video_plan.source_clip.probe_info.video_stream_index is None:
                    raise RuntimeError(f"{video_plan.source_clip.source_path.name} is missing a video stream.")
                self.extract_video_copy(
                    video_plan.source_clip.source_path,
                    video_plan.source_clip.probe_info.video_stream_index,
                    video_plan.output_path,
                )

        for audio_plan in audio_plans:
            if self.audio_output_exists(audio_plan) and not self.force:
                print(
                    f"Skipping existing audio outputs for {audio_plan.source_clip.source_path.name} "
                    f"stream 0:{audio_plan.audio_stream.stream_index}; pass --force to overwrite.",
                    file=sys.stderr,
                )
                continue
            self.extract_audio_stream(
                audio_plan.source_clip.source_path,
                audio_plan.audio_stream.stream_index,
                audio_plan.wav_output_path,
            )
            write_json(audio_plan.meta_output_path, audio_plan.metadata)

        if manifest_path.exists() and not self.force:
            print(f"Skipping existing manifest: {manifest_path}", file=sys.stderr)
        else:
            write_json(manifest_path, manifest)

        for warning in warnings:
            print(f"warning: {warning}", file=sys.stderr)
        return 0

    def run(self) -> int:
        try:
            self.ensure_tools()
        except RuntimeError as error:
            print(str(error), file=sys.stderr)
            return 1

        source_folders = self.find_source_folders()
        if not source_folders:
            print(f"No {SUPPORTED_SUFFIX} files found under {self.input_root}", file=sys.stderr)
            return 1

        exit_code = 0
        for folder_path, source_paths in sorted(source_folders.items(), key=lambda item: str(item[0]).lower()):
            try:
                exit_code = max(exit_code, self.process_folder(folder_path, source_paths))
            except RuntimeError as error:
                print(f"{folder_path}: {error}", file=sys.stderr)
                exit_code = 1
        return exit_code


def main() -> int:
    try:
        args = parse_args()
        return MediaScratchIngester(args).run()
    except RuntimeError as error:
        print(str(error), file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
