#!/usr/bin/env python3
"""Generate six original, sparse 92 BPM scratch-break variations.

Each WAV contains a one-bar count-in followed by a clean 16-bar loop.
The adjacent JSON file is the step-sequencer source of truth.
"""

from __future__ import annotations

import json
import math
from pathlib import Path

import numpy as np
import soundfile as sf


SR = 44_100
BPM = 92
BEAT = 60.0 / BPM
STEP = BEAT / 4.0
COUNT_IN_BARS = 1
LOOP_BARS = 16
SWING = 0.60
OUT = Path(__file__).resolve().parent.parent / "generated_scratch_breaks"


def add_voice(dst: np.ndarray, start: float, voice: np.ndarray, gain: float) -> None:
    i = int(round(start * SR))
    if i >= len(dst):
        return
    end = min(len(dst), i + len(voice))
    dst[i:end] += voice[: end - i] * gain


def kick(length: float = 0.30) -> np.ndarray:
    n = int(length * SR)
    t = np.arange(n) / SR
    freq = 47.0 + 105.0 * np.exp(-t * 26.0)
    phase = 2 * np.pi * np.cumsum(freq) / SR
    body = np.sin(phase) * np.exp(-t * 10.0)
    click = np.random.default_rng(4).normal(0, 1, n) * np.exp(-t * 105.0)
    return body * 0.95 + click * 0.035


def snare(length: float = 0.20) -> np.ndarray:
    n = int(length * SR)
    t = np.arange(n) / SR
    rng = np.random.default_rng(8)
    noise = rng.normal(0, 1, n)
    # A low-mid body and a very short upper crack keep the scratch band open.
    body = np.sin(2 * np.pi * 190.0 * t) * np.exp(-t * 23.0)
    crack = noise * np.exp(-t * 75.0)
    return body * 0.30 + crack * 0.22


def rim(length: float = 0.055) -> np.ndarray:
    n = int(length * SR)
    t = np.arange(n) / SR
    return (np.sin(2 * np.pi * 1150.0 * t) * 0.16
            + np.sin(2 * np.pi * 1780.0 * t) * 0.08) * np.exp(-t * 95.0)


def hat(length: float = 0.055, open_hat: bool = False) -> np.ndarray:
    n = int(length * SR)
    t = np.arange(n) / SR
    rng = np.random.default_rng(17 if open_hat else 19)
    noise = rng.normal(0, 1, n)
    # High-passed noise leaves most of 1-5 kHz available for scratch cuts.
    hp = noise - np.convolve(noise, np.ones(30) / 30, mode="same")
    return hp * (0.12 if not open_hat else 0.16) * np.exp(-t * (28 if open_hat else 95))


def bass(length: float = 0.22, root: float = 43.65) -> np.ndarray:
    n = int(length * SR)
    t = np.arange(n) / SR
    env = np.minimum(1.0, t * 100.0) * np.exp(-t * 13.0)
    return (np.sin(2 * np.pi * root * t) + 0.18 * np.sin(2 * np.pi * root * 2 * t)) * env * 0.28


def noise_tick(length: float = 0.025) -> np.ndarray:
    n = int(length * SR)
    t = np.arange(n) / SR
    return np.random.default_rng(31).normal(0, 0.035, n) * np.exp(-t * 125.0)


def swung_time(bar: int, step: int) -> float:
    base = (COUNT_IN_BARS * 4 + bar * 4) * BEAT + step * STEP
    if step % 2 == 1:
        base += STEP * (SWING - 0.5) * 2.0
    return base


def matrix_for(variation: int) -> dict:
    kick_patterns = [
        [0, 4, 7, 8, 10, 12], [0, 4, 6, 8, 11, 12], [0, 3, 4, 8, 10, 12],
        [0, 4, 7, 8, 9, 12], [0, 2, 4, 8, 10, 12], [0, 4, 5, 8, 11, 12],
    ]
    ghost_patterns = [
        [3, 14], [2, 7, 15], [3, 6, 14], [2, 6, 15], [3, 7, 14], [2, 5, 15],
    ]
    fills = [
        [13, 14, 15], [11, 13, 14, 15], [12, 13, 14, 15],
        [10, 12, 14, 15], [11, 12, 14, 15], [9, 11, 13, 15],
    ]
    bars = []
    for bar in range(LOOP_BARS):
        kick_steps = list(kick_patterns[variation])
        ghosts = list(ghost_patterns[variation])
        fill_steps = fills[variation] if bar % 4 == 3 else []
        if fill_steps:
            kick_steps = [s for s in kick_steps if s not in fill_steps]
        bass_steps = [0, 8]
        if bar % 8 == 7:
            bass_steps = [0]  # last two beats drop the bass
        bars.append({
            "kick": kick_steps,
            "kick_ghost": ghosts,
            "snare": [4, 12],
            "rimshot": [4, 12],
            "hat_8th_swing": list(range(0, 16, 2)),
            "open_hat": [7],
            "bass_root": bass_steps,
            "fill_muted_tom": fill_steps,
            "bass_drop_last_two_beats": bar % 8 == 7,
        })
    return {
        "tempo_bpm": BPM,
        "time_signature": "4/4",
        "swing_percent": int(SWING * 100),
        "count_in_bars": COUNT_IN_BARS,
        "loop_bars": LOOP_BARS,
        "loop_start_seconds": COUNT_IN_BARS * 4 * BEAT,
        "loop_length_seconds": LOOP_BARS * 4 * BEAT,
        "frequency_design": "Kick/bass below 250 Hz; snare body below 2 kHz; hat air above 5 kHz; no melodic midrange.",
        "bars": bars,
    }


def render(pattern: dict, variation: int) -> np.ndarray:
    total = int((COUNT_IN_BARS + LOOP_BARS) * 4 * BEAT * SR)
    out = np.zeros(total, dtype=np.float32)
    voices = {"kick": kick(), "snare": snare(), "rim": rim(), "hat": hat(),
              "open_hat": hat(0.24, True), "bass": bass(), "tick": noise_tick()}
    # Count-in: two restrained sticks on beats 2 and 4, then the loop begins.
    add_voice(out, BEAT, voices["rim"], 0.55)
    add_voice(out, 3 * BEAT, voices["rim"], 0.55)
    for bar, events in enumerate(pattern["bars"]):
        for step in events["kick"]:
            add_voice(out, swung_time(bar, step), voices["kick"], 0.75)
        for step in events["kick_ghost"]:
            add_voice(out, swung_time(bar, step), voices["kick"], 0.23)
        for step in events["snare"]:
            add_voice(out, swung_time(bar, step), voices["snare"], 0.80)
        for step in events["rimshot"]:
            add_voice(out, swung_time(bar, step), voices["rim"], 0.32)
        for step in events["hat_8th_swing"]:
            add_voice(out, swung_time(bar, step), voices["hat"], 0.52)
        for step in events["open_hat"]:
            add_voice(out, swung_time(bar, step), voices["open_hat"], 0.42)
        for step in events["bass_root"]:
            add_voice(out, swung_time(bar, step), voices["bass"], 0.72)
        for step in events["fill_muted_tom"]:
            add_voice(out, swung_time(bar, step), voices["rim"], 0.14)
            add_voice(out, swung_time(bar, step), voices["tick"], 0.35)
    peak = np.max(np.abs(out))
    return (out / max(peak, 1.0) * 0.88).astype(np.float32)


def main() -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    for variation in range(6):
        pattern = matrix_for(variation)
        audio = render(pattern, variation)
        name = f"scratch_break_92bpm_v{variation + 1}"
        sf.write(OUT / f"{name}.wav", np.column_stack([audio, audio]), SR, subtype="PCM_16")
        (OUT / f"{name}.json").write_text(json.dumps(pattern, indent=2) + "\n")
    manifest = {
        "source": "Original synthesized material; supplied Scratch Visualizer breaks used only as stylistic references.",
        "files": [f"scratch_break_92bpm_v{i}.wav" for i in range(1, 7)],
        "loop_region": {"start_seconds": COUNT_IN_BARS * 4 * BEAT, "length_seconds": LOOP_BARS * 4 * BEAT},
    }
    (OUT / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")


if __name__ == "__main__":
    main()
