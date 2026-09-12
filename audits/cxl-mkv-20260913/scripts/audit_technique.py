#!/usr/bin/env python3
"""Per-technique audit. Deterministic and resumable: writes to a .partial file and
renames only after every section completed, so an interrupted run is never mistaken
for a finished one.

Usage: python3 scripts/audit_technique.py <technique_key>     e.g. cutting_79bpm
"""
import hashlib, json, os, subprocess, sys, tempfile
from pathlib import Path
import numpy as np

EV = Path(__file__).resolve().parent.parent
SRC = Path("/Volumes/Untitled/CXLrip")
DS = Path("/Users/karlwatson/Movies/PRO DJ DATASET/dataset")
SC = Path(os.environ.get("BATCH_SCRATCH", "/tmp/cxl-batch"))
SR, FS = 48000, 32767.0
VW, VH = 360, 240

def atomic(path, text):
    fd, tmp = tempfile.mkstemp(dir=str(Path(path).parent), prefix=".tmp-")
    with os.fdopen(fd, "w") as fh: fh.write(text)
    os.replace(tmp, path)

def run(cmd, **kw):
    return subprocess.run(cmd, capture_output=True, text=kw.pop("text", True), **kw)

def pcm(title, idx):
    SC.joinpath("pcm").mkdir(parents=True, exist_ok=True)
    dst = SC / "pcm" / f"{title}-a{idx}.s16le"
    if not dst.exists() or dst.stat().st_size == 0:
        subprocess.run(["ffmpeg", "-nostdin", "-v", "error", "-i", str(SRC / f"{title}.mkv"),
                        "-map", f"0:a:{idx}", "-vn", "-sn", "-dn", "-ac", "2", "-ar", "48000",
                        "-c:a", "pcm_s16le", "-f", "s16le", str(dst)], check=True)
    return np.fromfile(dst, dtype="<i2").reshape(-1, 2).astype(np.float64)

def gray_full(title):
    SC.joinpath("grayfull").mkdir(parents=True, exist_ok=True)
    dst = SC / "grayfull" / f"{title}.gray"
    if not dst.exists() or dst.stat().st_size == 0:
        subprocess.run(["ffmpeg", "-nostdin", "-v", "error", "-i", str(SRC / f"{title}.mkv"),
                        "-map", "0:v:0", "-vf", f"scale={VW}:{VH}:flags=bicubic,format=gray",
                        "-fps_mode", "passthrough", "-f", "rawvideo", str(dst)], check=True)
    return np.fromfile(dst, dtype=np.uint8).reshape(-1, VH, VW).astype(np.float32)

def sha_file(p):
    h = hashlib.sha256()
    with open(p, "rb") as fh:
        for c in iter(lambda: fh.read(1 << 20), b""): h.update(c)
    return h.hexdigest()

def db(x): return round(float(20*np.log10(max(np.sqrt((np.asarray(x)**2).mean()), 1e-9)/FS)), 2)
def ncc(u, v):
    u = np.asarray(u).ravel(); v = np.asarray(v).ravel()
    u = u - u.mean(); v = v - v.mean()
    return float(u @ v / (np.linalg.norm(u)*np.linalg.norm(v) + 1e-12))
def zn(a, b):
    a = a.reshape(len(a), -1); b = b.reshape(len(b), -1)
    a = a - a.mean(1, keepdims=True); b = b - b.mean(1, keepdims=True)
    return float(np.mean((a*b).sum(1)/(np.linalg.norm(a,axis=1)*np.linalg.norm(b,axis=1)+1e-9)))

def envelope(x, hop=480, win=1024):
    m = np.asarray(x).mean(axis=1) if np.asarray(x).ndim == 2 else np.asarray(x)
    n = (len(m) - win)//hop + 1
    idx = np.arange(win)[None, :] + hop*np.arange(n)[:, None]
    return np.sqrt((m[idx]**2).mean(axis=1)), np.arange(n)*hop/SR

def runs(mask, minlen, gap=0):
    out, s = [], None
    for i, v in enumerate(mask):
        if v and s is None: s = i
        elif not v and s is not None:
            if i - s >= minlen: out.append([s, i])
            s = None
    if s is not None and len(mask)-s >= minlen: out.append([s, len(mask)])
    if gap:
        merged = []
        for a, b in out:
            if merged and a - merged[-1][1] <= gap: merged[-1][1] = b
            else: merged.append([a, b])
        out = merged
    return out

# ---------------------------------------------------------------- main
key = sys.argv[1]
groups = json.load(open(EV / "inventory" / "stage-a-groups.json"))
binding = json.load(open(EV / "inventory" / "angle-binding.json"))[key]
edit = groups["edit_lists"][key]
tech, bpm = edit["scratch"], edit["bpm"]
ch2 = edit["chapter2"]
angles = {a: v["title"] for a, v in binding["angles"].items() if "title" in v}
titles = sorted(set(angles.values()))
outdir = EV / "techniques"; outdir.mkdir(exist_ok=True)
final = outdir / f"{key}.json"; partial = outdir / f"{key}.partial.json"

if final.exists():
    print(f"{final.name} already complete; nothing to do (delete it to force a rerun).")
    sys.exit(0)
R = json.loads(partial.read_text()) if partial.exists() else {
     "technique": tech, "bpm": bpm, "key": key, "chapter2": ch2,
     "angle_to_title": angles, "distinct_titles": titles,
     "missing_delivered_angles": [a for a in "1234" if a not in angles],
     "sections_completed": []}
def need(name):
    """True if this section still has to run. Verified sections are never recomputed."""
    return name not in R["sections_completed"]
def save(done=False):
    R["complete"] = done
    atomic(partial, json.dumps(R, indent=2))

if need("video_integrity"):
      # ---- 1. decode integrity, field order, timing, aspect --------------
    R["video"] = {}
    for t in sorted(set(binding["candidate_titles"])):
        fr = json.loads(run(["ffprobe", "-v", "error", "-select_streams", "v:0", "-show_entries",
            "frame=pts_time,interlaced_frame,top_field_first,repeat_pict,width,height,sample_aspect_ratio",
            "-of", "json", str(SRC / f"{t}.mkv")]).stdout)["frames"]
        pts = np.array([float(f["pts_time"]) for f in fr]); d = np.diff(pts)
        dec = run(["ffmpeg", "-nostdin", "-v", "error", "-i", str(SRC / f"{t}.mkv"),
                   "-map", "0:v:0", "-f", "null", "-"])
        R["video"][t] = {
            "frames": len(fr), "first_pts": float(pts[0]), "last_pts": round(float(pts[-1]), 6),
            "pts_monotonic": bool(np.all(d > 0)),
            "pts_step_mean": round(float(d.mean()), 9),
            "pts_step_range": [round(float(d.min()), 6), round(float(d.max()), 6)],
            "interlaced_frames": int(sum(f.get("interlaced_frame", 0) for f in fr)),
            "top_field_first_count": int(sum(f.get("top_field_first", 0) for f in fr)),
            "repeat_pict_nonzero": int(sum(1 for f in fr if f.get("repeat_pict", 0))),
            "sar": sorted({f.get("sample_aspect_ratio") for f in fr}),
            "size": sorted({f"{f['width']}x{f['height']}" for f in fr}),
            "decode_stderr": dec.stderr.strip()[:400],
            "decode_clean": dec.stderr.strip() == "",
        }
        idet = run(["ffmpeg", "-nostdin", "-i", str(SRC / f"{t}.mkv"), "-map", "0:v:0",
                    "-ss", f"{ch2[0]}", "-to", f"{min(ch2[1], ch2[0]+10):.3f}", "-vf", "idet",
                    "-an", "-sn", "-f", "null", "-"]).stderr
        line = [l for l in idet.splitlines() if "Multi frame detection" in l]
        R["video"][t]["idet_multi_frame"] = line[-1].split("]")[-1].strip() if line else "n/a"
    R["sections_completed"].append("video_integrity"); save()

# ---- 2. audio: identity across angles, roles, levels, hum ----------
# decoded PCM is cached on disk, so it is loaded unconditionally: sections 5-7 need it
# even when section 2 is skipped on a resume.
nA = groups["titles"][titles[0]]["n_audio"]
data = {}
for t in sorted(set(binding["candidate_titles"])):
    for i in range(nA):
        data[(t, i)] = pcm(t, i)

if need("audio_streams"):
    R["audio"] = {"n_streams": nA, "streams": {}, "cross_title_identity": {}, "roles": None}
    for t in sorted(set(binding["candidate_titles"])):
        for i in range(nA):
            R["audio"]["streams"].setdefault(t, {})[f"a{i}"] = {
                "sha256": sha_file(SC / "pcm" / f"{t}-a{i}.s16le"),
                "samples": int(len(data[(t, i)])),
                "duration_s": round(len(data[(t, i)])/SR, 4),
                "rms_dbfs": db(data[(t, i)]),
                "peak_dbfs": round(float(20*np.log10(max(np.abs(data[(t, i)]).max(), 1)/FS)), 3),
                "samples_at_full_scale": int((np.abs(data[(t, i)]) >= 32767).sum()),
            }
    for i in range(nA):
        hs = {t: R["audio"]["streams"][t][f"a{i}"]["sha256"] for t in sorted(set(binding["candidate_titles"]))}
        cls = {}
        for t, h in hs.items(): cls.setdefault(h, []).append(t)
        R["audio"]["cross_title_identity"][f"a{i}"] = {"equality_classes": [sorted(v) for v in cls.values()]}
    if nA == 3:
        t0 = titles[0]
        # The component test must be run where there is no narration. Speech lives on the
        # mixed track only, so including chapter 1 breaks the relation and would produce a
        # false negative. Chapter 2 is the performance region.
        sl = slice(int(ch2[0]*SR), int(min(ch2[1], len(data[(t0,0)])/SR)*SR))
        a0, a1, a2 = data[(t0,0)][sl], data[(t0,1)][sl], data[(t0,2)][sl]
        r = a0 - a1 - a2
        f0, f1, f2 = data[(t0,0)], data[(t0,1)], data[(t0,2)]
        R["audio"]["roles"] = {
            "hypothesis": {"0:a:0": "withBeat", "0:a:1": "noBeat", "0:a:2": "beatOnly"},
            "test": "a0 - a1 - a2 should collapse, measured over chapter 2 only",
            "window_s": [ch2[0], ch2[1]],
            "residual_dbfs": db(r), "programme_dbfs": db(a0),
            "residual_below_programme_db": round(db(r) - db(a0), 2),
            "corr_a0_minus_a2_vs_a1": round(ncc(a0-a2, a1), 6),
            "rms_dbfs": {"a0": db(a0), "a1": db(a1), "a2": db(a2)},
            "full_title_residual_below_programme_db": round(db(f0-f1-f2) - db(f0), 2),
            "full_title_note": "expected to be much worse than the chapter-2 figure whenever the "
                               "title has narration, because speech is on the mixed track alone",
            "verdict": None}
        R["audio"]["roles"]["verdict"] = (
            "CONFIRMED for this technique" if db(r) - db(a0) < -35 else
            "NOT CONFIRMED - do not reuse Baby's stream order here")
    else:
        R["audio"]["roles"] = {"verdict": f"only {nA} audio stream(s); no component test possible; "
                                          "no isolated-scratch track available"}
    R["sections_completed"].append("audio_streams"); save()

if need("title_duplicates"):
    # Two titles in a group can carry the same camera view. Tested exactly with
    # per-frame MD5 of the decoded video, not sampled similarity.
    cands = sorted(set(binding["candidate_titles"]))
    SC.joinpath("framemd5").mkdir(parents=True, exist_ok=True)
    sigs = {}
    for t in cands:
        dst = SC / "framemd5" / f"{t}.framemd5"
        if not dst.exists() or dst.stat().st_size == 0:
            subprocess.run(["ffmpeg", "-nostdin", "-v", "error", "-i", str(SRC / f"{t}.mkv"),
                            "-map", "0:v:0", "-f", "framemd5", "-y", str(dst)], check=True)
        lines = [l for l in dst.read_text().splitlines() if l and not l.startswith("#")]
        sigs[t] = (len(lines), hashlib.sha256("\n".join(
            l.split(",")[-1].strip() for l in lines).encode()).hexdigest())
    cls = {}
    for t, v in sigs.items():
        cls.setdefault(v, []).append(t)
    R["title_duplicates"] = {
        "method": "ffmpeg framemd5 of the decoded video stream; identical hash sequence means "
                  "identical decoded frames for the whole title",
        "per_title": {t: {"frames": v[0], "frame_hash_sequence_sha256": v[1]} for t, v in sigs.items()},
        "identical_video_groups": [sorted(v) for v in cls.values() if len(v) > 1],
        "distinct_camera_views_in_group": len(cls),
        "titles_in_group": len(cands),
    }
    R["sections_completed"].append("title_duplicates"); save()

if need("repeat_within_title"):
      # ---- 3. repeated content inside the title -------------------------
    t_ref = angles.get("1", titles[0])
    f = gray_full(t_ref)
    pts = np.array([float(x["pts_time"]) for x in json.loads(run(["ffprobe","-v","error",
        "-select_streams","v:0","-show_entries","frame=pts_time","-of","json",
        str(SRC/f"{t_ref}.mkv")]).stdout)["frames"]])
    sel = (pts >= ch2[0]) & (pts <= ch2[1])
    fv = f[sel]
    D = fv.reshape(len(fv), -1); D = D - D.mean(1, keepdims=True)
    D /= (np.linalg.norm(D, axis=1, keepdims=True) + 1e-9)
    adj = float(np.mean([D[i] @ D[i+1] for i in range(len(D)-1)]))
    best = {"offset_frames": None, "mean_similarity": -1}
    lo = int(2.0*30000/1001)
    for off in range(lo, len(D)-lo):
        s = float(np.mean([D[i] @ D[i+off] for i in range(0, len(D)-off, 3)]))
        if s > best["mean_similarity"]: best = {"offset_frames": off, "mean_similarity": round(s, 5)}
    best["offset_s"] = round(best["offset_frames"]*1001/30000, 6)
    rnd = float(np.mean([D[i] @ D[(i+137) % len(D)] for i in range(len(D)-1)]))
    R["repeat_within_title"] = {
        "reference_title": t_ref, "chapter2_frames": int(len(fv)),
        "adjacent_frame_similarity": round(adj, 5),
        "random_pair_similarity": round(rnd, 5),
        "best_nonlocal_offset": best,
        "video_repeat_detected": bool(best["mean_similarity"] > adj),
        "criterion": "a real repeat makes frames OFF apart at least as similar as neighbouring frames",
    }
    if R["repeat_within_title"]["video_repeat_detected"] and nA == 3:
        off_s = best["offset_s"]; n = int(round((ch2[1]-ch2[0]-off_s)*SR))
        if n > SR:
            s0 = int(ch2[0]*SR); s1 = s0 + int(round(off_s*SR))
            iso = data[(t_ref, 1)]
            R["repeat_within_title"]["isolated_scratch_confirmation"] = {
                "ncc_at_video_offset": round(ncc(iso[s0:s0+n], iso[s1:s1+n]), 6),
                "note": "confirmation uses the isolated-scratch track, not the beat"}
    elif R["repeat_within_title"]["video_repeat_detected"]:
        R["repeat_within_title"]["isolated_scratch_confirmation"] = {
            "note": "no isolated-scratch track available; video-only evidence"}
    R["sections_completed"].append("repeat_within_title"); save()

if need("segment_duplication"):
      # ---- 4. duplication among delivered exported segments -------------
    import re, wave
    vids = sorted((DS/"video"/tech).glob(f"{tech}_{bpm}bpm_angle_*_take*.mp4"))
    byang = {}
    for p in vids:
        m = re.search(r"angle_(\d)_take(\d+)", p.name)
        byang.setdefault(m.group(1), {})[int(m.group(2))] = p
    def gray_clip(p):
        SC.joinpath("clip").mkdir(parents=True, exist_ok=True)
        dst = SC/"clip"/f"{p.stem}.gray"
        if not dst.exists():
            subprocess.run(["ffmpeg","-nostdin","-v","error","-i",str(p),
                            "-vf","scale=180:120:flags=bicubic,format=gray",
                            "-fps_mode","passthrough","-f","rawvideo",str(dst)],check=True)
        return np.fromfile(dst,dtype=np.uint8).reshape(-1,120,180).astype(np.float32)
    dup = {}
    for a, takes in sorted(byang.items()):
        ks = sorted(takes); G = {k: gray_clip(takes[k]) for k in ks}
        pairs = {}
        for i in range(len(ks)):
            for j in range(i+1, len(ks)):
                x, y = G[ks[i]], G[ks[j]]
                L = min(len(x), len(y)) - 12
                if L < 20: continue
                sc = max((zn(x[6:6+L], y[6+d:6+d+L]), d) for d in range(-6, 7))
                if sc[0] > 0.99:
                    pairs[f"take{ks[i]:02d}_vs_take{ks[j]:02d}"] = {
                        "zncc": round(sc[0], 5), "frame_offset": sc[1], "frames": L}
        dup[f"angle_{a}"] = {"takes": len(ks), "duplicate_pairs_zncc_gt_0.99": pairs}
    R["delivered_segment_duplication"] = dup
    R["sections_completed"].append("segment_duplication"); save()

if need("talking_boundaries"):
      # ---- 5. talking boundaries ----------------------------------------
    tb = {"method_note":
          "Two independent tests. (a) Component subtraction isolates content unique to the mixed "
          "track, but CANNOT prove absence of speech: voice shared by two components cancels. "
          "(b) A per-stream voice-band indicator is run on every stream separately. Neither replaces "
          "listening; boundary previews are produced and operator audition is REQUIRED.",
          "operator_audition": "PENDING"}
    if nA == 3:
        t0 = titles[0]
        res = data[(t0, 0)] - data[(t0, 1)] - data[(t0, 2)]
        rr, tt = envelope(res)
        floor = float(np.median(rr[(tt > ch2[0]+5) & (tt < ch2[1]-2)])) if (ch2[1]-ch2[0]) > 10 else float(np.median(rr))
        thr = max(floor*6, 1e-9)
        sp = runs(rr > thr, 15, gap=40)
        tb["residual_speech_runs_s"] = [[round(float(tt[a]), 3), round(float(tt[b-1]), 3)] for a, b in sp]
        tb["residual_floor"] = round(floor, 3); tb["residual_threshold"] = round(thr, 3)
        tb["residual_max_after_chapter2_start"] = round(float(rr[tt >= ch2[0]].max()), 2)
        tb["residual_max_before_chapter2_start"] = round(float(rr[tt < ch2[0]].max()), 2)
    # per-stream voice-band indicator, every stream
    tb["per_stream_voice_band"] = {}
    for i in range(nA):
        x = data[(titles[0], i)].mean(axis=1)
        hop, win = 480, 1024
        n = (len(x)-win)//hop + 1
        idx = np.arange(win)[None, :] + hop*np.arange(n)[:, None]
        fr_ = x[idx]*np.hanning(win)[None, :]
        sp_ = np.abs(np.fft.rfft(fr_, axis=1))**2
        fq = np.fft.rfftfreq(win, 1/SR)
        tot = sp_.sum(1)+1e-9
        voice = sp_[:, (fq >= 300) & (fq <= 3400)].sum(1)/tot
        high = sp_[:, fq > 5000].sum(1)/tot
        rms_ = np.sqrt((fr_**2).mean(1))
        loud = rms_ > max(np.percentile(rms_, 20)*4, rms_.max()*0.02)
        cand = runs(loud & (voice > 0.55) & (high < 0.12), 25, gap=30)
        tv = np.arange(n)*hop/SR
        inside = [[round(float(tv[a]),2), round(float(tv[b-1]),2)] for a, b in cand
                  if tv[b-1] > ch2[0] and tv[a] < ch2[1]]
        tb["per_stream_voice_band"][f"a{i}"] = {
            "candidate_runs_total": len(cand),
            "candidate_runs_inside_chapter2": inside[:20],
            "n_inside_chapter2": len(inside),
            "caveat": "scratch transients also carry voice-band energy; these are candidates, not detections"}
    R["talking_boundaries"] = tb
    R["sections_completed"].append("talking_boundaries"); save()

if need("noise"):
      # ---- 6. hum / hiss / clipping, measured only -----------------------
    noise = {"policy": "measured observations only; no filter applied, no Baby setting reused"}
    sil = edit.get("silences", [])
    pause = [[a, b] for a, b in sil if b - a > 1.0][:8]
    noise["pause_windows_used_s"] = pause
    for i in range(nA):
        x = data[(titles[0], i)]
        if pause:
            q = np.concatenate([x[int(a*SR):int(b*SR)] for a, b in pause], axis=0).mean(axis=1)
        else:
            q = x[:int(2*SR)].mean(axis=1)
        N = 1 << 16
        if len(q) < N: N = 1 << int(np.floor(np.log2(len(q))))
        w = np.hanning(N); cg = w.sum()/N
        acc = np.zeros(N//2+1); c = 0
        for s in range(0, len(q)-N+1, N//2):
            acc += np.abs(np.fft.rfft(q[s:s+N]*w))**2; c += 1
        psd = acc/max(c, 1); fq = np.fft.rfftfreq(N, 1/SR)
        def tone(f0, hw=3.0):
            m = (fq > f0-hw) & (fq < f0+hw)
            if not m.any(): return None
            return round(float(20*np.log10(max(np.sqrt(psd[m].max())/(N*cg/2), 1e-9)/FS)), 2)
        # fit the mains fundamental instead of assuming 50 or 60 Hz
        grid = np.arange(49.0, 61.01, 0.01)
        seg = q[:min(len(q), 3*SR)]; seg = seg - seg.mean()
        nn = np.arange(len(seg))
        sc = [abs(np.dot(seg, np.exp(-2j*np.pi*fh*nn/SR))) + abs(np.dot(seg, np.exp(-2j*np.pi*3*fh*nn/SR)))
              for fh in grid]
        f0 = float(grid[int(np.argmax(sc))])
        hf = (fq > 2000) & (fq < 16000)
        noise[f"a{i}"] = {
            "quiet_material_s": round(len(q)/SR, 3),
            "quiet_rms_dbfs": db(q),
            "fitted_mains_fundamental_hz": round(f0, 3),
            "harmonic_levels_dbfs": {str(round(f0*k, 2)): tone(f0*k) for k in (1, 2, 3, 4, 5, 7)},
            "broadband_median_2k_16k_dbfs_per_bin": round(float(10*np.log10(np.median(psd[hf])/(FS**2)+1e-20)), 2),
            "peak_dbfs": R["audio"]["streams"][titles[0]][f"a{i}"]["peak_dbfs"],
            "samples_at_full_scale": R["audio"]["streams"][titles[0]][f"a{i}"]["samples_at_full_scale"],
            "interpretation_warning": "these windows may still contain music; a peak at the mains "
                                      "frequency is only hum if the stream is otherwise quiet there",
        }
    R["hum_hiss_clipping"] = noise
    R["sections_completed"].append("noise"); save()

if need("av_sync"):
      # ---- 7. measured A/V sync ------------------------------------------
    if nA == 3:
        t0 = angles.get("3", titles[0])
        f3 = gray_full(t0)
        pts3 = np.array([float(x["pts_time"]) for x in json.loads(run(["ffprobe","-v","error",
            "-select_streams","v:0","-show_entries","frame=pts_time","-of","json",
            str(SRC/f"{t0}.mkv")]).stdout)["frames"]])
        m = (pts3 >= ch2[0]) & (pts3 <= ch2[1])
        fv3 = f3[m]; tv3 = pts3[m]
        motion = np.abs(np.diff(fv3, axis=0)).mean(axis=(1, 2))
        mt = (tv3[:-1] + tv3[1:]) / 2
        iso = data[(t0, 1)].mean(axis=1)
        env = np.array([np.sqrt((iso[int(t*SR):int(t*SR)+1602]**2).mean()+1e-9) for t in mt])
        segs = {}
        span = ch2[1]-ch2[0]
        for lbl, (u, v) in (("start", (0, min(8, span/3))), ("middle", (span/2-4, span/2+4)),
                            ("end", (span-8, span))):
            sel2 = (mt-ch2[0] >= u) & (mt-ch2[0] < v)
            if sel2.sum() < 60: continue
            a_ = motion[sel2]-motion[sel2].mean(); b_ = env[sel2]-env[sel2].mean()
            a_ /= np.linalg.norm(a_)+1e-12; b_ /= np.linalg.norm(b_)+1e-12
            lags = np.arange(-15, 16)
            cc = [float(np.dot(a_[max(0,l):len(a_)+min(0,l)], b_[max(0,-l):len(b_)+min(0,-l)])) for l in lags]
            k = int(np.argmax(cc))
            segs[lbl] = {"best_lag_frames": int(lags[k]),
                         "best_lag_ms": round(float(lags[k])*1001/30, 2),
                         "peak_corr": round(cc[k], 4),
                         "corr_at_zero": round(cc[list(lags).index(0)], 4)}
        R["av_sync"] = {"reference_title": t0, "method":
            "isolated-scratch loudness envelope vs per-frame video motion energy; "
            "resolution ~1 frame (33.4 ms), not better", "segments": segs}
    else:
        R["av_sync"] = {"note": "no isolated-scratch track; envelope method not applicable"}
    R["sections_completed"].append("av_sync"); save(done=True)

save(done=True)
os.replace(partial, final)
print(json.dumps({k: R[k] for k in ("technique","angle_to_title","missing_delivered_angles")}, indent=2))
print("sections:", R["sections_completed"])
print("written:", final)
