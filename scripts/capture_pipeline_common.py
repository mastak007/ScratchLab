#!/usr/bin/env python3
from __future__ import annotations

import array
import csv
import hashlib
import json
import math
import re
import shutil
import subprocess
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
    "scratch_only": "audio",
    "beat_only": "audio",
    "scratch_with_beat": "audio",
    "raw_original": "audio",
    "watch": "watch",
}

ALLOWED_EXTENSIONS = {
    "camA": {"mov"},
    "camB": {"mov"},
    "serato": {"wav"},
    "scratch_only": {"wav"},
    "beat_only": {"wav"},
    "scratch_with_beat": {"wav"},
    "raw_original": {"wav"},
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
    r"^(?P<dj>[A-Z0-9]+)_baby_(?P<bpm>\d{3})_take(?P<take>\d{2})_"
    r"(?P<source>camA|camB|serato|scratch_only|beat_only|scratch_with_beat|raw_original|watch)\.(?P<ext>mov|wav|csv)$"
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


def parse_bpm(value: str, allowed_bpms: tuple[int, ...] = ALLOWED_BPMS) -> int:
    try:
        bpm = int(value)
    except ValueError as exc:
        raise ValueError("BPM must be a whole number.") from exc
    if bpm not in allowed_bpms:
        raise ValueError(f"BPM must be one of {', '.join(str(item) for item in allowed_bpms)}.")
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


def resolve_take_log_media_path(session_dir: Path, raw_value: str) -> Path:
    """Resolve a take-log media path the way it is written.

    Take-log media columns are session-root-relative. App exports write
    canonical locations (`video/...`, `audio/...`), so the validator must not
    silently reroot them under `raw/`. Bare filenames with no directory
    component are the legacy staging convention from `create_session.py` /
    `rename_files.py`, where the operator drops sources straight into `raw/`;
    those still resolve there, but only when the file is not already present at
    the session root.
    """
    session_root = session_dir.resolve()
    candidate = Path(raw_value)
    if candidate.is_absolute():
        raise ValueError(f"Take log media paths must stay inside the session folder: {raw_value}")

    def _contained(path: Path) -> Path:
        resolved = (session_root / path).resolve()
        try:
            resolved.relative_to(session_root)
        except ValueError as exc:
            raise ValueError(
                f"Take log media paths must stay inside the session folder: {raw_value}"
            ) from exc
        return resolved

    as_written = _contained(candidate)
    if as_written.exists() or len(candidate.parts) > 1:
        return as_written
    return _contained(Path("raw") / candidate)


def audio_peak_sample(path: Path) -> float:
    """Return the largest absolute sample value in a WAV artifact.

    Reported in linear full-scale units, so 1.0 is 0 dBFS and anything above it
    would clip on playback or on conversion to an integer format.
    """
    metadata = read_riff_wave_metadata(path)
    sample_width = int(metadata["sample_width_bytes"])
    format_tag = int(metadata["format_tag"])

    with path.open("rb") as handle:
        header = handle.read(12)
        if len(header) < 12:
            raise ValueError(f"{path.name} is not a RIFF/WAVE file.")
        payload = b""
        while True:
            chunk_header = handle.read(8)
            if len(chunk_header) < 8:
                break
            chunk_id = chunk_header[0:4]
            chunk_size = int.from_bytes(chunk_header[4:8], "little")
            if chunk_id == b"data":
                payload = handle.read(chunk_size if chunk_size not in (0, 0xFFFFFFFF) else -1)
                break
            handle.seek(chunk_size + (chunk_size & 1), 1)

    if not payload:
        return 0.0

    if format_tag == RIFF_FORMAT_TAG_IEEE_FLOAT and sample_width == 4:
        values = array.array("f")
        values.frombytes(payload[: len(payload) - (len(payload) % 4)])
        return max((abs(value) for value in values), default=0.0)
    if format_tag == RIFF_FORMAT_TAG_PCM and sample_width == 2:
        values = array.array("h")
        values.frombytes(payload[: len(payload) - (len(payload) % 2)])
        return max((abs(value) / 32768.0 for value in values), default=0.0)
    if format_tag == RIFF_FORMAT_TAG_PCM and sample_width == 1:
        return max((abs(byte - 128) / 128.0 for byte in payload), default=0.0)

    raise ValueError(
        f"{path.name} uses a sample format this peak reader does not support"
        f" (tag {format_tag}, {sample_width} bytes per sample)."
    )


def peak_dbfs(peak_sample: float) -> float:
    if peak_sample <= 0:
        return float("-inf")
    return 20.0 * math.log10(peak_sample)


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


# RIFF chunk identifiers that carry no sample data. Real capture writers
# (AVAudioFile among them) pad the header area with these before `data`, so a
# reader that assumes `fmt ` is immediately followed by `data` will fail on a
# perfectly valid file.
RIFF_FORMAT_TAG_PCM = 0x0001
RIFF_FORMAT_TAG_IEEE_FLOAT = 0x0003
RIFF_FORMAT_TAG_EXTENSIBLE = 0xFFFE
SUPPORTED_RIFF_FORMAT_TAGS = (
    RIFF_FORMAT_TAG_PCM,
    RIFF_FORMAT_TAG_IEEE_FLOAT,
    RIFF_FORMAT_TAG_EXTENSIBLE,
)


def read_riff_wave_metadata(path: Path) -> dict[str, Any]:
    """Parse a RIFF/WAVE header without the stdlib `wave` module.

    `wave` only understands WAVE_FORMAT_PCM (tag 1) and raises on
    WAVE_FORMAT_IEEE_FLOAT (tag 3), which is what ScratchLab captures write.
    This walker also skips arbitrary non-data chunks (JUNK, FLLR, LIST, ...)
    and honours the odd-size word-alignment padding byte.
    """
    with path.open("rb") as handle:
        header = handle.read(12)
        if len(header) < 12 or header[0:4] != b"RIFF" or header[8:12] != b"WAVE":
            raise ValueError(f"{path.name} is not a RIFF/WAVE file.")

        file_size = path.stat().st_size
        fmt_chunk: bytes | None = None
        data_size: int | None = None

        while True:
            chunk_header = handle.read(8)
            if len(chunk_header) < 8:
                break
            chunk_id = chunk_header[0:4]
            chunk_size = int.from_bytes(chunk_header[4:8], "little")
            chunk_start = handle.tell()

            if chunk_id == b"fmt ":
                fmt_chunk = handle.read(min(chunk_size, 40))
            elif chunk_id == b"data":
                # A streaming writer may leave 0xFFFFFFFF here; fall back to
                # whatever actually remains in the file.
                remaining = max(0, file_size - chunk_start)
                data_size = remaining if chunk_size in (0, 0xFFFFFFFF) else min(chunk_size, remaining)
                break

            handle.seek(chunk_start + chunk_size + (chunk_size & 1))

    if fmt_chunk is None or len(fmt_chunk) < 16:
        raise ValueError(f"{path.name} has no readable RIFF fmt chunk.")
    if data_size is None:
        raise ValueError(f"{path.name} has no RIFF data chunk.")

    format_tag = int.from_bytes(fmt_chunk[0:2], "little")
    channel_count = int.from_bytes(fmt_chunk[2:4], "little")
    sample_rate = int.from_bytes(fmt_chunk[4:8], "little")
    block_align = int.from_bytes(fmt_chunk[12:14], "little")
    bits_per_sample = int.from_bytes(fmt_chunk[14:16], "little")

    if format_tag == RIFF_FORMAT_TAG_EXTENSIBLE and len(fmt_chunk) >= 26:
        # cbSize(2) + validBits(2) + channelMask(4), then the 16-byte GUID whose
        # first two bytes are the real format tag.
        format_tag = int.from_bytes(fmt_chunk[24:26], "little")
    if format_tag not in SUPPORTED_RIFF_FORMAT_TAGS:
        raise ValueError(f"{path.name} uses unsupported WAV format tag {format_tag}.")

    if block_align <= 0:
        block_align = max(1, channel_count * (bits_per_sample // 8))

    return {
        "channel_count": channel_count,
        "sample_rate_hz": sample_rate,
        "frame_count": data_size // block_align,
        "sample_width_bytes": max(1, bits_per_sample // 8),
        "format_tag": format_tag,
        "block_align": block_align,
        "data_offset_bytes": None,
    }


def ffprobe_audio_metadata(path: Path) -> dict[str, Any]:
    payload = run_ffprobe(path)
    streams = payload.get("streams", [])
    if not isinstance(streams, list):
        raise ValueError(f"ffprobe returned no streams for {path.name}.")
    audio_stream = next(
        (
            stream
            for stream in streams
            if isinstance(stream, dict) and stream.get("codec_type") == "audio"
        ),
        None,
    )
    if audio_stream is None:
        raise ValueError(f"{path.name} has no audio stream.")

    channel_count = parse_probe_int(audio_stream.get("channels"))
    sample_rate = parse_probe_int(audio_stream.get("sample_rate"))
    bits_per_sample = parse_probe_int(audio_stream.get("bits_per_sample")) or parse_probe_int(
        audio_stream.get("bits_per_raw_sample")
    )
    frame_count = parse_probe_int(audio_stream.get("duration_ts"))
    if frame_count is None:
        frame_count = parse_probe_int(audio_stream.get("nb_samples"))

    if channel_count is None or sample_rate is None or frame_count is None or not bits_per_sample:
        raise ValueError(f"ffprobe returned an incomplete audio payload for {path.name}.")

    return {
        "channel_count": channel_count,
        "sample_rate_hz": sample_rate,
        "frame_count": frame_count,
        "sample_width_bytes": max(1, bits_per_sample // 8),
    }


def probe_audio_metadata(path: Path) -> dict[str, Any]:
    """Probe a WAV artifact, preferring ffprobe and falling back to RIFF.

    ffprobe is authoritative when present because it reads the same container
    the app wrote. The RIFF walker keeps the validator usable on machines
    without ffmpeg installed. `wave` is deliberately not used: it rejects the
    IEEE Float32 files the capture pipeline produces.
    """
    ffprobe_error: Exception | None = None
    try:
        metadata = ffprobe_audio_metadata(path)
    except Exception as exc:  # noqa: BLE001 - fall back to the local parser
        ffprobe_error = exc
        try:
            metadata = read_riff_wave_metadata(path)
        except ValueError as riff_exc:
            raise ValueError(
                f"{path.name} is not a readable WAV file"
                f" (ffprobe: {ffprobe_error}; riff: {riff_exc})."
            ) from riff_exc

    channel_count = int(metadata["channel_count"])
    sample_rate = int(metadata["sample_rate_hz"])
    frame_count = int(metadata["frame_count"])
    sample_width = int(metadata["sample_width_bytes"])

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
    if source in {"serato", "scratch_only", "beat_only", "scratch_with_beat", "raw_original"}:
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

            canonical_source = "serato" if source == "scratch_only" else source

            records.append(
                {
                    "path": path,
                    "relative_path": relative_to_session(session_dir, path),
                    "dj_token": match.group("dj"),
                    "bpm": int(match.group("bpm")),
                    "take_number": int(match.group("take")),
                    "source": canonical_source,
                    "source_token": source,
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
