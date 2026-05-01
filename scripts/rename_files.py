#!/usr/bin/env python3
from __future__ import annotations

import argparse
import shutil
import sys
from pathlib import Path

from capture_pipeline_common import (
    ALLOWED_BPMS,
    DESTINATION_FOLDERS,
    REQUIRED_DIRECTORIES,
    SOURCE_COLUMNS,
    build_standard_filename,
    build_take_record,
    default_manifest,
    normalize_extension,
    parse_bool,
    parse_bpm,
    parse_take_number,
    read_json,
    read_take_log,
    relative_to_session,
    resolve_raw_path,
    sanitize_dj_token,
    session_file_paths,
    take_sort_key,
    validate_date_string,
    write_bpm_summary,
    write_json,
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Copy raw Scratch Capture files into the standard renamed layout."
    )
    parser.add_argument("session_dir", help="Path to the baby_scratch session directory")
    parser.add_argument(
        "--take-log",
        help="Optional override for the take log CSV path",
    )
    parser.add_argument(
        "--manifest",
        help="Optional override for the session manifest JSON path",
    )
    return parser.parse_args()


def resolve_path(path_text: str) -> Path:
    return Path(path_text).expanduser().resolve()


def rollback_copied_targets(session_dir: Path, copied_targets: list[Path]) -> tuple[list[str], list[str]]:
    rolled_back: list[str] = []
    rollback_errors: list[str] = []

    for target_path in reversed(copied_targets):
        try:
            target_path.unlink()
            rolled_back.append(relative_to_session(session_dir, target_path))
        except FileNotFoundError:
            continue
        except OSError as exc:
            rollback_errors.append(
                f"Could not remove copied file after rename failure: {relative_to_session(session_dir, target_path)} ({exc})"
            )

    return rolled_back, rollback_errors


def main() -> int:
    args = parse_args()
    session_dir = resolve_path(args.session_dir)

    for directory_name in REQUIRED_DIRECTORIES:
        if not (session_dir / directory_name).exists():
            print(
                f"Error: session directory is missing {directory_name}/ inside {session_dir}",
                file=sys.stderr,
            )
            return 1

    paths = session_file_paths(session_dir)
    take_log_path = resolve_path(args.take_log) if args.take_log else paths["take_log"]
    manifest_path = resolve_path(args.manifest) if args.manifest else paths["manifest"]

    if not take_log_path.exists():
        print(f"Error: missing take log: {take_log_path}", file=sys.stderr)
        return 1

    try:
        take_rows = read_take_log(take_log_path)
    except ValueError as exc:
        print(f"Error: {exc}", file=sys.stderr)
        return 1

    if not take_rows:
        print("No take rows found in the take log. Nothing to rename.")
        return 0

    manifest_data = default_manifest()
    if manifest_path.exists():
        try:
            existing_manifest = read_json(manifest_path)
            if isinstance(existing_manifest, dict):
                manifest_data.update({key: value for key, value in existing_manifest.items() if key != "takes"})
        except Exception as exc:  # pragma: no cover - defensive path
            print(f"Error: could not read manifest: {exc}", file=sys.stderr)
            return 1

    try:
        inferred_date = validate_date_string(str(manifest_data.get("date") or session_dir.parent.name))
    except ValueError:
        inferred_date = session_dir.parent.name

    inferred_dj_token = str(manifest_data.get("dj_token") or session_dir.parent.parent.name)
    try:
        inferred_dj_token = sanitize_dj_token(inferred_dj_token)
    except ValueError:
        print("Error: could not determine DJ token from the manifest or session path.", file=sys.stderr)
        return 1

    dj_name = str(manifest_data.get("dj_name") or inferred_dj_token)
    dj_token = inferred_dj_token
    date_string = inferred_date

    manifest_data["dj_name"] = dj_name
    manifest_data["dj_token"] = dj_token
    manifest_data["date"] = date_string
    manifest_data["session_root"] = str(session_dir)
    manifest_data["allowed_bpms"] = list(ALLOWED_BPMS)

    copied: list[str] = []
    copied_targets: list[Path] = []
    warnings: list[str] = []
    errors: list[str] = []
    take_records: list[dict[str, object]] = []
    seen_take_keys: set[tuple[int, int]] = set()

    for line_number, row in enumerate(take_rows, start=2):
        label = f"line {line_number}"

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
            errors.append(f"{label}: duplicate entry for {bpm} BPM take {take_number:02d}")
            continue
        seen_take_keys.add(take_key)

        requested_sources: list[tuple[str, str, Path, Path]] = []
        row_has_path_errors = False
        for source, column in SOURCE_COLUMNS.items():
            raw_value = row[column]
            if not raw_value:
                continue

            try:
                source_path = resolve_raw_path(session_dir, raw_value)
            except ValueError as exc:
                errors.append(f"{label}: {exc}")
                row_has_path_errors = True
                continue
            target_name = build_standard_filename(dj_token, bpm, take_number, source)
            target_path = session_dir / DESTINATION_FOLDERS[source] / target_name
            requested_sources.append((source, raw_value, source_path, target_path))

        if row_has_path_errors:
            continue

        existing_targets = [
            (source, target_path)
            for source, _, _, target_path in requested_sources
            if target_path.exists()
        ]
        if existing_targets:
            for source, target_path in existing_targets:
                errors.append(
                    f"{label}: renamed target already exists for {source}: {relative_to_session(session_dir, target_path)}"
                )
            continue

        requested_source_names = {source for source, _, _, _ in requested_sources}
        if "camA" not in requested_source_names:
            errors.append(f"{label}: Each take needs a primary camA video file.")
            continue
        if "serato" not in requested_source_names:
            errors.append(f"{label}: Each take needs a serato audio file.")
            continue

        files_by_source: dict[str, Path] = {}
        row_has_errors = False

        for source, raw_value, source_path, target_path in requested_sources:
            if not source_path.exists():
                errors.append(f"{label}: missing source file {source_path}")
                row_has_errors = True
                continue

            try:
                normalize_extension(source, source_path)
            except ValueError as exc:
                errors.append(f"{label}: {exc}")
                row_has_errors = True
                continue

            target_path.parent.mkdir(parents=True, exist_ok=True)
            try:
                shutil.copy2(source_path, target_path)
            except OSError as exc:
                try:
                    target_path.unlink()
                except FileNotFoundError:
                    pass
                except OSError:
                    pass
                errors.append(f"{label}: could not copy {source_path} to {target_path}: {exc}")
                row_has_errors = True
                continue

            files_by_source[source] = target_path
            copied_targets.append(target_path)
            copied.append(
                f"{relative_to_session(session_dir, source_path)} -> {relative_to_session(session_dir, target_path)}"
            )

        if row_has_errors:
            continue

        try:
            take_record = build_take_record(
                session_dir,
                dj_name=dj_name,
                date_string=date_string,
                bpm=bpm,
                take_number=take_number,
                verbal_slate_used=verbal_slate_used,
                sync_clap_used=sync_clap_used,
                notes=row["notes"],
                files_by_source=files_by_source,
            )
        except ValueError as exc:
            errors.append(f"{label}: {exc}")
            continue

        take_records.append(take_record)

    rolled_back: list[str] = []
    if errors:
        rolled_back, rollback_errors = rollback_copied_targets(session_dir, copied_targets)
        errors.extend(rollback_errors)

    print(f"Processed session: {session_dir}")
    if copied:
        print("Copied files:")
        for item in copied:
            print(f"- {item}")

    if warnings:
        print("Warnings:")
        for item in warnings:
            print(f"- {item}")

    if errors:
        print("Errors:")
        for item in errors:
            print(f"- {item}")
        if rolled_back:
            print("Rolled back copied files from this run:")
            for item in rolled_back:
                print(f"- {item}")
        print(f"Left manifest unchanged: {manifest_path}")
        return 1

    take_records.sort(key=take_sort_key)
    manifest_data["takes"] = take_records
    write_json(manifest_path, manifest_data)

    for take_record in take_records:
        write_bpm_summary(session_dir, take_record)

    print(f"Updated manifest with {len(take_records)} take record(s): {manifest_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
