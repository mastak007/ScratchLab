#!/usr/bin/env python3
"""Extract ScratchLab notation from Baby Scratch no-beat audio."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Iterable

from extract_baby_scratch_strokes import (
    DEFAULT_INPUT,
    DEMO_END_SECONDS,
    DEMO_START_SECONDS,
    extract as extract_strokes,
    percentile,
)


DEFAULT_OUTPUT = Path("ScratchLab/Resources/Notation/baby_scratch.json")


def speed_classification(duration: float, fast_cutoff: float, slow_cutoff: float) -> str:
    if duration <= fast_cutoff:
        return "fast"
    if duration >= slow_cutoff:
        return "slow"
    return "medium"


def detect_transient_peaks(input_path: Path) -> list[dict[str, object]]:
    payload = extract_strokes(input_path)
    return list(payload["strokes"])


def notation_strokes(strokes: Iterable[dict[str, object]]) -> list[dict[str, object]]:
    stroke_list = list(strokes)
    durations = [
        float(stroke["endTime"]) - float(stroke["startTime"])
        for stroke in stroke_list
    ]
    median_duration = percentile(durations, 0.50)
    fast_cutoff = median_duration * 1.02
    slow_cutoff = median_duration * 1.05

    notation: list[dict[str, object]] = []
    for index, stroke in enumerate(stroke_list):
        start_time = float(stroke["startTime"])
        end_time = float(stroke["endTime"])
        duration = max(0.0, end_time - start_time)
        direction = "forward" if index % 2 == 0 else "backward"
        notation.append(
            {
                "startTime": round(start_time, 4),
                "endTime": round(end_time, 4),
                "direction": direction,
                "speedClassification": speed_classification(duration, fast_cutoff, slow_cutoff),
                "faderState": "open",
            }
        )
    return notation


def extract_notation(input_path: Path) -> dict[str, object]:
    payload = extract_strokes(input_path)
    strokes = list(payload["strokes"])
    return {
        "version": 1,
        "scratchID": "baby",
        "demoStart": DEMO_START_SECONDS,
        "demoEnd": DEMO_END_SECONDS,
        "phraseStart": payload["phraseStart"],
        "phraseEnd": payload["phraseEnd"],
        "timingBasis": "audio_transient_peaks",
        "strokes": notation_strokes(strokes),
    }


def main() -> None:
    parser = argparse.ArgumentParser(description="Extract ScratchLab notation from WAV.")
    parser.add_argument("--input", type=Path, default=DEFAULT_INPUT)
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    args = parser.parse_args()

    if not args.input.exists():
        raise SystemExit(f"Input WAV not found: {args.input}")

    data = extract_notation(args.input)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(f"Wrote {len(data['strokes'])} notation strokes to {args.output}")


if __name__ == "__main__":
    main()
