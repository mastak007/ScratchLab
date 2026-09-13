#!/usr/bin/env python3
from __future__ import annotations

import json
import os
import sys
from pathlib import Path


def wav_audio_stream(path: Path) -> dict[str, object]:
    """Report a WAV's real header the way ffprobe would.

    The stub stays truthful so probe values cannot diverge between the
    ffprobe-preferred path and the validator's RIFF fallback.
    """
    data = path.read_bytes()
    if len(data) < 12 or data[0:4] != b"RIFF" or data[8:12] != b"WAVE":
        raise ValueError(f"{path.name}: not a RIFF/WAVE file")

    offset = 12
    fmt: bytes | None = None
    data_size: int | None = None
    while offset + 8 <= len(data):
        chunk_id = data[offset : offset + 4]
        chunk_size = int.from_bytes(data[offset + 4 : offset + 8], "little")
        body = offset + 8
        if chunk_id == b"fmt ":
            fmt = data[body : body + chunk_size]
        elif chunk_id == b"data":
            data_size = min(chunk_size, len(data) - body)
            break
        offset = body + chunk_size + (chunk_size & 1)

    if fmt is None or len(fmt) < 16 or data_size is None:
        raise ValueError(f"{path.name}: unreadable RIFF header")

    format_tag = int.from_bytes(fmt[0:2], "little")
    channels = int.from_bytes(fmt[2:4], "little")
    sample_rate = int.from_bytes(fmt[4:8], "little")
    block_align = int.from_bytes(fmt[12:14], "little") or 1
    bits_per_sample = int.from_bytes(fmt[14:16], "little")

    return {
        "codec_type": "audio",
        "codec_name": "pcm_f32le" if format_tag == 3 else "pcm_s16le",
        "channels": channels,
        "sample_rate": str(sample_rate),
        "bits_per_sample": bits_per_sample,
        "duration_ts": data_size // block_align,
        "time_base": f"1/{sample_rate}",
    }


def main() -> int:
    path = Path(sys.argv[-1])
    if not path.exists():
        print(f"{path} not found", file=sys.stderr)
        return 1

    if path.suffix.lower() == ".wav":
        # Lets a test prove the validator's RIFF fallback without also
        # removing video probing, which genuinely requires ffprobe.
        if os.environ.get("FFPROBE_STUB_FAIL_WAV") == "1":
            print("ffprobe stub: WAV probing disabled for this run", file=sys.stderr)
            return 1
        try:
            stream = wav_audio_stream(path)
        except ValueError as exc:
            print(str(exc), file=sys.stderr)
            return 1
        print(json.dumps({"format": {"filename": str(path)}, "streams": [stream]}))
        return 0

    payload = {
        "format": {
            "filename": str(path),
            "duration": "1.0",
        },
        "streams": [
            {
                "codec_type": "video",
                "codec_name": "h264",
                "width": 1280,
                "height": 720,
                "avg_frame_rate": "30/1",
                "duration": "1.0",
            }
        ],
    }
    print(json.dumps(payload))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
