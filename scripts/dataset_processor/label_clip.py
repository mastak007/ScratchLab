#!/usr/bin/env python3
from __future__ import annotations

import argparse
import sys
from pathlib import Path
from typing import Any

from process_dataset import MEDIA_SUFFIXES, normalize_scratch_type, write_json


BEAT_MODE_CHOICES = ("withBeat", "noBeat", "metronome", "unknown")
LABEL_SOURCE_CHOICES = ("manual", "manual_review", "batch_manual")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Create ScratchLab loose-clip metadata sidecars for one file or a batch directory."
    )
    parser.add_argument("media_path", nargs="?", help="Path to one supported media file.")
    parser.add_argument("--input-dir", help="Directory containing supported media files to label.")
    parser.add_argument("--recursive", action="store_true", help="Recurse into subdirectories when using --input-dir.")
    parser.add_argument("--performer", required=True, help="Performer or DJ name.")
    parser.add_argument("--scratch-type", required=True, help="Scratch label to write into the sidecar.")
    parser.add_argument("--bpm", type=int, help="Positive BPM value. Optional for noBeat or unknown.")
    parser.add_argument("--beat-mode", required=True, choices=BEAT_MODE_CHOICES, help="Beat context for the clip.")
    parser.add_argument(
        "--label-source",
        choices=LABEL_SOURCE_CHOICES,
        help="Origin of the label. Defaults to manual for one file and batch_manual for --input-dir.",
    )
    parser.add_argument("--confidence", type=float, default=1.0, help="Confidence score between 0.0 and 1.0.")
    parser.add_argument("--notes", default="", help="Optional free-text notes.")
    parser.add_argument("--start-time", type=float, default=0.0, help="Clip start time in seconds.")
    parser.add_argument("--end-time", type=float, help="Optional clip end time in seconds.")
    parser.add_argument("--force", action="store_true", help="Overwrite existing .meta.json files.")
    return parser.parse_args()


def sidecar_path_for(media_path: Path) -> Path:
    return media_path.with_name(f"{media_path.stem}.meta.json")


def supported_media_path(path: Path) -> bool:
    return path.is_file() and path.suffix.lower() in MEDIA_SUFFIXES


def default_label_source(args: argparse.Namespace) -> str:
    if args.label_source is not None:
        return args.label_source
    if args.input_dir:
        return "batch_manual"
    return "manual"


def validate_args(args: argparse.Namespace) -> tuple[dict[str, Any] | None, list[str]]:
    errors: list[str] = []

    if bool(args.media_path) == bool(args.input_dir):
        errors.append("Provide exactly one input target: a media file path or --input-dir.")

    scratch_type = normalize_scratch_type(args.scratch_type)
    if scratch_type is None:
        errors.append("scratch-type must use a supported ScratchLab scratch label.")

    if not 0.0 <= args.confidence <= 1.0:
        errors.append("confidence must be between 0.0 and 1.0.")

    if args.bpm is not None and args.bpm <= 0:
        errors.append("bpm must be a positive integer when provided.")

    if args.beat_mode in {"withBeat", "metronome"} and args.bpm is None:
        errors.append("bpm is required for beat-mode withBeat or metronome.")

    if args.start_time < 0:
        errors.append("start-time cannot be negative.")

    if args.end_time is not None and args.end_time < args.start_time:
        errors.append("end-time cannot be earlier than start-time.")

    if errors:
        return None, errors

    payload = {
        "performer": args.performer,
        "scratchType": scratch_type,
        "bpm": args.bpm if args.bpm is not None else None,
        "beatMode": args.beat_mode,
        "labelSource": default_label_source(args),
        "confidence": args.confidence,
        "notes": args.notes,
        "startTime": args.start_time,
        "endTime": args.end_time,
    }
    return payload, []


def resolve_single_media_path(raw_path: str) -> tuple[Path | None, str | None]:
    media_path = Path(raw_path).expanduser().resolve()
    if not media_path.exists():
        return None, f"Media file does not exist: {media_path}"
    if not supported_media_path(media_path):
        return None, f"Unsupported media file type: {media_path}"
    return media_path, None


def find_batch_media(input_dir: str, recursive: bool) -> tuple[list[Path], str | None]:
    root = Path(input_dir).expanduser().resolve()
    if not root.exists():
        return [], f"Input directory does not exist: {root}"
    if not root.is_dir():
        return [], f"Input path is not a directory: {root}"

    iterator = root.rglob("*") if recursive else root.iterdir()
    media_paths = sorted(path for path in iterator if supported_media_path(path))
    if not media_paths:
        return [], f"No supported media files were found in: {root}"
    return media_paths, None


def write_sidecar(media_path: Path, payload: dict[str, Any], *, force: bool) -> tuple[bool, str]:
    sidecar_path = sidecar_path_for(media_path)
    if sidecar_path.exists() and not force:
        return False, f"Sidecar already exists: {sidecar_path} (use --force to overwrite)"

    write_json(sidecar_path, payload)
    return True, f"Wrote sidecar: {sidecar_path}"


def label_single_clip(args: argparse.Namespace, payload: dict[str, Any]) -> int:
    media_path, error = resolve_single_media_path(args.media_path)
    if error is not None:
        print(error, file=sys.stderr)
        return 1

    success, message = write_sidecar(media_path, payload, force=args.force)
    destination = sys.stdout if success else sys.stderr
    print(message, file=destination)
    return 0 if success else 1


def label_batch(args: argparse.Namespace, payload: dict[str, Any]) -> int:
    media_paths, error = find_batch_media(args.input_dir, args.recursive)
    if error is not None:
        print(error, file=sys.stderr)
        return 1

    written_count = 0
    skipped_existing = 0
    for media_path in media_paths:
        success, message = write_sidecar(media_path, payload, force=args.force)
        if success:
            written_count += 1
            print(message)
            continue

        skipped_existing += 1
        print(f"Skipped existing sidecar: {sidecar_path_for(media_path)}", file=sys.stderr)

    print(
        f"Batch labeling complete. Wrote {written_count} sidecar(s); skipped {skipped_existing} existing sidecar(s)."
    )
    return 0 if written_count > 0 or skipped_existing > 0 else 1


def main() -> int:
    args = parse_args()
    payload, errors = validate_args(args)
    if errors:
        for error in errors:
            print(error, file=sys.stderr)
        return 1

    if args.input_dir:
        return label_batch(args, payload)
    if args.media_path is None:
        print("A media file path is required when --input-dir is not used.", file=sys.stderr)
        return 1
    return label_single_clip(args, payload)


if __name__ == "__main__":
    sys.exit(main())
