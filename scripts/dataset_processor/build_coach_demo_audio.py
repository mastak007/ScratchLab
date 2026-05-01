#!/usr/bin/env python3

"""Build ScratchLab Coach demo audio clips from development-only source media."""

from __future__ import annotations

import argparse
import json
import shutil
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True)
class CoachDemoSource:
    scratch_type: str
    output_file: str
    source_media: str
    audio_stream_index: int
    demo_start: float
    demo_end: float


DEMO_SOURCES = [
    CoachDemoSource(
        scratch_type="baby",
        output_file="baby_noBeat.wav",
        source_media="Baby_79bpm/title_t00.mov",
        audio_stream_index=2,
        demo_start=0.0,
        demo_end=12.0,
    ),
    CoachDemoSource(
        scratch_type="chirpflare",
        output_file="chirpflare_noBeat.wav",
        source_media="ChirpFlare_92bpm/title_t52.mov",
        audio_stream_index=2,
        demo_start=0.0,
        demo_end=11.0,
    ),
]


def parse_args() -> argparse.Namespace:
    repo_root = Path(__file__).resolve().parents[2]
    default_output_root = repo_root / "ScratchLab" / "Resources" / "CoachDemoAudio"
    default_manifest_path = Path(__file__).resolve().with_name("coach_demo_manifest.dev.json")

    parser = argparse.ArgumentParser(
        description=(
            "Trim development-only no-beat performance audio into bundled "
            "ScratchLab Coach demo WAVs without modifying source media."
        )
    )
    parser.add_argument(
        "--source-root",
        required=True,
        help="Root folder containing source media for local demo generation.",
    )
    parser.add_argument(
        "--output-root",
        default=str(default_output_root),
        help="Destination folder for bundled coach demo WAVs.",
    )
    parser.add_argument(
        "--manifest-output",
        default=str(default_manifest_path),
        help="Development-only manifest path. This must stay outside app resources.",
    )
    parser.add_argument(
        "--offset",
        type=float,
        default=2.0,
        help="Extra seconds to add after Chapter 2 start before extracting audio.",
    )
    parser.add_argument(
        "--force",
        action="store_true",
        help="Overwrite existing generated outputs.",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Print planned actions without writing any files.",
    )
    return parser.parse_args()


def require_tool(tool_name: str) -> None:
    if shutil.which(tool_name):
        return
    raise SystemExit(f"Missing required tool on PATH: {tool_name}")


def run_command(command: list[str]) -> str:
    completed = subprocess.run(
        command,
        check=False,
        capture_output=True,
        text=True,
    )
    if completed.returncode != 0:
        stderr = completed.stderr.strip()
        stdout = completed.stdout.strip()
        detail = stderr or stdout or "command failed"
        raise RuntimeError(f"{' '.join(command)}\n{detail}")
    return completed.stdout


def chapter_two_start(source_file: Path) -> float:
    output = run_command(
        [
            "ffprobe",
            "-v",
            "error",
            "-show_chapters",
            "-of",
            "json",
            str(source_file),
        ]
    )
    payload = json.loads(output)
    chapters = payload.get("chapters", [])
    if len(chapters) < 2:
        raise RuntimeError(f"Expected at least 2 chapters in {source_file}")
    start_time = chapters[1].get("start_time")
    if start_time in (None, ""):
        raise RuntimeError(f"Chapter 2 start time missing in {source_file}")
    return float(start_time)


def extract_trimmed_wav(
    *,
    source_file: Path,
    output_file: Path,
    audio_stream_index: int,
    performance_start: float,
) -> None:
    run_command(
        [
            "ffmpeg",
            "-hide_banner",
            "-loglevel",
            "error",
            "-y",
            "-ss",
            f"{performance_start:.6f}",
            "-i",
            str(source_file),
            "-map",
            f"0:{audio_stream_index}",
            "-vn",
            "-acodec",
            "pcm_s16le",
            "-ar",
            "48000",
            str(output_file),
        ]
    )


def main() -> int:
    args = parse_args()
    require_tool("ffprobe")
    require_tool("ffmpeg")

    source_root = Path(args.source_root).expanduser().resolve()
    output_root = Path(args.output_root).expanduser().resolve()
    manifest_path = Path(args.manifest_output).expanduser().resolve()

    if not source_root.exists():
        raise SystemExit(f"Source root does not exist: {source_root}")
    if args.offset < 0:
        raise SystemExit("--offset must be zero or greater.")

    manifest_items: list[dict[str, object]] = []

    if not args.dry_run:
        output_root.mkdir(parents=True, exist_ok=True)

    for source in DEMO_SOURCES:
        source_file = source_root / source.source_media
        output_file = output_root / source.output_file

        if not source_file.exists():
            raise SystemExit(f"Missing source media: {source_file}")

        chapter_start = chapter_two_start(source_file)
        performance_start = chapter_start + args.offset

        manifest_items.append(
            {
                "name": source.scratch_type,
                "file": source.output_file,
                "demoStart": source.demo_start,
                "demoEnd": source.demo_end,
            }
        )

        if output_file.exists() and not args.force:
            print(f"skip {output_file} (exists, pass --force to overwrite)")
            continue

        print(
            f"{'plan' if args.dry_run else 'write'} "
            f"{output_file.name} from {source.source_media} stream {source.audio_stream_index} "
            f"starting at {performance_start:.3f}s"
        )

        if args.dry_run:
            continue

        extract_trimmed_wav(
            source_file=source_file,
            output_file=output_file,
            audio_stream_index=source.audio_stream_index,
            performance_start=performance_start,
        )

    manifest = {
        "clips": manifest_items,
    }

    if args.dry_run:
        print(json.dumps(manifest, indent=2))
        return 0

    manifest_path.parent.mkdir(parents=True, exist_ok=True)
    manifest_path.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    print(f"wrote {manifest_path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
