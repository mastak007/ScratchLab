#!/usr/bin/env python3
"""Generate ScratchLab's local-only 1 kHz quadrature decoder test WAV."""

from __future__ import annotations

import argparse
import math
import wave
from pathlib import Path


SAMPLE_RATE = 44_100
DURATION_SECONDS = 60
FREQUENCY_HZ = 1_000.0
AMPLITUDE = 0.42
OUTPUT_FILENAME = "scratchlab_quadrature_1khz_60s.wav"


def default_output_path() -> Path:
    repo_root = Path(__file__).resolve().parents[1]
    return repo_root / "debug_captures" / "timecode" / OUTPUT_FILENAME


def generate_quadrature_wav(output_path: Path) -> None:
    output_path.parent.mkdir(parents=True, exist_ok=True)

    frame_count = SAMPLE_RATE * DURATION_SECONDS
    max_int16 = 32767

    with wave.open(str(output_path), "wb") as wav_file:
        wav_file.setnchannels(2)
        wav_file.setsampwidth(2)
        wav_file.setframerate(SAMPLE_RATE)

        frames = bytearray()
        for sample_index in range(frame_count):
            phase = 2.0 * math.pi * FREQUENCY_HZ * sample_index / SAMPLE_RATE
            left = int(round(AMPLITUDE * max_int16 * math.sin(phase)))
            right = int(round(AMPLITUDE * max_int16 * math.sin(phase + math.pi / 2.0)))
            frames.extend(left.to_bytes(2, byteorder="little", signed=True))
            frames.extend(right.to_bytes(2, byteorder="little", signed=True))

        wav_file.writeframes(frames)


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Generate a local-only ScratchLab pure quadrature control WAV."
    )
    parser.add_argument(
        "--output",
        type=Path,
        default=default_output_path(),
        help=f"Output WAV path. Default: {default_output_path()}",
    )
    args = parser.parse_args()

    output_path = args.output.expanduser().resolve()
    generate_quadrature_wav(output_path)

    print(f"Wrote: {output_path}")
    print(f"sample rate: {SAMPLE_RATE} Hz")
    print(f"duration: {DURATION_SECONDS} seconds")
    print(f"frequency: {FREQUENCY_HZ:g} Hz")
    print(f"amplitude: {AMPLITUDE:.2f} peak")
    print("phase relationship: left = sine, right = sine +90 degrees")
    print("modulation: none; continuous carrier; no silence gaps; no fade")
    print("intended validation route:")
    print(f"  {OUTPUT_FILENAME}")
    print("  -> Loopback virtual input")
    print("  -> ScratchLab Timecode Prototype")


if __name__ == "__main__":
    main()
