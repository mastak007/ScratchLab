#!/usr/bin/env python3
from __future__ import annotations

import csv
import hashlib
import json
import re
import shutil
import subprocess
import wave
from datetime import datetime
from pathlib import Path
from typing import Any

SCRATCH_TYPE = "baby"
SESSION_NAME = "baby_scratch"
ALLOWED_BPMS = (70, 90, 110)
SEGMENT_COUNT = 3

REQUIRED_DIRECTORIES = (
    "raw",
    "70bpm",
    "90bpm",
    "110bpm",
    "audio",
    "video",
    "watch",
    "notation",
    "manifests",
)

SOURCE_COLUMNS = {
    "camA": "raw_camA",
    "camB": "raw_camB",
    "serato": "raw_audio",
    "watch": "raw_watch",
}

DESTINATION_FOLDERS = {
    "camA": "video",
    "camB": "video",
    "serato": "audio",
    "watch": "watch",
}

ALLOWED_EXTENSIONS = {
    "camA": {"mov"},
    "camB": {"mov"},
    "serato": {"wav"},
    "watch": {"csv"},
}

WATCH_CSV_HEADER = [
    "elapsed_time",
    "core_motion_timestamp",
    "attitude_roll",
    "attitude_pitch",
    "attitude_yaw",
    "quaternion_x",
    "quaternion_y",
    "quaternion_z",
    "quaternion_w",
    "gravity_x",
    "gravity_y",
    "gravity_z",
    "user_accel_x",
    "user_accel_y",
    "user_accel_z",
    "rotation_rate_x",
    "rotation_rate_y",
    "rotation_rate_z",
]
MIN_WATCH_DATA_ROWS = 10

TAKE_LOG_COLUMNS = [
    "bpm",
    "take_number",
    "raw_camA",
    "raw_camB",
    "raw_audio",
    "raw_watch",
    "verbal_slate_used",
    "sync_clap_used",
    "notes",
]

MANIFEST_TEMPLATE_FILENAME = "session_manifest_template.json"
TAKE_LOG_TEMPLATE_FILENAME = "take_log_template.csv"
SESSION_MANIFEST_FILENAME = "session_manifest.json"
TAKE_LOG_FILENAME = "take_log.csv"
VALIDATION_REPORT_FILENAME = "validation_report.txt"

FILENAME_PATTERN = re.compile(
    r"^(?P<dj>[A-Z0-9]+)_baby_(?P<bpm>070|090|110)_take(?P<take>\d{2})_"
    r"(?P<source>camA|camB|serato|watch)\.(?P<ext>mov|wav|csv)$"
)


def repo_root() -> Path:
    return Path(__file__).resolve().parent.parent


def templates_dir() -> Path:
    return repo_root() / "templates"


def sanitize_dj_token(name: str) -> str:
    token = re.sub(r"[^A-Za-z0-9]+", "", name).upper()
    if not token:
        raise ValueError("DJ name must include at least one letter or number.")
    return token


def validate_date_string(value: str) -> str:
    try:
        datetime.strptime(value, "%Y-%m-%d")
    except ValueError as exc:
        raise ValueError("Date must use YYYY-MM-DD format.") from exc
    return value


def default_manifest(
    dj_name: str = "",
    dj_token: str = "",
    date_string: str = "",
    session_dir: Path | None = None,
) -> dict[str, Any]:
    return {
        "spec_version": "capture_spec_v1",
        "dj_name": dj_name,
        "dj_token": dj_token,
        "date": date_string,
        "scratch_type": SCRATCH_TYPE,
        "allowed_bpms": list(ALLOWED_BPMS),
        "segment_count": SEGMENT_COUNT,
        "verbal_slate_required": True,
        "sync_clap_required": True,
        "session_root": str(session_dir) if session_dir else "",
        "notes": "",
        "takes": [],
    }


def session_file_paths(session_dir: Path) -> dict[str, Path]:
    manifests_dir = session_dir / "manifests"
    return {
        "manifest": manifests_dir / SESSION_MANIFEST_FILENAME,
        "take_log": manifests_dir / TAKE_LOG_FILENAME,
        "validation_report": manifests_dir / VALIDATION_REPORT_FILENAME,
    }


def read_json(path: Path) -> Any:
    with path.open("r", encoding="utf-8") as handle:
        return json.load(handle)


def write_json(path: Path, payload: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temp_path = path.parent / f".{path.name}.tmp"
    with temp_path.open("w", encoding="utf-8") as handle:
        json.dump(payload, handle, indent=2)
        handle.write("\n")
    temp_path.replace(path)


def read_take_log(path: Path) -> list[dict[str, str]]:
    with path.open("r", encoding="utf-8", newline="") as handle:
        reader = csv.DictReader(handle)
        if reader.fieldnames is None:
            return []
        missing_columns = [column for column in TAKE_LOG_COLUMNS if column not in reader.fieldnames]
        if missing_columns:
            joined = ", ".join(missing_columns)
            raise ValueError(f"Take log is missing required columns: {joined}")

        rows: list[dict[str, str]] = []
        for row in reader:
            cleaned = {column: (row.get(column) or "").strip() for column in TAKE_LOG_COLUMNS}
            if any(cleaned.values()):
                rows.append(cleaned)
        return rows


def parse_bool(value: str, *, default: bool | None = None, field_name: str = "boolean field") -> bool:
    text = (value or "").strip().lower()
    if not text:
        if default is None:
            raise ValueError(f"{field_name} is required and cannot be blank.")
        return default
    if text in {"1", "true", "yes", "y"}:
        return True
    if text in {"0", "false", "no", "n"}:
        return False
    raise ValueError(
        f"{field_name} must be one of true/false, yes/no, y/n, or 1/0; got {value!r}."
    )


def parse_bpm(value: str) -> int:
    try:
        bpm = int(value)
    except ValueError as exc:
        raise ValueError("BPM must be a whole number.") from exc
    if bpm not in ALLOWED_BPMS:
        raise ValueError(f"BPM must be one of {', '.join(str(item) for item in ALLOWED_BPMS)}.")
    return bpm


def parse_take_number(value: str) -> int:
    try:
        take_number = int(value)
    except ValueError as exc:
        raise ValueError("Take number must be a whole number.") from exc
    if take_number < 1:
        raise ValueError("Take number must be 1 or greater.")
    return take_number


def format_bpm(bpm: int) -> str:
    return f"{bpm:03d}"


def build_standard_filename(dj_token: str, bpm: int, take_number: int, source: str) -> str:
    extension = sorted(ALLOWED_EXTENSIONS[source])[0]
    return f"{dj_token}_{SCRATCH_TYPE}_{format_bpm(bpm)}_take{take_number:02d}_{source}.{extension}"


def normalize_extension(source: str, path: Path) -> str:
    extension = path.suffix.lower().lstrip(".")
    allowed = ALLOWED_EXTENSIONS[source]
    if extension not in allowed:
        joined = ", ".join(sorted(f".{item}" for item in allowed))
        raise ValueError(f"{path.name} must use one of these extensions for {source}: {joined}")
    return extension


def resolve_raw_path(session_dir: Path, raw_value: str) -> Path:
    raw_root = (session_dir / "raw").resolve()
    raw_path = Path(raw_value)
    if raw_path.is_absolute():
        raise ValueError(f"Raw source paths must stay inside the session raw/ folder: {raw_value}")

    resolved_path = (raw_root / raw_path).resolve()
    try:
        resolved_path.relative_to(raw_root)
    except ValueError as exc:
        raise ValueError(f"Raw source paths must stay inside the session raw/ folder: {raw_value}") from exc
    return resolved_path


def relative_to_session(session_dir: Path, path: Path) -> str:
    try:
        return str(path.relative_to(session_dir))
    except ValueError:
        return str(path)


def file_sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def parse_probe_float(value: Any) -> float | None:
    if value in (None, "", "N/A"):
        return None
    try:
        return round(float(value), 6)
    except (TypeError, ValueError):
        return None


def parse_probe_int(value: Any) -> int | None:
    if value in (None, "", "N/A"):
        return None
    try:
        return int(value)
    except (TypeError, ValueError):
        return None


def parse_probe_ratio(value: Any) -> float | None:
    text = str(value or "").strip()
    if not text or text in {"0/0", "N/A"}:
        return None
    if "/" not in text:
        return parse_probe_float(text)

    numerator_text, denominator_text = text.split("/", 1)
    numerator = parse_probe_float(numerator_text)
    denominator = parse_probe_float(denominator_text)
    if numerator is None or denominator in (None, 0):
        return None
    return round(numerator / denominator, 6)


def run_ffprobe(path: Path) -> dict[str, Any]:
    ffprobe_path = shutil.which("ffprobe")
    if not ffprobe_path:
        raise ValueError("ffprobe is required to probe video metadata.")

    result = subprocess.run(
        [
            ffprobe_path,
            "-v",
            "error",
            "-print_format",
            "json",
            "-show_format",
            "-show_streams",
            str(path),
        ],
        check=False,
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        detail = result.stderr.strip() or result.stdout.strip() or "unknown ffprobe error"
        raise ValueError(f"ffprobe could not read {path.name}: {detail}")

    try:
        payload = json.loads(result.stdout)
    except json.JSONDecodeError as exc:
        raise ValueError(f"ffprobe returned invalid JSON for {path.name}.") from exc

    if not isinstance(payload, dict):
        raise ValueError(f"ffprobe returned an invalid payload for {path.name}.")
    return payload


def probe_video_metadata(path: Path) -> dict[str, Any]:
    payload = run_ffprobe(path)
    streams = payload.get("streams", [])
    video_stream = next(
        (stream for stream in streams if isinstance(stream, dict) and stream.get("codec_type") == "video"),
        None,
    )
    if not isinstance(video_stream, dict):
        raise ValueError(f"{path.name} does not contain a readable video stream.")

    format_payload = payload.get("format", {})
    if not isinstance(format_payload, dict):
        format_payload = {}

    duration_seconds = parse_probe_float(format_payload.get("duration") or video_stream.get("duration"))
    width = parse_probe_int(video_stream.get("width"))
    height = parse_probe_int(video_stream.get("height"))
    if duration_seconds is None:
        raise ValueError(f"{path.name} is missing a readable video duration.")
    if width is None or height is None:
        raise ValueError(f"{path.name} is missing readable video dimensions.")

    metadata: dict[str, Any] = {
        "kind": "video",
        "duration_seconds": duration_seconds,
        "width": width,
        "height": height,
    }

    frame_rate = parse_probe_ratio(video_stream.get("avg_frame_rate") or video_stream.get("r_frame_rate"))
    if frame_rate is not None:
        metadata["frame_rate_fps"] = round(frame_rate, 4)

    codec_name = str(video_stream.get("codec_name") or "").strip()
    if codec_name:
        metadata["codec"] = codec_name

    return metadata


def probe_audio_metadata(path: Path) -> dict[str, Any]:
    try:
        with wave.open(str(path), "rb") as handle:
            channel_count = handle.getnchannels()
            sample_rate = handle.getframerate()
            frame_count = handle.getnframes()
            sample_width = handle.getsampwidth()
    except (wave.Error, EOFError) as exc:
        raise ValueError(f"{path.name} is not a readable WAV file.") from exc

    if channel_count < 1:
        raise ValueError(f"{path.name} is missing audio channels.")
    if sample_rate < 1:
        raise ValueError(f"{path.name} is missing a valid audio sample rate.")
    if frame_count < 0:
        raise ValueError(f"{path.name} is missing a valid audio frame count.")

    return {
        "kind": "audio",
        "duration_seconds": round(frame_count / sample_rate, 6),
        "sample_rate_hz": sample_rate,
        "channel_count": channel_count,
        "frame_count": frame_count,
        "sample_width_bytes": sample_width,
    }


def probe_csv_metadata(path: Path) -> dict[str, Any]:
    with path.open("r", encoding="utf-8", newline="") as handle:
        reader = csv.reader(handle)
        header = next(reader, None)
        if header is None:
            raise ValueError(f"{path.name} is empty.")
        normalized_header = [cell.strip() for cell in header]
        if normalized_header != WATCH_CSV_HEADER:
            raise ValueError(f"{path.name} does not match the expected watch CSV header.")

        data_row_count = 0
        for row in reader:
            if any(cell.strip() for cell in row):
                data_row_count += 1
        if data_row_count < MIN_WATCH_DATA_ROWS:
            raise ValueError(
                f"{path.name} has only {data_row_count} watch samples; expected at least {MIN_WATCH_DATA_ROWS}."
            )

    return {
        "kind": "csv",
        "row_count": data_row_count + 1,
        "data_row_count": data_row_count,
        "column_count": len(normalized_header),
    }


def probe_media_metadata(source: str, path: Path) -> dict[str, Any]:
    if source in {"camA", "camB"}:
        return probe_video_metadata(path)
    if source == "serato":
        return probe_audio_metadata(path)
    if source == "watch":
        return probe_csv_metadata(path)
    raise ValueError(f"Unsupported probe source: {source}")


def build_artifact_record(session_dir: Path, path: Path, source: str) -> dict[str, Any]:
    return {
        "path": relative_to_session(session_dir, path),
        "bytes": path.stat().st_size,
        "sha256": file_sha256(path),
        "probe": probe_media_metadata(source, path),
    }


def build_notation_filename(take_number: int) -> str:
    return f"take-{take_number:03d}_detected_notation.json"


def build_unavailable_notation_document(
    *,
    session_id: str,
    take_id: str,
    take_number: int,
    bpm: int,
    notes: str,
) -> dict[str, Any]:
    return {
        "schemaVersion": "scratchlab_detected_notation_v1",
        "sessionID": session_id,
        "takeID": take_id,
        "takeNumber": take_number,
        "scratchType": SESSION_NAME,
        "bpm": bpm,
        "captureMode": "timed_click",
        "notationSource": "unavailable",
        "labelSource": "unknown",
        "confidence": None,
        "recordMovementEvents": [],
        "faderEvents": [],
        "mixerMidiEvents": [],
        "beatGrid": None,
        "notes": notes,
    }


def take_sort_key(record: dict[str, Any]) -> tuple[int, int]:
    return int(record["bpm"]), int(record["take_number"])


def build_take_record(
    session_dir: Path,
    *,
    dj_name: str,
    date_string: str,
    bpm: int,
    take_number: int,
    verbal_slate_used: bool,
    sync_clap_used: bool,
    notes: str,
    files_by_source: dict[str, Path],
) -> dict[str, Any]:
    has_cam_a = "camA" in files_by_source
    has_cam_b = "camB" in files_by_source
    has_serato = "serato" in files_by_source
    if not has_cam_a:
        raise ValueError("Each take needs a primary camA video file.")
    if not has_serato:
        raise ValueError("Each take needs a serato audio file.")

    camera_id = "camA+camB" if has_cam_b else "camA"

    files = {
        source: relative_to_session(session_dir, path)
        for source, path in sorted(files_by_source.items())
    }
    files["notation"] = f"notation/{build_notation_filename(take_number)}"
    artifacts = {
        source: build_artifact_record(session_dir, path, source)
        for source, path in sorted(files_by_source.items())
    }

    return {
        "dj_name": dj_name,
        "date": date_string,
        "scratch_type": SCRATCH_TYPE,
        "bpm": bpm,
        "take_number": take_number,
        "segment_count": SEGMENT_COUNT,
        "camera_id": camera_id,
        "audio_source": "serato",
        "watch_source": "watch" if "watch" in files_by_source else "none",
        "verbal_slate_used": verbal_slate_used,
        "sync_clap_used": sync_clap_used,
        "notes": notes,
        "files": files,
        "artifacts": artifacts,
    }


def write_bpm_summary(session_dir: Path, take_record: dict[str, Any]) -> Path:
    bpm = int(take_record["bpm"])
    take_number = int(take_record["take_number"])
    summary_path = session_dir / f"{bpm}bpm" / f"take{take_number:02d}.txt"
    files = take_record.get("files", {})

    lines = [
        f"DJ Name: {take_record.get('dj_name', '')}",
        f"Date: {take_record.get('date', '')}",
        f"Scratch Type: {take_record.get('scratch_type', SCRATCH_TYPE)}",
        f"BPM: {format_bpm(bpm)}",
        f"Take: {take_number:02d}",
        f"Camera ID: {take_record.get('camera_id', '')}",
        f"Audio Source: {take_record.get('audio_source', '')}",
        f"Watch Source: {take_record.get('watch_source', '')}",
        f"Verbal Slate Used: {str(take_record.get('verbal_slate_used', True)).lower()}",
        f"Sync Clap Used: {str(take_record.get('sync_clap_used', True)).lower()}",
        "Files:",
    ]

    if files:
        for source in ("camA", "camB", "serato", "watch"):
            if source in files:
                lines.append(f"- {source}: {files[source]}")
    else:
        lines.append("- none")

    lines.append(f"Notes: {take_record.get('notes', '')}")
    summary_path.write_text("\n".join(lines) + "\n", encoding="utf-8")
    return summary_path


def scan_renamed_media(session_dir: Path) -> tuple[list[dict[str, Any]], list[str]]:
    records: list[dict[str, Any]] = []
    issues: list[str] = []

    for folder_name in ("audio", "video", "watch"):
        folder_path = session_dir / folder_name
        if not folder_path.exists():
            continue

        for path in sorted(folder_path.iterdir()):
            if path.is_dir():
                issues.append(f"Unexpected directory inside {folder_name}/: {path.name}")
                continue

            match = FILENAME_PATTERN.match(path.name)
            if not match:
                issues.append(f"Naming mismatch: {folder_name}/{path.name}")
                continue

            source = match.group("source")
            expected_folder = DESTINATION_FOLDERS[source]
            if expected_folder != folder_name:
                issues.append(
                    f"Wrong folder for {path.name}: expected {expected_folder}/, found {folder_name}/"
                )

            records.append(
                {
                    "path": path,
                    "relative_path": relative_to_session(session_dir, path),
                    "dj_token": match.group("dj"),
                    "bpm": int(match.group("bpm")),
                    "take_number": int(match.group("take")),
                    "source": source,
                    "extension": match.group("ext"),
                }
            )

    return records, issues


def group_media_records(
    records: list[dict[str, Any]]
) -> dict[tuple[int, int], dict[str, dict[str, Any]]]:
    grouped: dict[tuple[int, int], dict[str, dict[str, Any]]] = {}
    for record in records:
        key = (int(record["bpm"]), int(record["take_number"]))
        grouped.setdefault(key, {})[str(record["source"])] = record
    return grouped
