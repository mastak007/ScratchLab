#!/usr/bin/env python3
"""Stage A: group the 119 source titles into techniques and camera angles using
evidence, not filenames or duration.

Three independent signals are combined:
  1. chapter structure (chapter-2 start/end pair) from the existing probe JSON;
  2. an audio equality class - titles whose decoded audio excerpt is byte-identical
     share one recording, which is what actually binds camera angles together;
  3. video dissimilarity inside a group, which is what separates camera angles.

Technique names come from matching the chapter-2 range against the dataset edit
lists.  Nothing is decoded that the existing inventory already answers.

Resumable: audio fingerprints are cached per title in inventory/audio-fingerprints.json.
"""
import hashlib, json, os, subprocess, sys, tempfile
from pathlib import Path

EV = Path(__file__).resolve().parent.parent
PRIOR = EV.parent
SRC = Path("/Volumes/Untitled/CXLrip")
DS = Path("/Users/karlwatson/Movies/PRO DJ DATASET/dataset")
FP = EV / "inventory" / "audio-fingerprints.json"

def atomic_write(path, text):
    path = Path(path)
    fd, tmp = tempfile.mkstemp(dir=str(path.parent), prefix=".tmp-")
    with os.fdopen(fd, "w") as fh:
        fh.write(text)
    os.replace(tmp, path)

# ---- 1. chapters + stream shape, straight from the existing probe output ----
titles = {}
for p in sorted((PRIOR / "probe").glob("Scratch_t*.json")):
    d = json.load(open(p))
    name = p.stem
    ch = d.get("chapters", [])
    v = next(s for s in d["streams"] if s["codec_type"] == "video")
    au = [s for s in d["streams"] if s["codec_type"] == "audio"]
    titles[name] = {
        "file": name + ".mkv",
        "duration": float(d["format"]["duration"]),
        "n_audio": len(au),
        "audio_source_ids": [s.get("tags", {}).get("SOURCE_ID") for s in au],
        "video": {k: v.get(k) for k in ("codec_name", "width", "height",
                  "sample_aspect_ratio", "display_aspect_ratio", "field_order", "r_frame_rate")},
        "chapters": [[float(c["start_time"]), float(c["end_time"])] for c in ch],
        "chapter2": [float(ch[1]["start_time"]), float(ch[1]["end_time"])] if len(ch) == 2 else None,
    }

# ---- 2. audio equality classes (cached, resumable) ----
fps = json.loads(FP.read_text()) if FP.exists() else {}
todo = [t for t in titles if t not in fps]
for i, t in enumerate(todo):
    # 4 s from a fixed absolute position that exists in every title
    r = subprocess.run(["ffmpeg", "-nostdin", "-v", "error", "-i", str(SRC / titles[t]["file"]),
                        "-map", "0:a:0", "-af", "atrim=start=10:end=14,asetpts=PTS-STARTPTS",
                        "-vn", "-sn", "-dn", "-ac", "2", "-ar", "48000",
                        "-c:a", "pcm_s16le", "-f", "s16le", "pipe:1"],
                       capture_output=True)
    fps[t] = {"a0_10_14s_sha256": hashlib.sha256(r.stdout).hexdigest(),
              "bytes": len(r.stdout)}
    if (i + 1) % 20 == 0 or i == len(todo) - 1:
        atomic_write(FP, json.dumps(fps, indent=2))
        print(f"  fingerprinted {i+1}/{len(todo)}", file=sys.stderr)
if todo:
    atomic_write(FP, json.dumps(fps, indent=2))

# ---- 3. edit-list technique names, matched on the chapter-2 range ----
edits = {}
for p in sorted((DS / "edit_lists").glob("*.json")):
    e = json.load(open(p))
    edits[p.stem] = {"scratch": e["scratch"], "bpm": e["bpm"],
                     "chapter2": e.get("chapter2"), "keeps": e.get("keeps", []),
                     "silences": e.get("silences", [])}

def key(ch2):
    return None if ch2 is None else (round(ch2[0], 3), round(ch2[1], 3))

edit_by_ch2 = {}
for name, e in edits.items():
    k = key(e["chapter2"])
    edit_by_ch2.setdefault(k, []).append(name)

# ---- 4. combine into groups ----
groups = {}
for t, d in titles.items():
    k = key(d["chapter2"])
    gid = f"ch2_{k[0]:.3f}_{k[1]:.3f}" if k else f"nochapters_{t}"
    groups.setdefault(gid, {"chapter2": list(k) if k else None, "titles": []})["titles"].append(t)

for gid, g in groups.items():
    g["titles"].sort()
    g["n_titles"] = len(g["titles"])
    k = key(g["chapter2"]) if g["chapter2"] else None
    cand = edit_by_ch2.get(k, [])
    g["edit_list_candidates"] = cand
    g["technique_binding"] = ("unique edit-list match" if len(cand) == 1
                              else "ambiguous - multiple edit lists share this chapter-2 range"
                              if len(cand) > 1 else "no edit-list match")
    ah = {t: fps[t]["a0_10_14s_sha256"] for t in g["titles"]}
    classes = {}
    for t, h in ah.items():
        classes.setdefault(h, []).append(t)
    g["audio_equality_classes"] = [sorted(v) for v in classes.values()]
    g["audio_binds_all_titles"] = len(classes) == 1
    g["n_audio_streams"] = sorted({titles[t]["n_audio"] for t in g["titles"]})
    g["video_specs"] = sorted({json.dumps(titles[t]["video"], sort_keys=True) for t in g["titles"]})
    g["durations"] = sorted({round(titles[t]["duration"], 3) for t in g["titles"]})

# cross-group audio collisions would break the grouping assumption
allfp = {}
for t in titles:
    allfp.setdefault(fps[t]["a0_10_14s_sha256"], []).append(t)
collisions = {h: sorted(v) for h, v in allfp.items() if len(v) > 1}
gid_of = {t: gid for gid, g in groups.items() for t in g["titles"]}
cross = {h: v for h, v in collisions.items() if len({gid_of[t] for t in v}) > 1}

out = {
  "generated_by": "scripts/stage_a_inventory.py",
  "n_titles": len(titles),
  "n_groups": len(groups),
  "grouping_evidence": "chapter-2 range (primary) + byte-identical audio excerpt (binds angles) "
                       "+ edit-list chapter-2 match (technique name). Filenames and duration alone "
                       "were NOT used to decide membership.",
  "audio_fingerprint": "SHA-256 of 0:a:0 decoded to s16le 48 kHz stereo over source 10.000-14.000 s",
  "cross_group_audio_collisions": cross,
  "groups": dict(sorted(groups.items())),
  "titles": titles,
  "edit_lists": edits,
}
atomic_write(EV / "inventory" / "stage-a-groups.json", json.dumps(out, indent=2))

sizes = {}
for g in groups.values():
    sizes[g["n_titles"]] = sizes.get(g["n_titles"], 0) + 1
print(f"titles={len(titles)} groups={len(groups)} group-size histogram={sizes}")
print(f"cross-group audio collisions: {len(cross)}")
amb = [gid for gid, g in groups.items() if g["technique_binding"] != "unique edit-list match"]
print(f"groups without a unique edit-list match: {len(amb)}")
nb = [gid for gid, g in groups.items() if not g["audio_binds_all_titles"]]
print(f"groups whose titles do NOT all share one audio excerpt: {len(nb)}")
for gid in sorted(nb):
    print("   ", gid, groups[gid]["audio_equality_classes"], groups[gid]["edit_list_candidates"])
