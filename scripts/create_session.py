#!/usr/bin/env python3
from __future__ import annotations

import argparse
import shutil
import sys
from pathlib import Path

from capture_pipeline_common import (
    MANIFEST_TEMPLATE_FILENAME,
    REQUIRED_DIRECTORIES,
    resolve_raw_path,
    SESSION_NAME,
    SOURCE_COLUMNS,
    TAKE_LOG_TEMPLATE_FILENAME,
    default_manifest,
    normalize_extension,
    parse_bool,
    parse_bpm,
    parse_take_number,
    read_json,
    read_take_log,
    sanitize_dj_token,
    session_file_paths,
    templates_dir,
    validate_date_string,
    write_json,
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Create a Scratch Capture Pipeline session folder for one DJ and date."
    )
    parser.add_argument("dj_name", help='DJ name, for example "DJ Prime Cuts"')
    parser.add_argument("date", help="Session date in YYYY-MM-DD format")
    parser.add_argument(
        "--sessions-root",
        default="sessions",
        help="Base folder for session storage (default: ./sessions)",
    )
    return parser.parse_args()


def resolve_path(path_text: str) -> Path:
    path = Path(path_text).expanduser()
    if path.is_absolute():
        return path
    return (Path.cwd() / path).resolve()


def validate_existing_manifest(
    manifest_path: Path,
    *,
    dj_name: str,
    dj_token: str,
    date_string: str,
    session_dir: Path,
) -> dict[str, object]:
    try:
        payload = read_json(manifest_path)
    except Exception as exc:  # pragma: no cover - defensive path
        raise ValueError(f"could not read existing manifest: {exc}") from exc

    if not isinstance(payload, dict):
        raise ValueError("existing manifest must contain a JSON object.")

    expected_fields = {
        "dj_name": dj_name,
        "dj_token": dj_token,
        "date": date_string,
        "session_root": str(session_dir),
    }
    mismatches: list[str] = []
    for field_name, expected_value in expected_fields.items():
        actual_value = payload.get(field_name)
        if actual_value != expected_value:
            mismatches.append(f"{field_name} is {actual_value!r}, expected {expected_value!r}")

    if mismatches:
        joined = "; ".join(mismatches)
        raise ValueError(f"existing manifest does not match the requested session: {joined}")

    return payload


def validate_existing_take_log(take_log_path: Path, *, template_path: Path, session_dir: Path) -> None:
    try:
        take_rows = read_take_log(take_log_path)
    except ValueError as exc:
        raise ValueError(f"existing take log is invalid: {exc}") from exc

    if not take_rows:
        if take_log_path.read_bytes() != template_path.read_bytes():
            raise ValueError(
                "existing take log is invalid: contains no non-empty take rows and does not match the empty template."
            )
        return

    seen_take_keys: set[tuple[int, int]] = set()
    for row_index, row in enumerate(take_rows, start=1):
        try:
            bpm = parse_bpm(row["bpm"])
            take_number = parse_take_number(row["take_number"])
            parse_bool(row["verbal_slate_used"], field_name="verbal_slate_used")
            parse_bool(row["sync_clap_used"], field_name="sync_clap_used")
            for source, column_name in SOURCE_COLUMNS.items():
                raw_value = row[column_name]
                if raw_value:
                    normalize_extension(source, Path(raw_value))
                    resolve_raw_path(session_dir, raw_value)
        except ValueError as exc:
            raise ValueError(f"existing take log is invalid: take row {row_index}: {exc}") from exc

        take_key = (bpm, take_number)
        if take_key in seen_take_keys:
            raise ValueError(
                f"existing take log is invalid: take row {row_index}: duplicate entry for {bpm} BPM take {take_number:02d}."
            )
        seen_take_keys.add(take_key)


def main() -> int:
    args = parse_args()

    try:
        date_string = validate_date_string(args.date)
        dj_token = sanitize_dj_token(args.dj_name)
    except ValueError as exc:
        print(f"Error: {exc}", file=sys.stderr)
        return 1

    sessions_root = resolve_path(args.sessions_root)
    session_dir = sessions_root / dj_token / date_string / SESSION_NAME
    template_dir = templates_dir()
    manifest_template_path = template_dir / MANIFEST_TEMPLATE_FILENAME
    take_log_template_path = template_dir / TAKE_LOG_TEMPLATE_FILENAME

    if not manifest_template_path.exists():
        print(f"Error: missing manifest template: {manifest_template_path}", file=sys.stderr)
        return 1
    if not take_log_template_path.exists():
        print(f"Error: missing take log template: {take_log_template_path}", file=sys.stderr)
        return 1

    for directory_name in REQUIRED_DIRECTORIES:
        (session_dir / directory_name).mkdir(parents=True, exist_ok=True)

    paths = session_file_paths(session_dir)
    created_items: list[str] = []
    kept_items: list[str] = []
    manifest_exists = paths["manifest"].exists()
    take_log_exists = paths["take_log"].exists()

    existing_manifest: dict[str, object] | None = None
    if manifest_exists:
        try:
            existing_manifest = validate_existing_manifest(
                paths["manifest"],
                dj_name=args.dj_name,
                dj_token=dj_token,
                date_string=date_string,
                session_dir=session_dir,
            )
        except ValueError as exc:
            print(f"Error: {exc}", file=sys.stderr)
            return 1
        kept_items.append(str(paths["manifest"]))
    else:
        template_data = read_json(manifest_template_path)
        if not isinstance(template_data, dict):
            print("Error: manifest template must contain a JSON object.", file=sys.stderr)
            return 1
        manifest_data = default_manifest(
            dj_name=args.dj_name,
            dj_token=dj_token,
            date_string=date_string,
            session_dir=session_dir,
        )
        for key, value in template_data.items():
            if key == "takes":
                continue
            manifest_data[key] = value
        manifest_data["dj_name"] = args.dj_name
        manifest_data["dj_token"] = dj_token
        manifest_data["date"] = date_string
        manifest_data["session_root"] = str(session_dir)
        manifest_data["takes"] = []
        write_json(paths["manifest"], manifest_data)
        created_items.append(str(paths["manifest"]))

    if take_log_exists:
        if existing_manifest is None:
            print(
                "Error: cannot keep an existing take log without an existing manifest that matches the requested session.",
                file=sys.stderr,
            )
            return 1
        try:
            validate_existing_take_log(
                paths["take_log"],
                template_path=take_log_template_path,
                session_dir=session_dir,
            )
        except ValueError as exc:
            print(f"Error: {exc}", file=sys.stderr)
            return 1
        kept_items.append(str(paths["take_log"]))
    else:
        shutil.copyfile(take_log_template_path, paths["take_log"])
        created_items.append(str(paths["take_log"]))

    print("Scratch capture session ready.")
    print(f"Session path: {session_dir}")
    print(f"DJ token: {dj_token}")
    print("Prepared folders:")
    for directory_name in REQUIRED_DIRECTORIES:
        print(f"- {session_dir / directory_name}")

    if created_items:
        print("Created manifest files:")
        for item in created_items:
            print(f"- {item}")

    if kept_items:
        print("Kept existing files:")
        for item in kept_items:
            print(f"- {item}")

    print("Next steps:")
    print("- Copy the original files into raw/")
    print("- Add one row per take to manifests/take_log.csv")
    print(f"- Run: python3 scripts/rename_files.py {session_dir}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
