#!/usr/bin/env python3
from __future__ import annotations

import argparse
import csv
import re
import sys
from datetime import datetime
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
    audio_peak_sample,
    peak_dbfs,
    read_json,
    read_take_log,
    resolve_take_log_media_path,
    scan_renamed_media,
    sanitize_dj_token,
    session_file_paths,
    validate_date_string,
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
# Generated and mixed stems must stay inside full scale. `scratch_only` is the
# captured signal and is only reported, never rewritten, so it is held to plain
# full scale; the stems ScratchLab renders itself are held to a real headroom
# target so a later integer conversion cannot clip.
MAX_STEM_PEAK_SAMPLE = 1.0
GENERATED_STEM_PEAK_CEILING_DBFS = -1.0
GENERATED_STEM_SOURCES = ("beat_only",)
FULL_SCALE_STEM_SOURCES = ("scratch_only", "beat_only", "scratch_with_beat", "serato")
OPTIONAL_MANIFEST_FILE_SOURCES = {"notation", "scratch_only", "raw_original"}
OPTIONAL_MANIFEST_ARTIFACT_SOURCES = {"scratch_only", "raw_original"}


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
    if source in {"serato", "scratch_only", "beat_only", "scratch_with_beat", "raw_original"}:
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
    media_duration: float | None = None,
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

    if media_duration is not None:
        tolerance = 0.001
        for field in ("recordMovementEvents", "audioEvents", "faderEvents"):
            for index, event in enumerate(notation_payload.get(field, [])):
                if not isinstance(event, dict):
                    continue
                end_time = event.get("endTime")
                if isinstance(end_time, (int, float)) and float(end_time) > media_duration + tolerance:
                    errors.append(
                        f"{take_label}: {field}[{index}] ends at {float(end_time):.6f}s,"
                        f" beyond scratch media duration {media_duration:.6f}s."
                    )
        for index, event in enumerate(notation_payload.get("mixerMidiEvents", [])):
            if not isinstance(event, dict):
                continue
            event_time = event.get("takeRelativeTime")
            if isinstance(event_time, (int, float)) and float(event_time) > media_duration + tolerance:
                errors.append(
                    f"{take_label}: mixerMidiEvents[{index}] occurs at {float(event_time):.6f}s,"
                    f" beyond scratch media duration {media_duration:.6f}s."
                )

    for index, event in enumerate(notation_payload.get("faderEvents", [])):
        if not isinstance(event, dict):
            errors.append(f"{take_label}: faderEvents[{index}] must be an object.")
            continue

        for numeric_field in ("startTime", "endTime", "fromValue", "toValue", "confidence"):
            value = event.get(numeric_field)
            if not isinstance(value, (int, float)):
                errors.append(f"{take_label}: faderEvents[{index}].{numeric_field} must be numeric.")

        event_kind = event.get("eventKind")
        if not isinstance(event_kind, str) or not event_kind.strip():
            errors.append(f"{take_label}: faderEvents[{index}].eventKind must be a string.")

        control = event.get("control")
        if not isinstance(control, str) or control not in {"crossfader"}:
            errors.append(f"{take_label}: faderEvents[{index}].control must be a known control.")

        source = event.get("source")
        if source != "midi":
            errors.append(f"{take_label}: faderEvents[{index}].source must be 'midi'.")

        for bounded_field in ("fromValue", "toValue", "confidence"):
            value = event.get(bounded_field)
            if isinstance(value, (int, float)) and not 0.0 <= float(value) <= 1.0:
                errors.append(f"{take_label}: faderEvents[{index}].{bounded_field} must be between 0 and 1.")

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
) -> dict[str, float]:
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
        return durations

    duration_delta = abs(cam_a_duration - serato_duration)
    if duration_delta > MAX_PRIMARY_AV_DURATION_DELTA_SECONDS:
        errors.append(
            f"{take_label}: camA and serato durations differ by {duration_delta:.3f}s ({cam_a_duration:.3f}s vs {serato_duration:.3f}s; max {MAX_PRIMARY_AV_DURATION_DELTA_SECONDS:.3f}s)."
        )
    return durations



# How far past the end of the canonical take a Watch capture may legitimately
# run before it stops being finalization latency and starts being a Watch that
# never got the stop.
#
# The Watch's Core Motion stop lands after the Mac's media stop: the command
# crosses MultipeerConnectivity to the iPhone, WatchConnectivity to the Watch,
# and the Watch then finalizes its motion file. `CaptureWatchStopPolicy` in the
# app bounds one acknowledgement attempt at 2.0 s and permits a single retry, so
# the whole handshake cannot honestly exceed 4.0 s.
#
#   * over 2.0 s — one acknowledgement window — is a warning: slower than a
#     healthy stop, still explicable.
#   * over 4.0 s — longer than the handshake can possibly take — is an error:
#     the Watch kept recording after the take ended.
#
# The raw Watch CSV is never truncated or rewritten to satisfy this. The
# overrun is reported; every captured sample is preserved.
WATCH_OVERRUN_WARNING_SECONDS = 2.0
WATCH_OVERRUN_ERROR_SECONDS = 4.0

# How far ahead of the take's media the Watch may start before it is worth
# saying so. The Watch begins when the start handshake resolves, so a count-in
# plus camera startup legitimately puts it a couple of seconds early; much more
# than that means the start handshake stalled.
WATCH_LEAD_IN_WARNING_SECONDS = 3.0


def parse_iso8601(value: Any) -> datetime | None:
    """Parse an ISO-8601 instant as written by the app's exporter, or None."""
    if not isinstance(value, str) or not value:
        return None
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None


def watch_capture_duration_seconds(path: Path) -> float | None:
    """Largest `elapsed_time` in a Watch motion CSV, or None if unreadable.

    Read-only: the file on disk is the raw capture record and must survive
    validation byte-for-byte.
    """
    try:
        with path.open(newline="", encoding="utf-8") as handle:
            reader = csv.DictReader(handle)
            if reader.fieldnames is None or "elapsed_time" not in reader.fieldnames:
                return None
            maximum: float | None = None
            for row in reader:
                raw = (row.get("elapsed_time") or "").strip()
                if not raw:
                    continue
                try:
                    value = float(raw)
                except ValueError:
                    continue
                if maximum is None or value > maximum:
                    maximum = value
            return maximum
    except OSError:
        return None


def load_take_alignment(session_dir: Path) -> dict[int, dict[str, Any]]:
    """Per-take watch/take alignment instants from app-side metadata.

    `manifests/session_metadata.json` is optional — a session staged by the
    canonical scripts has none — so an empty mapping is a normal result, not an
    error.
    """
    path = session_dir / "manifests" / "session_metadata.json"
    if not path.exists():
        return {}
    try:
        payload = read_json(path)
    except Exception:  # pragma: no cover - defensive path
        return {}
    if not isinstance(payload, dict):
        return {}
    takes = payload.get("takes")
    if not isinstance(takes, list):
        return {}

    alignment: dict[int, dict[str, Any]] = {}
    for take in takes:
        if not isinstance(take, dict):
            continue
        number = take.get("takeNumber")
        if isinstance(number, int):
            alignment[number] = take
    return alignment


def validate_take_watch_duration(
    take_label: str,
    *,
    session_dir: Path,
    grouped: dict[str, dict[str, Any]],
    media_durations: dict[str, float],
    alignment: dict[str, Any] | None,
    errors: list[str],
    warnings: list[str],
) -> None:
    """Report a Watch capture that ran past the end of the take.

    The BVB regression (2026-09-04): a take whose Watch kept recording because
    the Mac's Stop never reached it.

    The quantity that matters is the gap between when the Watch **stopped** and
    when the take's media **stopped** — not the difference between the two
    durations. Those are different questions, because the Watch's window and
    the take's window do not share a start: the Watch begins as soon as the
    start handshake resolves, while media begins after the count-in and camera
    startup. Session `1ce25396-…` recorded 15.411 s of motion against a 10.000 s
    take and stopped in the same second the Mac asked it to — the whole 5.411 s
    was a *lead-in*, and comparing durations reported it as an overrun.

    So: when the archive carries the alignment instants, compare the ends. When
    it does not (any export written before those fields existed), say plainly
    that the two cannot be told apart rather than asserting the worse one.
    """
    record = grouped.get("watch")
    if not record:
        return

    watch_duration = watch_capture_duration_seconds(Path(record["path"]))
    if watch_duration is None:
        warnings.append(f"{take_label}: watch motion CSV has no readable elapsed_time column.")
        return

    watch_end = parse_iso8601((alignment or {}).get("watchCaptureEndedAt"))
    take_stop = parse_iso8601((alignment or {}).get("takeStopRequestedAt"))

    if watch_end is not None and take_stop is not None:
        overrun = (watch_end - take_stop).total_seconds()
        report_watch_lead_in(take_label, alignment=alignment or {}, warnings=warnings)
        if overrun <= WATCH_OVERRUN_WARNING_SECONDS:
            return
        message = (
            f"{take_label}: watch motion stopped {overrun:.3f}s after the take's"
            f" stop was requested"
        )
        if overrun > WATCH_OVERRUN_ERROR_SECONDS:
            errors.append(
                f"{message} (max {WATCH_OVERRUN_ERROR_SECONDS:.3f}s). The watch"
                " kept recording after the take ended."
            )
        else:
            warnings.append(
                f"{message} (over {WATCH_OVERRUN_WARNING_SECONDS:.3f}s). Watch"
                " stop was slower than a healthy acknowledgement."
            )
        return

    # No alignment recorded. A duration difference is real, but it cannot be
    # attributed to either end of the take, so it is never reported as an
    # overrun.
    take_duration = media_durations.get("serato")
    if take_duration is None:
        take_duration = media_durations.get("camA")
    if take_duration is None:
        return

    excess = watch_duration - float(take_duration)
    if excess <= WATCH_OVERRUN_WARNING_SECONDS:
        return
    warnings.append(
        f"{take_label}: watch motion window is {excess:.3f}s longer than the take"
        f" ({watch_duration:.3f}s against {float(take_duration):.3f}s). This archive"
        " records no watch/take alignment, so a late stop cannot be told apart"
        " from an early start."
    )


def report_watch_lead_in(
    take_label: str,
    *,
    alignment: dict[str, Any],
    warnings: list[str],
) -> None:
    """Surface a Watch that began well before the take's media did.

    Not a defect in itself — motion through the count-in is wanted — but a large
    lead-in means the start handshake is stalling, and it is the number that was
    previously being misread as overrun.
    """
    watch_start = parse_iso8601(alignment.get("watchCaptureStartedAt"))
    take_start = parse_iso8601(alignment.get("takeStartedAt"))
    if watch_start is None or take_start is None:
        return
    lead_in = (take_start - watch_start).total_seconds()
    if lead_in > WATCH_LEAD_IN_WARNING_SECONDS:
        warnings.append(
            f"{take_label}: watch motion began {lead_in:.3f}s before the take's media"
            f" (over {WATCH_LEAD_IN_WARNING_SECONDS:.3f}s). Motion through the count-in"
            " is expected; a lead-in this long usually means the watch start"
            " handshake stalled."
        )


def validate_manifest(
    manifest_data: dict[str, Any],
    *,
    session_dir: Path,
    grouped_files: dict[tuple[int, int], dict[str, dict[str, Any]]],
    errors: list[str],
    warnings: list[str],
    allowed_bpms: tuple[int, ...],
) -> None:
    take_alignment = load_take_alignment(session_dir)
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
            bpm = parse_bpm(str(take.get("bpm", "")), allowed_bpms)
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
        if take.get("audio_source") not in {"serato", "scratchlab_output"}:
            errors.append(f"{take_label}: manifest audio_source must identify a supported capture source.")
        if take.get("watch_source") not in {"watch", "none"}:
            errors.append(f"{take_label}: manifest watch_source must be 'watch' or 'none'.")
        if manifest_data.get("verbal_slate_required") is True and not verbal_slate_used:
            warnings.append(f"{take_label}: verbal_slate_used is false.")
        if manifest_data.get("sync_clap_required") is True and not sync_clap_used:
            warnings.append(f"{take_label}: sync_clap_used is false.")

        grouped = grouped_files.get((bpm, take_number))
        if not grouped:
            warnings.append(f"{take_label}: manifest entry has no renamed files.")
            continue

        media_durations = validate_take_media_sanity(
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

        validate_take_watch_duration(
            take_label,
            session_dir=session_dir,
            grouped=grouped,
            media_durations=media_durations,
            alignment=take_alignment.get(take_number),
            errors=errors,
            warnings=warnings,
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
                if source == "scratch_only" and not expected_relative_path:
                    expected_relative_path = str(grouped.get("serato", {}).get("relative_path") or "")
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
                            media_duration=media_durations.get("serato"),
                        )

        artifacts = take.get("artifacts")
        if not isinstance(artifacts, dict):
            errors.append(f"{take_label}: manifest artifacts field must be an object.")
            continue

        artifact_sources = set(artifacts)
        missing_artifact_sources = sorted(grouped_sources - artifact_sources)
        unexpected_artifact_sources = sorted(artifact_sources - grouped_sources - OPTIONAL_MANIFEST_ARTIFACT_SOURCES)
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
                expected_artifact = build_artifact_record(
                    session_dir,
                    artifact_path,
                    "serato" if source == "scratch_only" else source,
                )
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

            if source in FULL_SCALE_STEM_SOURCES:
                try:
                    peak_sample = audio_peak_sample(artifact_path)
                except ValueError as exc:
                    errors.append(f"{take_label}: could not measure {source} peak level: {exc}")
                else:
                    measured_dbfs = peak_dbfs(peak_sample)
                    if peak_sample > MAX_STEM_PEAK_SAMPLE:
                        errors.append(
                            f"{take_label}: {source} peaks at {peak_sample:.6f}"
                            f" ({measured_dbfs:+.6f} dBFS), above full scale."
                        )
                    elif (
                        source in GENERATED_STEM_SOURCES
                        and measured_dbfs > GENERATED_STEM_PEAK_CEILING_DBFS
                    ):
                        errors.append(
                            f"{take_label}: generated stem {source} peaks at {measured_dbfs:+.6f} dBFS,"
                            f" above the {GENERATED_STEM_PEAK_CEILING_DBFS:+.1f} dBFS headroom ceiling."
                        )

        stem_availability = take.get("stem_availability")
        if stem_availability is not None:
            if not isinstance(stem_availability, dict):
                errors.append(f"{take_label}: stem_availability must be an object.")
            else:
                valid_statuses = {"available", "unavailable"}
                files_map = files if isinstance(files, dict) else {}
                for stem in ("scratch_only", "beat_only", "scratch_with_beat"):
                    status = stem_availability.get(stem)
                    if status is None:
                        continue
                    if status not in valid_statuses:
                        errors.append(
                            f"{take_label}: stem_availability.{stem} has invalid value {status!r};"
                            f" must be 'available' or 'unavailable'."
                        )
                        continue
                    if status == "available":
                        stem_path = files_map.get(stem)
                        if not stem_path:
                            errors.append(
                                f"{take_label}: stem_availability marks {stem} as available"
                                f" but files.{stem} is missing."
                            )
                        elif not (session_dir / str(stem_path)).exists():
                            errors.append(
                                f"{take_label}: stem_availability marks {stem} as available"
                                f" but the file is missing on disk: {stem_path}"
                            )

        available_stem_frames = {
            stem: artifact.get("probe", {}).get("frame_count")
            for stem, artifact in artifacts.items()
            if stem in {"scratch_only", "beat_only", "scratch_with_beat"}
            and isinstance(artifact, dict)
            and isinstance(artifact.get("probe"), dict)
            and isinstance(artifact.get("probe", {}).get("frame_count"), int)
        }
        if len(set(available_stem_frames.values())) > 1:
            detail = ", ".join(f"{stem}={frames}" for stem, frames in sorted(available_stem_frames.items()))
            errors.append(f"{take_label}: audio stem frame counts differ: {detail}.")


SESSION_FOLDER_DATE_PATTERN = re.compile(r"^session_(?P<date>\d{4}_\d{2}_\d{2})_")


def session_folder_date(session_dir: Path) -> str | None:
    """Return the calendar date encoded in a `session_YYYY_MM_DD_...` folder."""
    match = SESSION_FOLDER_DATE_PATTERN.match(session_dir.name)
    if match is None:
        return None
    return match.group("date").replace("_", "-")


def validate_session_dates(
    session_dir: Path,
    manifest_data: dict[str, Any],
    *,
    errors: list[str],
) -> None:
    """Enforce the single session-date policy.

    Policy (documented in docs/capture_spec_v1.md): a session's calendar date is
    the capture device's LOCAL date at session start. The session folder name,
    `session_manifest.json.date`, and every take's `date` all carry that one
    value. Absolute instants (`createdAt`, `generatedAt`) stay UTC ISO-8601 and
    are deliberately not required to share the calendar day.
    """
    manifest_date = manifest_data.get("date")
    folder_date = session_folder_date(session_dir)

    if not isinstance(manifest_date, str) or not manifest_date:
        errors.append("Manifest date must be a YYYY-MM-DD string.")
        manifest_date = None
    else:
        try:
            validate_date_string(manifest_date)
        except ValueError as exc:
            errors.append(f"Manifest date is invalid: {exc}")
            manifest_date = None

    if folder_date is not None and manifest_date is not None and folder_date != manifest_date:
        errors.append(
            f"Session folder date {folder_date} does not match manifest date {manifest_date};"
            " both must be the capture device's local session date."
        )

    takes = manifest_data.get("takes")
    if not isinstance(takes, list) or manifest_date is None:
        return
    for index, take in enumerate(takes):
        if not isinstance(take, dict):
            continue
        take_date = take.get("date")
        if take_date != manifest_date:
            errors.append(
                f"manifest take {index + 1}: date {take_date!r} does not match session date"
                f" {manifest_date!r}."
            )


DEGRADED_WATCH_SYNC_STATES = {"requested", "timedOut", "unavailable", "failed"}
KNOWN_WATCH_SYNC_STATES = {"notRequested", "acknowledged"} | DEGRADED_WATCH_SYNC_STATES
PLANNED_DURATION_TOLERANCE_SECONDS = 0.5
STOP_REASON_PLANNED_DURATION_REACHED = "planned_duration_reached"
KNOWN_STOP_REASONS = {
    "manual",
    STOP_REASON_PLANNED_DURATION_REACHED,
    "interrupted",
    "capture_error",
    "media_limit",
}


def validate_take_watch_state(
    take: dict[str, Any],
    *,
    label: str,
    errors: list[str],
    warnings: list[str],
) -> None:
    """Keep Watch absence honest and catch motion that was linked but lost.

    `watch_source` in the canonical manifest is a two-valued dataset field, so
    it cannot distinguish "no Watch was requested" from "a Watch acknowledged
    and its motion went missing". The app-side metadata carries the real sync
    state; this reads it so a degraded take says so out loud instead of looking
    identical to a session recorded without a Watch.
    """
    sync_state = take.get("watchSyncState")
    linked = take.get("watchLinkedMotionFileName")
    exported = take.get("watchMotionExported")

    if sync_state is None:
        return
    if sync_state not in KNOWN_WATCH_SYNC_STATES:
        errors.append(
            f"{label}: watchSyncState {sync_state!r} is not one of"
            f" {', '.join(sorted(KNOWN_WATCH_SYNC_STATES))}."
        )
        return

    # Motion the sidecar claims to own must reach the archive. Anything else is
    # evidence quietly dropped between capture and export.
    if linked and exported is False:
        errors.append(
            f"{label}: sidecar links Watch motion {linked!r} but it was not exported."
        )
    if sync_state == "acknowledged" and not linked:
        errors.append(
            f"{label}: watchSyncState is 'acknowledged' but no Watch motion is linked;"
            " a synchronised take must carry its motion or say why it does not."
        )
    if sync_state in DEGRADED_WATCH_SYNC_STATES:
        warnings.append(
            f"{label}: Watch motion is absent because sync state is {sync_state!r}"
            " — this take is not Watch-synchronised."
        )


def validate_take_stop_reasons(
    session_dir: Path,
    *,
    errors: list[str],
    warnings: list[str],
) -> None:
    """Check planned-versus-actual duration only where a plan was in force.

    A take that ran 16.7 s under a 64 s safety cap and was stopped by hand is a
    complete take, not a 47 s shortfall. Only `planned_duration_reached` asserts
    that a chosen duration elapsed, so only that reason makes the two numbers
    comparable.

    `manifests/session_metadata.json` is app-side metadata and is optional; a
    session staged by the canonical scripts has no such file and is unaffected.
    """
    metadata_path = session_dir / "manifests" / "session_metadata.json"
    if not metadata_path.exists():
        return

    try:
        payload = read_json(metadata_path)
    except Exception as exc:  # pragma: no cover - defensive path
        errors.append(f"Could not read session_metadata.json: {exc}")
        return
    if not isinstance(payload, dict):
        errors.append("session_metadata.json must contain a JSON object.")
        return

    takes = payload.get("takes")
    if not isinstance(takes, list):
        return

    for take in takes:
        if not isinstance(take, dict):
            continue
        label = f"session_metadata take {take.get('takeID') or take.get('takeNumber') or '?'}"

        stop_reason = take.get("stopReason")
        if stop_reason is None:
            warnings.append(f"{label}: no stopReason recorded.")
        elif stop_reason not in KNOWN_STOP_REASONS:
            errors.append(
                f"{label}: stopReason {stop_reason!r} is not one of"
                f" {', '.join(sorted(KNOWN_STOP_REASONS))}."
            )

        validate_take_watch_state(take, label=label, errors=errors, warnings=warnings)

        planned = take.get("plannedTakeDurationSeconds")
        actual = take.get("actualTakeDurationSeconds")

        if stop_reason != STOP_REASON_PLANNED_DURATION_REACHED:
            # A cap is not a plan. Flagging here is what made a manually
            # stopped take look truncated.
            if planned is not None and stop_reason is not None:
                warnings.append(
                    f"{label}: plannedTakeDurationSeconds is set but the take stopped"
                    f" via {stop_reason!r}; the planned duration did not elapse."
                )
            continue

        if not isinstance(planned, (int, float)):
            errors.append(
                f"{label}: stopReason is {STOP_REASON_PLANNED_DURATION_REACHED!r}"
                " but no plannedTakeDurationSeconds is recorded."
            )
            continue
        if not isinstance(actual, (int, float)):
            errors.append(f"{label}: no actualTakeDurationSeconds recorded to compare against.")
            continue
        if abs(float(actual) - float(planned)) > PLANNED_DURATION_TOLERANCE_SECONDS:
            errors.append(
                f"{label}: planned {float(planned):.3f}s but captured"
                f" {float(actual):.3f}s after {STOP_REASON_PLANNED_DURATION_REACHED}"
                f" (max {PLANNED_DURATION_TOLERANCE_SECONDS:.3f}s)."
            )


def validate_take_log(
    take_rows: list[dict[str, str]],
    *,
    session_dir: Path,
    dj_token: str,
    grouped_files: dict[tuple[int, int], dict[str, dict[str, Any]]],
    errors: list[str],
    warnings: list[str],
    allowed_bpms: tuple[int, ...],
    verbal_slate_required: bool,
    sync_clap_required: bool,
) -> set[tuple[int, int]]:
    seen_take_keys: set[tuple[int, int]] = set()

    for line_number, row in enumerate(take_rows, start=2):
        label = f"take log line {line_number}"

        try:
            bpm = parse_bpm(row["bpm"], allowed_bpms)
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

        if verbal_slate_required and not verbal_slate_used:
            warnings.append(f"{label}: verbal_slate_used is false.")
        if sync_clap_required and not sync_clap_used:
            warnings.append(f"{label}: sync_clap_used is false.")

        grouped = grouped_files.get(take_key, {})
        if not grouped:
            errors.append(f"{label}: no renamed files found for {format_take_label(bpm, take_number)}.")

        for source, column in SOURCE_COLUMNS.items():
            raw_value = row[column]
            if not raw_value:
                continue

            try:
                source_path = resolve_take_log_media_path(session_dir, raw_value)
            except ValueError as exc:
                errors.append(f"{label}: {exc}")
                continue
            if source_path.exists():
                try:
                    normalize_extension(source, source_path)
                except ValueError as exc:
                    errors.append(f"{label}: {exc}")
            else:
                warnings.append(f"{label}: take log source file is missing: {source_path}")

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
    allowed_bpms: tuple[int, ...],
) -> list[str]:
    lines = [
        "Scratch Capture Validation Report",
        f"Session: {session_dir}",
        f"Status: {'PASS' if not errors else 'FAIL'}",
        "",
        "Summary:",
    ]

    for bpm in allowed_bpms:
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

    raw_allowed_bpms = manifest_data.get("allowed_bpms")
    if isinstance(raw_allowed_bpms, list) and raw_allowed_bpms:
        parsed_allowed_bpms = [value for value in raw_allowed_bpms if isinstance(value, int) and not isinstance(value, bool) and 1 <= value <= 999]
        if len(parsed_allowed_bpms) != len(raw_allowed_bpms) or len(set(parsed_allowed_bpms)) != len(parsed_allowed_bpms):
            errors.append("Manifest allowed_bpms must contain unique whole-number BPM values from 1 through 999.")
            allowed_bpms = ALLOWED_BPMS
        else:
            allowed_bpms = tuple(sorted(parsed_allowed_bpms))
    else:
        errors.append("Manifest allowed_bpms must be a non-empty list.")
        allowed_bpms = ALLOWED_BPMS

    static_directories = tuple(name for name in REQUIRED_DIRECTORIES if not name.endswith("bpm"))
    for directory_name in (*static_directories, *(f"{bpm}bpm" for bpm in allowed_bpms)):
        if not (session_dir / directory_name).exists():
            errors.append(f"Missing required directory: {directory_name}/")

    verbal_slate_required = manifest_data.get("verbal_slate_required") is True
    sync_clap_required = manifest_data.get("sync_clap_required") is True
    validate_session_dates(session_dir, manifest_data, errors=errors)
    validate_take_stop_reasons(session_dir, errors=errors, warnings=warnings)

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
    for bpm in allowed_bpms:
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
            allowed_bpms=allowed_bpms,
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
            allowed_bpms=allowed_bpms,
            verbal_slate_required=verbal_slate_required,
            sync_clap_required=sync_clap_required,
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
        allowed_bpms=allowed_bpms,
    )
    paths["validation_report"].parent.mkdir(parents=True, exist_ok=True)
    paths["validation_report"].write_text("\n".join(report_lines) + "\n", encoding="utf-8")

    for line in report_lines:
        print(line)

    return 1 if errors else 0


if __name__ == "__main__":
    raise SystemExit(main())
