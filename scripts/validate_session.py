#!/usr/bin/env python3
from __future__ import annotations

import argparse
import sys
from pathlib import Path
from typing import Any

from capture_pipeline_common import (
    ALLOWED_BPMS,
    REQUIRED_DIRECTORIES,
    SCRATCH_TYPE,
    SEGMENT_COUNT,
    build_artifact_record,
    SOURCE_COLUMNS,
    build_standard_filename,
    group_media_records,
    normalize_extension,
    parse_bool,
    parse_bpm,
    parse_take_number,
    read_json,
    read_take_log,
    resolve_raw_path,
    scan_renamed_media,
    sanitize_dj_token,
    session_file_paths,
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Validate a Scratch Capture session folder and write a report."
    )
    parser.add_argument("session_dir", help="Path to the baby_scratch session directory")
    return parser.parse_args()


def resolve_path(path_text: str) -> Path:
    return Path(path_text).expanduser().resolve()


def format_take_label(bpm: int, take_number: int) -> str:
    return f"{bpm} BPM take {take_number:02d}"


MIN_PRIMARY_MEDIA_DURATION_SECONDS = 0.5
MAX_PRIMARY_AV_DURATION_DELTA_SECONDS = 0.5
MAX_VIDEO_PROBE_DURATION_DELTA_SECONDS = 0.25
MAX_VIDEO_PROBE_FRAME_RATE_DELTA_FPS = 0.001
OPTIONAL_MANIFEST_FILE_SOURCES = {"notation"}


def expected_camera_id(sources: dict[str, dict[str, Any]]) -> str | None:
    has_cam_a = "camA" in sources
    has_cam_b = "camB" in sources
    if has_cam_a:
        return "camA+camB" if has_cam_b else "camA"
    return None


def artifact_probe_matches(
    source: str,
    recorded_probe: dict[str, Any],
    expected_probe: dict[str, Any],
) -> bool:
    if source == "serato":
        return recorded_probe == expected_probe

    if source in {"camA", "camB"}:
        for key in ("kind", "width", "height", "codec"):
            if recorded_probe.get(key) != expected_probe.get(key):
                return False

        recorded_duration = recorded_probe.get("duration_seconds")
        expected_duration = expected_probe.get("duration_seconds")
        if not isinstance(recorded_duration, (int, float)) or not isinstance(expected_duration, (int, float)):
            return False
        if abs(float(recorded_duration) - float(expected_duration)) > MAX_VIDEO_PROBE_DURATION_DELTA_SECONDS:
            return False

        recorded_frame_rate = recorded_probe.get("frame_rate_fps")
        expected_frame_rate = expected_probe.get("frame_rate_fps")
        if recorded_frame_rate is None or expected_frame_rate is None:
            return recorded_frame_rate == expected_frame_rate
        if not isinstance(recorded_frame_rate, (int, float)) or not isinstance(expected_frame_rate, (int, float)):
            return False
        return abs(float(recorded_frame_rate) - float(expected_frame_rate)) <= MAX_VIDEO_PROBE_FRAME_RATE_DELTA_FPS

    return recorded_probe == expected_probe


def payload_contains_absolute_user_path(payload: Any) -> bool:
    if isinstance(payload, str):
        return "/Users/" in payload
    if isinstance(payload, dict):
        return any(payload_contains_absolute_user_path(value) for value in payload.values())
    if isinstance(payload, list):
        return any(payload_contains_absolute_user_path(item) for item in payload)
    return False


def validate_notation_document(
    notation_payload: Any,
    *,
    take_label: str,
    errors: list[str],
    warnings: list[str],
) -> None:
    if not isinstance(notation_payload, dict):
        errors.append(f"{take_label}: notation file must contain a JSON object.")
        return

    if payload_contains_absolute_user_path(notation_payload):
        errors.append(f"{take_label}: notation JSON must not contain absolute /Users paths.")

    for field in ("sessionID", "takeID", "scratchType"):
        value = notation_payload.get(field)
        if not isinstance(value, str) or not value.strip():
            errors.append(f"{take_label}: notation JSON is missing {field}.")

    for field in ("recordMovementEvents", "faderEvents", "mixerMidiEvents"):
        if not isinstance(notation_payload.get(field), list):
            errors.append(f"{take_label}: notation JSON field {field} must be an array.")

    notation_source = notation_payload.get("notationSource")
    if not isinstance(notation_source, str) or not notation_source.strip():
        errors.append(f"{take_label}: notation JSON is missing notationSource.")
    elif notation_source == "unavailable":
        warnings.append(f"{take_label}: notationSource is unavailable.")


def validate_take_media_sanity(
    take_label: str,
    *,
    session_dir: Path,
    grouped: dict[str, dict[str, Any]],
    errors: list[str],
) -> None:
    durations: dict[str, float] = {}

    for source in ("camA", "serato"):
        record = grouped.get(source)
        if not record:
            continue

        try:
            artifact = build_artifact_record(session_dir, Path(record["path"]), source)
        except Exception as exc:
            errors.append(f"{take_label}: could not probe {source} media for duration checks: {exc}")
            continue

        probe = artifact.get("probe")
        if not isinstance(probe, dict):
            errors.append(f"{take_label}: probed metadata for {source} is missing.")
            continue

        duration_value = probe.get("duration_seconds")
        if not isinstance(duration_value, (int, float)):
            errors.append(f"{take_label}: probed duration is missing for {source}.")
            continue

        duration = float(duration_value)
        durations[source] = duration
        if duration < MIN_PRIMARY_MEDIA_DURATION_SECONDS:
            errors.append(
                f"{take_label}: {source} duration is {duration:.3f}s, below the minimum {MIN_PRIMARY_MEDIA_DURATION_SECONDS:.3f}s."
            )

    cam_a_duration = durations.get("camA")
    serato_duration = durations.get("serato")
    if cam_a_duration is None or serato_duration is None:
        return

    duration_delta = abs(cam_a_duration - serato_duration)
    if duration_delta > MAX_PRIMARY_AV_DURATION_DELTA_SECONDS:
        errors.append(
            f"{take_label}: camA and serato durations differ by {duration_delta:.3f}s ({cam_a_duration:.3f}s vs {serato_duration:.3f}s; max {MAX_PRIMARY_AV_DURATION_DELTA_SECONDS:.3f}s)."
        )


def validate_manifest(
    manifest_data: dict[str, Any],
    *,
    session_dir: Path,
    grouped_files: dict[tuple[int, int], dict[str, dict[str, Any]]],
    errors: list[str],
    warnings: list[str],
) -> None:
    if manifest_data.get("scratch_type") != SCRATCH_TYPE:
        errors.append("Manifest scratch_type must be 'baby'.")
    if manifest_data.get("segment_count") != SEGMENT_COUNT:
        errors.append("Manifest segment_count must be 3.")

    takes = manifest_data.get("takes", [])
    if not isinstance(takes, list):
        errors.append("Manifest takes field must be a list.")
        return

    for index, take in enumerate(takes, start=1):
        label = f"manifest take #{index}"
        if not isinstance(take, dict):
            errors.append(f"{label}: record must be an object.")
            continue

        try:
            bpm = parse_bpm(str(take.get("bpm", "")))
            take_number = parse_take_number(str(take.get("take_number", "")))
            verbal_slate_used = parse_bool(
                str(take.get("verbal_slate_used", "")),
                field_name="verbal_slate_used",
            )
            sync_clap_used = parse_bool(
                str(take.get("sync_clap_used", "")),
                field_name="sync_clap_used",
            )
        except ValueError as exc:
            errors.append(f"{label}: {exc}")
            continue

        take_label = format_take_label(bpm, take_number)
        if take.get("scratch_type") != SCRATCH_TYPE:
            errors.append(f"{take_label}: manifest scratch_type must be 'baby'.")
        if int(take.get("segment_count", 0) or 0) != SEGMENT_COUNT:
            errors.append(f"{take_label}: manifest segment_count must be 3.")
        if take.get("audio_source") != "serato":
            errors.append(f"{take_label}: manifest audio_source must be 'serato'.")
        if take.get("watch_source") not in {"watch", "none"}:
            errors.append(f"{take_label}: manifest watch_source must be 'watch' or 'none'.")
        if not verbal_slate_used:
            warnings.append(f"{take_label}: verbal_slate_used is false.")
        if not sync_clap_used:
            warnings.append(f"{take_label}: sync_clap_used is false.")

        grouped = grouped_files.get((bpm, take_number))
        if not grouped:
            warnings.append(f"{take_label}: manifest entry has no renamed files.")
            continue

        validate_take_media_sanity(
            take_label,
            session_dir=session_dir,
            grouped=grouped,
            errors=errors,
        )

        expected_camera = expected_camera_id(grouped)
        if take.get("camera_id") != expected_camera:
            errors.append(
                f"{take_label}: manifest camera_id is {take.get('camera_id')!r}, expected {expected_camera!r}."
            )

        expected_watch = "watch" if "watch" in grouped else "none"
        if take.get("watch_source") != expected_watch:
            errors.append(
                f"{take_label}: manifest watch_source is {take.get('watch_source')!r}, expected {expected_watch!r}."
            )

        grouped_sources = set(grouped)
        files = take.get("files")
        if not isinstance(files, dict):
            errors.append(f"{take_label}: manifest files field must be an object.")
        else:
            file_sources = set(files)
            missing_file_sources = sorted(grouped_sources - file_sources)
            unexpected_file_sources = sorted(file_sources - grouped_sources - OPTIONAL_MANIFEST_FILE_SOURCES)
            if missing_file_sources:
                errors.append(
                    f"{take_label}: manifest files are missing source entries for: {', '.join(missing_file_sources)}."
                )
            if unexpected_file_sources:
                errors.append(
                    f"{take_label}: manifest files include unexpected source entries: {', '.join(unexpected_file_sources)}."
                )

            for source, relative_path in files.items():
                if not isinstance(relative_path, str) or not relative_path:
                    errors.append(f"{take_label}: manifest file path for {source} is missing.")
                    continue

                expected_relative_path = str(grouped.get(source, {}).get("relative_path") or "")
                if expected_relative_path and relative_path != expected_relative_path:
                    errors.append(
                        f"{take_label}: manifest file path for {source} is {relative_path!r}, expected {expected_relative_path!r}."
                    )

                path = session_dir / str(relative_path)
                if not path.exists():
                    errors.append(f"{take_label}: manifest file reference is missing: {relative_path}")

            notation_relative_path = files.get("notation")
            if not isinstance(notation_relative_path, str) or not notation_relative_path:
                errors.append(f"{take_label}: manifest files are missing source entries for: notation.")
            else:
                notation_path = session_dir / notation_relative_path
                if not notation_path.exists():
                    errors.append(f"{take_label}: manifest notation reference is missing: {notation_relative_path}")
                else:
                    try:
                        notation_payload = read_json(notation_path)
                    except Exception as exc:
                        errors.append(f"{take_label}: could not read notation JSON: {exc}")
                    else:
                        validate_notation_document(
                            notation_payload,
                            take_label=take_label,
                            errors=errors,
                            warnings=warnings,
                        )

        artifacts = take.get("artifacts")
        if not isinstance(artifacts, dict):
            errors.append(f"{take_label}: manifest artifacts field must be an object.")
            continue

        artifact_sources = set(artifacts)
        missing_artifact_sources = sorted(grouped_sources - artifact_sources)
        unexpected_artifact_sources = sorted(artifact_sources - grouped_sources)
        if missing_artifact_sources:
            errors.append(
                f"{take_label}: manifest artifacts are missing source entries for: {', '.join(missing_artifact_sources)}."
            )
        if unexpected_artifact_sources:
            errors.append(
                f"{take_label}: manifest artifacts include unexpected source entries: {', '.join(unexpected_artifact_sources)}."
            )

        for source, artifact in artifacts.items():
            if not isinstance(artifact, dict):
                errors.append(f"{take_label}: artifact record for {source} must be an object.")
                continue

            relative_path = artifact.get("path")
            if not isinstance(relative_path, str) or not relative_path:
                errors.append(f"{take_label}: artifact record for {source} is missing its path.")
                continue

            artifact_path = session_dir / relative_path
            if not artifact_path.exists():
                errors.append(f"{take_label}: artifact path is missing on disk for {source}: {relative_path}")
                continue

            try:
                expected_artifact = build_artifact_record(session_dir, artifact_path, source)
            except Exception as exc:
                errors.append(f"{take_label}: could not probe artifact metadata for {source}: {exc}")
                continue
            if artifact.get("path") != expected_artifact["path"]:
                errors.append(
                    f"{take_label}: artifact path for {source} is {artifact.get('path')!r}, expected {expected_artifact['path']!r}."
                )
            if artifact.get("bytes") != expected_artifact["bytes"]:
                errors.append(
                    f"{take_label}: artifact bytes for {source} is {artifact.get('bytes')!r}, expected {expected_artifact['bytes']!r}."
                )
            if artifact.get("sha256") != expected_artifact["sha256"]:
                errors.append(
                    f"{take_label}: artifact sha256 for {source} does not match the file on disk."
                )
            if not artifact_probe_matches(source, artifact.get("probe", {}), expected_artifact["probe"]):
                errors.append(
                    f"{take_label}: artifact probe metadata for {source} does not match the file on disk."
                )


def validate_take_log(
    take_rows: list[dict[str, str]],
    *,
    session_dir: Path,
    dj_token: str,
    grouped_files: dict[tuple[int, int], dict[str, dict[str, Any]]],
    errors: list[str],
    warnings: list[str],
) -> set[tuple[int, int]]:
    seen_take_keys: set[tuple[int, int]] = set()

    for line_number, row in enumerate(take_rows, start=2):
        label = f"take log line {line_number}"

        try:
            bpm = parse_bpm(row["bpm"])
            take_number = parse_take_number(row["take_number"])
            verbal_slate_used = parse_bool(row["verbal_slate_used"], field_name="verbal_slate_used")
            sync_clap_used = parse_bool(row["sync_clap_used"], field_name="sync_clap_used")
        except ValueError as exc:
            errors.append(f"{label}: {exc}")
            continue

        take_key = (bpm, take_number)
        if take_key in seen_take_keys:
            errors.append(f"{label}: duplicate entry for {format_take_label(bpm, take_number)}")
            continue
        seen_take_keys.add(take_key)

        if not verbal_slate_used:
            warnings.append(f"{label}: verbal_slate_used is false.")
        if not sync_clap_used:
            warnings.append(f"{label}: sync_clap_used is false.")

        grouped = grouped_files.get(take_key, {})
        if not grouped:
            errors.append(f"{label}: no renamed files found for {format_take_label(bpm, take_number)}.")

        for source, column in SOURCE_COLUMNS.items():
            raw_value = row[column]
            if not raw_value:
                continue

            try:
                raw_path = resolve_raw_path(session_dir, raw_value)
            except ValueError as exc:
                errors.append(f"{label}: {exc}")
                continue
            if raw_path.exists():
                try:
                    normalize_extension(source, raw_path)
                except ValueError as exc:
                    errors.append(f"{label}: {exc}")
            else:
                warnings.append(f"{label}: raw source file is missing: {raw_path}")

            expected_name = build_standard_filename(dj_token, bpm, take_number, source)
            if source not in grouped:
                errors.append(f"{label}: missing renamed {source} file {expected_name}.")

    return seen_take_keys


def build_report_lines(
    *,
    session_dir: Path,
    grouped_files: dict[tuple[int, int], dict[str, dict[str, Any]]],
    valid_take_counts: dict[int, int],
    warnings: list[str],
    errors: list[str],
) -> list[str]:
    lines = [
        "Scratch Capture Validation Report",
        f"Session: {session_dir}",
        f"Status: {'PASS' if not errors else 'FAIL'}",
        "",
        "Summary:",
    ]

    for bpm in ALLOWED_BPMS:
        total = len([key for key in grouped_files if key[0] == bpm])
        valid = valid_take_counts.get(bpm, 0)
        lines.append(f"- {bpm} BPM: {valid} valid take(s), {total} renamed take(s)")

    if warnings:
        lines.append("")
        lines.append("Warnings:")
        for item in warnings:
            lines.append(f"- {item}")

    if errors:
        lines.append("")
        lines.append("Errors:")
        for item in errors:
            lines.append(f"- {item}")

    return lines


def main() -> int:
    args = parse_args()
    session_dir = resolve_path(args.session_dir)
    paths = session_file_paths(session_dir)

    warnings: list[str] = []
    errors: list[str] = []

    for directory_name in REQUIRED_DIRECTORIES:
        if not (session_dir / directory_name).exists():
            errors.append(f"Missing required directory: {directory_name}/")

    manifest_data: dict[str, Any] = {}
    if paths["manifest"].exists():
        try:
            payload = read_json(paths["manifest"])
            if isinstance(payload, dict):
                manifest_data = payload
            else:
                errors.append("Manifest file must contain a JSON object.")
        except Exception as exc:  # pragma: no cover - defensive path
            errors.append(f"Could not read manifest: {exc}")
    else:
        errors.append("Missing manifest file: manifests/session_manifest.json")

    take_rows: list[dict[str, str]] = []
    if paths["take_log"].exists():
        try:
            take_rows = read_take_log(paths["take_log"])
        except ValueError as exc:
            errors.append(str(exc))
    else:
        errors.append("Missing take log file: manifests/take_log.csv")

    renamed_files, scan_issues = scan_renamed_media(session_dir)
    errors.extend(scan_issues)
    grouped_files = group_media_records(renamed_files)

    dj_tokens = {record["dj_token"] for record in renamed_files}
    manifest_dj_token = str(manifest_data.get("dj_token", "")).strip()
    if manifest_dj_token:
        try:
            manifest_dj_token = sanitize_dj_token(manifest_dj_token)
        except ValueError:
            errors.append("Manifest dj_token is invalid.")

    if len(dj_tokens) > 1:
        errors.append(f"Multiple DJ tokens found in renamed files: {', '.join(sorted(dj_tokens))}")

    dj_token = manifest_dj_token or next(iter(dj_tokens), session_dir.parent.parent.name)
    try:
        dj_token = sanitize_dj_token(dj_token)
    except ValueError:
        errors.append("Could not determine a valid DJ token for validation.")
        dj_token = ""

    valid_take_counts: dict[int, int] = {}
    for bpm in ALLOWED_BPMS:
        take_numbers = sorted(key[1] for key in grouped_files if key[0] == bpm)
        if not take_numbers:
            errors.append(f"Missing BPM set: {bpm} BPM has no renamed takes.")
            valid_take_counts[bpm] = 0
            continue

        expected_numbers = set(range(1, max(take_numbers) + 1))
        missing_numbers = sorted(expected_numbers - set(take_numbers))
        if missing_numbers:
            warnings.append(
                f"{bpm} BPM is missing take numbers: {', '.join(f'take{number:02d}' for number in missing_numbers)}"
            )

        valid_take_count = 0
        for take_number in take_numbers:
            take_label = format_take_label(bpm, take_number)
            grouped = grouped_files[(bpm, take_number)]

            if "camA" not in grouped:
                errors.append(f"{take_label}: missing camA video file.")
            if "serato" not in grouped:
                errors.append(f"{take_label}: missing serato audio file.")

            if "camA" in grouped and "serato" in grouped:
                valid_take_count += 1

        valid_take_counts[bpm] = valid_take_count

    if manifest_data:
        validate_manifest(
            manifest_data,
            session_dir=session_dir,
            grouped_files=grouped_files,
            errors=errors,
            warnings=warnings,
        )

    take_log_keys: set[tuple[int, int]] = set()
    if take_rows and dj_token:
        take_log_keys = validate_take_log(
            take_rows,
            session_dir=session_dir,
            dj_token=dj_token,
            grouped_files=grouped_files,
            errors=errors,
            warnings=warnings,
        )

    missing_from_take_log = sorted(set(grouped_files) - take_log_keys)
    for bpm, take_number in missing_from_take_log:
        errors.append(
            f"{format_take_label(bpm, take_number)}: renamed files exist on disk but the take is missing from manifests/take_log.csv."
        )

    report_lines = build_report_lines(
        session_dir=session_dir,
        grouped_files=grouped_files,
        valid_take_counts=valid_take_counts,
        warnings=warnings,
        errors=errors,
    )
    paths["validation_report"].parent.mkdir(parents=True, exist_ok=True)
    paths["validation_report"].write_text("\n".join(report_lines) + "\n", encoding="utf-8")

    for line in report_lines:
        print(line)

    return 1 if errors else 0


if __name__ == "__main__":
    raise SystemExit(main())
