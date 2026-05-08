#!/usr/bin/env python3
"""Validate an offline training-clip manifest for ScratchLab.

This is for OFFLINE / PRIVATE training only. It does not touch any
app-bundled resource. See docs/training_dataset_plan.md.
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any

from process_dataset import normalize_scratch_type


ALLOWED_SPLITS = ("train", "validation", "test")
ALLOWED_BEAT_MODES = ("withBeat", "noBeat", "metronome", "unknown")

REQUIRED_CLIP_FIELDS = (
    "clip_id",
    "scratch_type",
    "beat_mode",
    "performer",
    "capture_device",
    "has_video",
    "has_audio",
    "has_motion",
    "label_confidence",
    "split",
)

# Provenance / source / rights fields the training manifest must never carry.
# These are checked both as field names AND as substrings inside string values.
BANNED_PROVENANCE_KEYS = frozenset(
    {
        "source_dvd",
        "source_app",
        "source_mkv",
        "sourcemkv",
        "source_path",
        "source_root",
        "rights_status",
        "rightsstatus",
        "review_status",
        "reviewstatus",
        "provenance",
        "absolute_path",
        "path",
    }
)

BANNED_TOKENS = (
    "/Users/",
    "MakeMKV",
    "makemkv",
    "processed_makemkv",
    "QBERT",
    "SXRATCH",
    "rightsStatus",
    "reviewStatus",
    "sourceMKV",
    "sourceDVD",
)


class ManifestValidationError(Exception):
    pass


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Validate an offline training-clip manifest against the "
            "ScratchLab canonical scratch-type list, split rules, and the "
            "banned-provenance blocklist. Exits 0 on success, 1 on failure."
        )
    )
    parser.add_argument(
        "--manifest",
        required=True,
        help="Path to a JSON manifest matching templates/training_clip_manifest_template.json",
    )
    parser.add_argument(
        "--require-min-per-class",
        type=int,
        default=0,
        help=(
            "If > 0, fail when any scratch_type has fewer clips than this "
            "across all splits. Useful before kicking off training."
        ),
    )
    return parser.parse_args()


def _scan_for_banned_tokens(payload: Any, path: str, errors: list[str]) -> None:
    if isinstance(payload, dict):
        for key, value in payload.items():
            normalized_key = str(key).strip().lower().replace("-", "_")
            if normalized_key in BANNED_PROVENANCE_KEYS:
                errors.append(
                    f"{path}: banned provenance field {key!r} is not allowed in training manifests."
                )
            _scan_for_banned_tokens(value, f"{path}.{key}", errors)
    elif isinstance(payload, list):
        for index, value in enumerate(payload):
            _scan_for_banned_tokens(value, f"{path}[{index}]", errors)
    elif isinstance(payload, str):
        for token in BANNED_TOKENS:
            if token in payload:
                errors.append(
                    f"{path}: value contains banned token {token!r}. "
                    "Training manifests must not carry source / vendor / rights metadata."
                )


def _validate_clip_entry(index: int, clip: Any, errors: list[str]) -> str | None:
    label_path = f"clips[{index}]"
    if not isinstance(clip, dict):
        errors.append(f"{label_path}: must be an object.")
        return None

    for field in REQUIRED_CLIP_FIELDS:
        if field not in clip:
            errors.append(f"{label_path}: missing required field {field!r}.")

    clip_id = clip.get("clip_id")
    if isinstance(clip_id, str):
        if not clip_id.strip():
            errors.append(f"{label_path}: clip_id must not be empty.")
        elif "/" in clip_id or "\\" in clip_id:
            errors.append(
                f"{label_path}: clip_id must be a stable identifier, not a path."
            )

    raw_scratch_type = clip.get("scratch_type")
    canonical_scratch_type = normalize_scratch_type(raw_scratch_type)
    if canonical_scratch_type is None:
        errors.append(
            f"{label_path}: scratch_type {raw_scratch_type!r} is not in the canonical ScratchLab list."
        )

    split = clip.get("split")
    if split not in ALLOWED_SPLITS:
        errors.append(
            f"{label_path}: split must be one of {ALLOWED_SPLITS}, got {split!r}."
        )

    beat_mode = clip.get("beat_mode")
    if beat_mode not in ALLOWED_BEAT_MODES:
        errors.append(
            f"{label_path}: beat_mode must be one of {ALLOWED_BEAT_MODES}, got {beat_mode!r}."
        )

    bpm = clip.get("bpm")
    if beat_mode in {"withBeat", "metronome"}:
        if not isinstance(bpm, int) or bpm <= 0:
            errors.append(
                f"{label_path}: bpm must be a positive integer when beat_mode is {beat_mode!r}."
            )
    elif bpm is not None and not (isinstance(bpm, int) and bpm > 0):
        errors.append(f"{label_path}: bpm must be null or a positive integer.")

    confidence = clip.get("label_confidence")
    if not isinstance(confidence, (int, float)) or not 0.0 <= float(confidence) <= 1.0:
        errors.append(
            f"{label_path}: label_confidence must be a number in [0.0, 1.0]."
        )

    for boolean_field in ("has_video", "has_audio", "has_motion"):
        if not isinstance(clip.get(boolean_field), bool):
            errors.append(f"{label_path}: {boolean_field} must be a boolean.")

    duration = clip.get("duration_seconds")
    if duration is not None and not (
        isinstance(duration, (int, float)) and float(duration) > 0
    ):
        errors.append(f"{label_path}: duration_seconds must be > 0 when provided.")

    performer = clip.get("performer")
    if isinstance(performer, str) and not performer.strip():
        errors.append(f"{label_path}: performer must not be empty.")

    return canonical_scratch_type


def validate_manifest(payload: Any, *, require_min_per_class: int = 0) -> list[str]:
    errors: list[str] = []

    if not isinstance(payload, dict):
        return ["manifest: top-level value must be a JSON object."]

    clips = payload.get("clips")
    if not isinstance(clips, list) or not clips:
        errors.append("manifest: clips must be a non-empty array.")
        return errors

    _scan_for_banned_tokens(payload, "manifest", errors)

    per_class_counts: dict[str, int] = {}
    seen_clip_ids: set[str] = set()

    for index, clip in enumerate(clips):
        canonical_scratch_type = _validate_clip_entry(index, clip, errors)

        if isinstance(clip, dict):
            clip_id = clip.get("clip_id")
            if isinstance(clip_id, str):
                if clip_id in seen_clip_ids:
                    errors.append(
                        f"clips[{index}]: duplicate clip_id {clip_id!r}."
                    )
                else:
                    seen_clip_ids.add(clip_id)

        if canonical_scratch_type is not None:
            per_class_counts[canonical_scratch_type] = (
                per_class_counts.get(canonical_scratch_type, 0) + 1
            )

    if require_min_per_class > 0:
        for scratch_type, count in sorted(per_class_counts.items()):
            if count < require_min_per_class:
                errors.append(
                    f"manifest: scratch_type {scratch_type!r} has only {count} clip(s); "
                    f"minimum required is {require_min_per_class}."
                )

    return errors


def main() -> int:
    args = parse_args()
    manifest_path = Path(args.manifest).expanduser().resolve()
    if not manifest_path.exists():
        print(f"Manifest does not exist: {manifest_path}", file=sys.stderr)
        return 1
    if not manifest_path.is_file():
        print(f"Manifest path is not a file: {manifest_path}", file=sys.stderr)
        return 1

    try:
        payload = json.loads(manifest_path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as error:
        print(f"Manifest is not valid JSON: {error}", file=sys.stderr)
        return 1

    errors = validate_manifest(
        payload, require_min_per_class=args.require_min_per_class
    )
    if errors:
        for line in errors:
            print(line, file=sys.stderr)
        print(
            f"Validation FAILED with {len(errors)} error(s) in {manifest_path}.",
            file=sys.stderr,
        )
        return 1

    clip_count = len(payload.get("clips", []))
    print(f"Validation OK. {clip_count} clip(s) accepted from {manifest_path}.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
