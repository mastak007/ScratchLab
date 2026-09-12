#!/usr/bin/env python3
"""Stage B: test the Baby report's claim that the delivered 29.97 fps exports
"discarded the second field".

A 29.97 fps frame that still shows combing contains BOTH fields woven together,
so the claim needs testing rather than inference from frame rate or metadata.
Method: split both the source frame and the delivered frame into their two fields
with separatefields (no interpolation at all), and compare field by field.  If
both fields survive in the export, no temporal information was lost and field-rate
processing is still possible from the delivered files.
"""
import json, subprocess, sys, os, tempfile
from pathlib import Path
import numpy as np

EV = Path(__file__).resolve().parent.parent
SRC = Path("/Volumes/Untitled/CXLrip")
DS = Path("/Users/karlwatson/Movies/PRO DJ DATASET/dataset")
SC = Path(os.environ.get("BATCH_SCRATCH", "/tmp/cxl-batch")) / "fields"
SC.mkdir(parents=True, exist_ok=True)
W, H = 720, 240                      # a separated field is half height

def fields(inp, chain, dst):
    """chain is prepended to separatefields; it must be one -vf string or the later
    -vf silently replaces the earlier one."""
    dst = SC / dst
    if not dst.exists():
        vf = (chain + "," if chain else "") + "separatefields,format=gray"
        subprocess.run(["ffmpeg", "-nostdin", "-v", "error", "-i", inp, "-map", "0:v:0",
                        "-vf", vf, "-fps_mode", "passthrough",
                        "-f", "rawvideo", str(dst)], check=True)
    return np.fromfile(dst, dtype=np.uint8).reshape(-1, H, W).astype(np.float32)

def psnr(a, b):
    m = float(((a - b) ** 2).mean())
    return float("inf") if m == 0 else round(10 * np.log10(255.0 ** 2 / m), 3)

res = {"method": "separatefields on both sides, no interpolation; 184 frames = 368 fields "
                 "of Baby angle 3 take01 (source Scratch_t02 frames 1050-1233)"}

src = fields(str(SRC / "Scratch_t02.mkv"),
             "trim=start_frame=1050:end_frame=1234,setpts=PTS-STARTPTS",
             "src-t02-take01-v2.fields")
exp = fields(str(DS / "video/baby/baby_79bpm_angle_3_take01.mp4"), "",
             "exp-angle3-take01-v2.fields")
n = min(len(src), len(exp))
res["source_fields"] = int(len(src))
res["delivered_fields"] = int(len(exp))

# separatefields emits fields in stored order; for BFF content field 0 of each pair is
# the bottom (earlier) field.  Compare like for like, and also against the swap.
aligned = {"field_index_parity_%d" % k: psnr(src[k:n:2], exp[k:n:2]) for k in (0, 1)}
swapped = psnr(src[0:n-1:2], exp[1:n:2])
res["psnr_per_field_parity_db"] = aligned
res["psnr_if_fields_were_swapped_db"] = swapped

# what a genuinely discarded field would look like: one field duplicated from the other
dup = np.repeat(src[0:n:2], 2, axis=0)[:n]
res["psnr_if_second_field_had_been_dropped_and_duplicated_db"] = psnr(src[:n], dup)

# do the two delivered fields actually differ from each other? (a dropped field would
# make them identical or near-identical)
res["field_difference_within_a_frame"] = {
    "delivered_mean_abs_diff_between_the_two_fields": round(float(
        np.abs(exp[0:n:2] - exp[1:n:2]).mean()), 4),
    "source_mean_abs_diff_between_the_two_fields": round(float(
        np.abs(src[0:n:2] - src[1:n:2]).mean()), 4),
    "note": "if a field had been dropped and the other duplicated, these would be ~0"}

# and can the delivered file be field-rate deinterlaced at all?
out = subprocess.run(["ffprobe", "-v", "error", "-select_streams", "v:0", "-count_frames",
                      "-show_entries", "stream=nb_read_frames", "-of", "csv=p=0",
                      "-f", "lavfi", "-i",
                      f"movie='{DS}/video/baby/baby_79bpm_angle_3_take01.mp4',"
                      f"bwdif=mode=send_field:parity=bff:deint=all"], capture_output=True, text=True)
res["field_rate_frames_obtainable_from_delivered_mp4"] = out.stdout.strip() or out.stderr.strip()[:200]

(EV / "reports" / "stage-b-field-retention.json").write_text(json.dumps(res, indent=2))
print(json.dumps(res, indent=2))
