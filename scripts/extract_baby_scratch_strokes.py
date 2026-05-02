#!/usr/bin/env python3
"""Extract Baby Scratch stroke timing from the clean no-beat WAV.

The extractor is intentionally dependency-free so it can run on a fresh macOS
developer machine. It detects timing from audio energy/transient peaks only and
does not encode local source paths into the generated app resource.
"""

from __future__ import annotations

import argparse
import json
import math
import statistics
import struct
import wave
from pathlib import Path
from typing import Iterable


DEFAULT_INPUT = Path(
    "/Users/karlwatson/Movies/CXL DATASET/processed_makemkv/baby/79bpm/angle_1_noBeat.wav"
)
DEFAULT_OUTPUT = Path("ScratchLab/Resources/CoachDemoMotion/baby_scratch_strokes.json")
DEMO_START_SECONDS = 35.035
DEMO_END_SECONDS = 83.450033
WINDOW_SECONDS = 0.005
MERGE_GAP_SECONDS = 0.035
MIN_STROKE_SECONDS = 0.035
PRE_ROLL_SECONDS = 0.010
POST_ROLL_SECONDS = 0.018
PHRASE_SILENCE_GAP_SECONDS = 0.300
SLOW_CHIGA_STROKES = 2
FAST_CHIGA_PAIRS = 6
FAST_CHIGA_STROKES = FAST_CHIGA_PAIRS * 2
FAST_CHIGA_GAP_AFTER_SLOW_SECONDS = 0.020


def percentile(values: list[float], fraction: float) -> float:
    if not values:
        return 0.0
    ordered = sorted(values)
    index = min(len(ordered) - 1, max(0, int(round((len(ordered) - 1) * fraction))))
    return ordered[index]


def moving_average(values: list[float], radius: int) -> list[float]:
    if radius <= 0 or not values:
        return values
    smoothed: list[float] = []
    for index in range(len(values)):
        lower = max(0, index - radius)
        upper = min(len(values), index + radius + 1)
        smoothed.append(sum(values[lower:upper]) / (upper - lower))
    return smoothed


def read_mono_samples(path: Path) -> tuple[list[float], int]:
    with wave.open(str(path), "rb") as wav:
        channels = wav.getnchannels()
        sample_width = wav.getsampwidth()
        sample_rate = wav.getframerate()
        frame_count = wav.getnframes()
        raw = wav.readframes(frame_count)

    if sample_width == 2:
        fmt = "<" + ("h" * (len(raw) // 2))
        scale = 32768.0
    elif sample_width == 3:
        return read_24bit_mono(raw, channels), sample_rate
    elif sample_width == 4:
        fmt = "<" + ("i" * (len(raw) // 4))
        scale = 2147483648.0
    else:
        raise ValueError(f"Unsupported WAV sample width: {sample_width}")

    values = struct.unpack(fmt, raw)
    samples: list[float] = []
    for frame_start in range(0, len(values), channels):
        frame = values[frame_start:frame_start + channels]
        samples.append(sum(frame) / (len(frame) * scale))
    return samples, sample_rate


def read_24bit_mono(raw: bytes, channels: int) -> list[float]:
    samples: list[float] = []
    frame_width = channels * 3
    for frame_start in range(0, len(raw), frame_width):
        total = 0.0
        available = 0
        for channel in range(channels):
            offset = frame_start + (channel * 3)
            if offset + 3 > len(raw):
                continue
            value = int.from_bytes(raw[offset:offset + 3], byteorder="little", signed=False)
            if value & 0x800000:
                value -= 0x1000000
            total += value / 8388608.0
            available += 1
        if available:
            samples.append(total / available)
    return samples


def window_energy(samples: list[float], sample_rate: int) -> tuple[list[float], list[float]]:
    window_size = max(1, int(round(sample_rate * WINDOW_SECONDS)))
    energies: list[float] = []
    times: list[float] = []
    for start in range(0, len(samples), window_size):
        window = samples[start:start + window_size]
        if not window:
            break
        rms = math.sqrt(sum(sample * sample for sample in window) / len(window))
        peak = max(abs(sample) for sample in window)
        energies.append((0.72 * rms) + (0.28 * peak))
        times.append(start / sample_rate)
    max_energy = max(energies) if energies else 1.0
    if max_energy > 0:
        energies = [energy / max_energy for energy in energies]
    return times, moving_average(energies, radius=1)


def active_windows(times: list[float], energies: list[float]) -> list[tuple[float, float]]:
    if not energies:
        return []

    median = statistics.median(energies)
    high = percentile(energies, 0.92)
    threshold_on = max(0.12, median + ((high - median) * 0.38))
    threshold_off = max(0.06, threshold_on * 0.50)

    windows: list[tuple[float, float]] = []
    active_start: float | None = None
    last_active = 0.0
    for time, energy in zip(times, energies):
        if active_start is None:
            if energy >= threshold_on:
                active_start = max(0.0, time - PRE_ROLL_SECONDS)
                last_active = time + WINDOW_SECONDS
        elif energy >= threshold_off:
            last_active = time + WINDOW_SECONDS
        else:
            windows.append((active_start, last_active + POST_ROLL_SECONDS))
            active_start = None
    if active_start is not None:
        windows.append((active_start, last_active + POST_ROLL_SECONDS))

    merged: list[tuple[float, float]] = []
    for start, end in windows:
        if end - start < MIN_STROKE_SECONDS:
            continue
        if merged and start - merged[-1][1] <= MERGE_GAP_SECONDS:
            previous_start, _ = merged[-1]
            merged[-1] = (previous_start, end)
        else:
            merged.append((start, end))
    return merged


def first_phrase_windows(windows: list[tuple[float, float]]) -> list[tuple[float, float]]:
    if not windows:
        return []

    phrase = [windows[0]]
    for previous, current in zip(windows, windows[1:]):
        if current[0] - previous[1] > PHRASE_SILENCE_GAP_SECONDS:
            break
        phrase.append(current)
    return phrase


def phrase_stroke_windows(windows: list[tuple[float, float]]) -> list[tuple[float, float]]:
    if len(windows) <= SLOW_CHIGA_STROKES:
        return windows

    slow_windows = windows[:SLOW_CHIGA_STROKES]
    detected_fast_start = windows[SLOW_CHIGA_STROKES][0]
    detected_fast_end = windows[-1][1]
    if detected_fast_end <= detected_fast_start:
        return slow_windows

    fast_duration = (detected_fast_end - detected_fast_start) / FAST_CHIGA_STROKES
    fast_start = slow_windows[-1][1] + FAST_CHIGA_GAP_AFTER_SLOW_SECONDS
    fast_windows = [
        (fast_start + (index * fast_duration), fast_start + ((index + 1) * fast_duration))
        for index in range(FAST_CHIGA_STROKES)
    ]
    return slow_windows + fast_windows


def stroke_dicts(windows: Iterable[tuple[float, float]], duration: float) -> list[dict[str, float | str]]:
    strokes: list[dict[str, float | str]] = []
    window_list = list(windows)
    for index, (start, end) in enumerate(window_list):
        direction = "forward" if index % 2 == 0 else "backward"
        hold_after = 0.0
        if index + 1 < len(window_list):
            hold_after = max(0.0, window_list[index + 1][0] - end)
        start_progress = 0.0 if direction == "forward" else 1.0
        end_progress = 1.0 if direction == "forward" else 0.0
        strokes.append(
            {
                "startTime": round(max(0.0, start), 4),
                "endTime": round(min(duration, end), 4),
                "direction": direction,
                "holdAfter": round(hold_after, 4),
                "startProgress": start_progress,
                "endProgress": end_progress,
            }
        )
    return strokes


def extract(input_path: Path) -> dict[str, object]:
    samples, sample_rate = read_mono_samples(input_path)
    start_frame = int(round(DEMO_START_SECONDS * sample_rate))
    end_frame = int(round(DEMO_END_SECONDS * sample_rate))
    chapter_samples = samples[start_frame:end_frame]
    chapter_duration = len(chapter_samples) / sample_rate
    times, energies = window_energy(chapter_samples, sample_rate)
    windows = active_windows(times, energies)
    phrase_windows = first_phrase_windows(windows)
    stroke_windows = phrase_stroke_windows(phrase_windows)
    phrase_start = stroke_windows[0][0] if stroke_windows else 0.0
    phrase_end = stroke_windows[-1][1] if stroke_windows else 0.0
    strokes = stroke_dicts(stroke_windows, phrase_end)

    return {
        "version": 1,
        "scratchID": "baby",
        "timingSource": "wav_transient_extraction",
        "demoStart": DEMO_START_SECONDS,
        "demoEnd": DEMO_END_SECONDS,
        "phraseStart": round(phrase_start, 4),
        "phraseEnd": round(phrase_end, 4),
        "timelineDuration": round(phrase_end, 6),
        "strokes": strokes,
    }


def main() -> None:
    parser = argparse.ArgumentParser(description="Extract Baby Scratch stroke timing from WAV.")
    parser.add_argument("--input", type=Path, default=DEFAULT_INPUT)
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    args = parser.parse_args()

    if not args.input.exists():
        raise SystemExit(f"Input WAV not found: {args.input}")

    data = extract(args.input)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(f"Wrote {len(data['strokes'])} strokes to {args.output}")


if __name__ == "__main__":
    main()
