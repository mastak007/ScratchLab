#!/usr/bin/env python3
from __future__ import annotations

import json
import sys
from pathlib import Path


def main() -> int:
    path = Path(sys.argv[-1])
    if not path.exists():
        print(f"{path} not found", file=sys.stderr)
        return 1

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
