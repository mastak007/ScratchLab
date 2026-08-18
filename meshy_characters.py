#!/usr/bin/env python3
"""Generate a stylistically-consistent set of cartoony 3D characters via Meshy.ai,
rig the humanoid ones, and download everything in formats usable in a SceneKit /
RealityKit iOS project.

API contract (docs.meshy.ai):
  - Text-to-3D (v2):  https://api.meshy.ai/openapi/v2/text-to-3d
      POST  {"mode": "preview", ...}            -> {"result": "<preview_task_id>"}
      POST  {"mode": "refine", "preview_task_id": ...} -> {"result": "<refine_task_id>"}
      GET   /{id}  -> status + model_urls / texture_urls / consumed_credits
  - Rigging (v1):     https://api.meshy.ai/openapi/v1/rigging
      POST  {"input_task_id": <refine_id>, "height_meters": <h>}
      GET   /{id}  -> rigged_character_fbx_url / rigged_character_glb_url / basic_animations

The pipeline is credit-safe by design: `--dry-run` first, sequential by default,
real `consumed_credits` reported per stage, and a per-character `state.json` so a
re-run after interruption resumes completed stages instead of re-generating them.
The default stage (`all`) stops after preview so the four previews can be reviewed
side by side before the expensive refine + rig stages are approved.
"""

import argparse
import csv
import json
import logging
import os
import re
import shutil
import sys
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime, timezone
from pathlib import Path

import requests

# --------------------------------------------------------------------------- #
# Constants
# --------------------------------------------------------------------------- #

TEXT_TO_3D_URL = "https://api.meshy.ai/openapi/v2/text-to-3d"
RIGGING_URL = "https://api.meshy.ai/openapi/v1/rigging"

# Texture map keys Meshy returns on a refine task. These become _source/textures/*.png.
TEXTURE_KEYS = ("base_color", "metallic", "roughness", "normal", "emission")

# A truncated download is worse than a clear failure.
MIN_FILE_BYTES = 1024

# Task statuses that terminate polling.
TERMINAL_STATUSES = ("SUCCEEDED", "FAILED", "CANCELED")

# Shared style bible — appended verbatim to every preview prompt AND refine
# texture_prompt. This identical wording is the main lever for visual consistency,
# since Meshy has no cross-task seed/reference.
STYLE_SUFFIX = (
    "cartoony stylized character design, not photorealistic, proportions roughly 5 to "
    "5.5 heads tall, slightly enlarged head, hands and eyes versus realistic anatomy, "
    "simplified rounded anatomical forms, smooth stylized clothing folds with minimal "
    "fine wrinkles, matte painted PBR material with soft gradient shading and restrained "
    "specular highlights, no glossy plastic-doll shine, no photoreal skin pores or "
    "hyper-detailed textures, flat confident color blocking, clean readable silhouette, "
    "shared team color language of olive-drab and warm tan accents on gear and straps"
)

# The team — written to characters.json on first run if that file is absent.
DEFAULT_CHARACTERS = [
    {
        "slug": "rangikurupatua",
        "name": "Rangikurupatua",
        "is_humanoid": True,
        "height_meters": 1.83,
        "preview_prompt": (
            "A stocky, solid-built Maori man in his late 40s, 20-year army veteran, "
            "close-cropped salt-and-pepper hair, calm controlled expression, weathered "
            "face, wearing practical olive-drab field jacket and cargo trousers, worn "
            "boots, dog tags around his neck, standing in a relaxed a-pose. No tattoos "
            "or facial markings."
        ),
        "texture_prompt": (
            "olive drab and tan field gear, weathered fabric, subtle sun-worn skin tone, "
            "no facial tattoos or moko"
        ),
    },
    {
        "slug": "kwame",
        "name": "Kwame Osei",
        "is_humanoid": True,
        "height_meters": 1.78,
        "preview_prompt": (
            "A broad-shouldered Ghanaian man in his mid-30s, former combat medic turned "
            "field engineer, warm steady expression, dreadlocks tied back, wearing a "
            "practical utility vest over a fitted shirt with rolled sleeves, tool belt, "
            "sturdy boots, standing in a relaxed a-pose."
        ),
        "texture_prompt": (
            "warm brown skin tone, olive drab and tan utility vest with a rust-orange "
            "accent, worn leather tool belt"
        ),
    },
    {
        "slug": "elin",
        "name": "Elin Kask",
        "is_humanoid": True,
        "height_meters": 1.65,
        "preview_prompt": (
            "A lean, wiry Estonian woman in her late 20s, recon and comms specialist, "
            "sharp watchful eyes, closely-cropped or tied-back light hair, wearing a "
            "fitted tactical jacket with a small comms headset, fingerless gloves, "
            "standing in a relaxed a-pose."
        ),
        "texture_prompt": (
            "fair skin tone, olive drab and tan tactical jacket with a pale-blue accent, "
            "dark fingerless gloves"
        ),
    },
    {
        "slug": "rango",
        "name": "Rango",
        "is_humanoid": False,
        "height_meters": 0.35,
        "preview_prompt": (
            "A plump, round-bodied cartoon kiwi bird, the mascot of a small squad, "
            "oversized expressive round eyes, tiny vestigial wings, a short thick stubby "
            "beak (much shorter and chunkier than a real kiwi's long beak, "
            "toy-proportioned), stubby strong legs, rust-brown feathers with a cream "
            "belly, wearing a small worn olive-drab bandana around its neck matching a "
            "set of tiny dog tags, standing in a cute alert pose."
        ),
        "texture_prompt": (
            "rust-brown and cream feather color blocking, simplified chunky feather "
            "clumps not individual feather strands, olive drab bandana accent"
        ),
    },
]

log = logging.getLogger("meshy_characters")


# --------------------------------------------------------------------------- #
# Small helpers
# --------------------------------------------------------------------------- #

def utc_now_iso() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def _parse_retry_after(header, attempt: int) -> float:
    if header:
        try:
            return max(float(header), 0.0)
        except (TypeError, ValueError):
            pass
    return float(2 ** (attempt + 1))


_URL_RE = re.compile(r"https?://\S+")


def sanitize_error(msg: str) -> str:
    """Strip query strings from any URLs embedded in an error string.

    Signed download URLs carry credentials in their query string; this keeps them
    out of log lines, state.json, and run_log.csv.
    """
    return _URL_RE.sub(lambda m: m.group(0).split("?")[0], msg)


# --------------------------------------------------------------------------- #
# API client
# --------------------------------------------------------------------------- #

class MeshyClient:
    def __init__(self, api_key: str):
        self.session = requests.Session()
        self.session.headers["Authorization"] = f"Bearer {api_key}"

    def _request(self, method: str, url: str, retries: int = 3, **kwargs):
        """Perform a request with retry/backoff for network errors, 429, and 5xx."""
        kwargs.setdefault("timeout", (15, 120))
        attempt = 0
        while True:
            try:
                resp = self.session.request(method, url, **kwargs)
            except requests.RequestException as exc:
                attempt += 1
                if attempt > retries:
                    raise
                wait = 2 ** attempt
                log.warning("network error (%s); retrying in %.0fs (%d/%d)",
                            exc, wait, attempt, retries)
                time.sleep(wait)
                continue

            if resp.status_code == 429:
                wait = _parse_retry_after(resp.headers.get("Retry-After"), attempt)
                attempt += 1
                if attempt > retries:
                    resp.raise_for_status()
                log.warning("rate limited (429); backing off %.0fs (%d/%d)", wait, attempt, retries)
                time.sleep(wait)
                continue

            if resp.status_code >= 500:
                wait = 2 ** attempt
                attempt += 1
                if attempt > retries:
                    resp.raise_for_status()
                log.warning("server error (%d); retrying in %.0fs (%d/%d)",
                            resp.status_code, wait, attempt, retries)
                time.sleep(wait)
                continue

            # Any other 4xx (including the rigging 422 pose-estimation failure) is
            # deterministic — surface it without retrying.
            resp.raise_for_status()
            return resp

    def create_task(self, url: str, payload: dict) -> str:
        resp = self._request("POST", url, json=payload)
        data = resp.json()
        task_id = data.get("result")
        if not task_id:
            raise RuntimeError(f"create task returned no 'result': {data}")
        return task_id

    def get_task(self, url: str, task_id: str) -> dict:
        resp = self._request("GET", f"{url}/{task_id}")
        return resp.json()

    def poll_until_terminal(self, url: str, task_id: str,
                            poll_interval: float, timeout: float, stage: str) -> dict:
        deadline = time.monotonic() + timeout
        while True:
            data = self.get_task(url, task_id)
            status = data.get("status")
            if status in TERMINAL_STATUSES:
                return data
            if time.monotonic() >= deadline:
                raise TimeoutError(f"{stage} task {task_id} did not finish within {timeout:.0f}s")
            time.sleep(poll_interval)


def download_url(url: str, dest: Path, retries: int = 3) -> int:
    """Download a (signed) URL to disk WITHOUT the auth header, with retry/backoff.

    Signed model/texture URLs are served by a CDN; we deliberately do not attach
    the Authorization header here so the API key is never sent to that host.
    Returns the number of bytes written.
    """
    display_url = url.split("?")[0]
    attempt = 0
    while True:
        try:
            resp = requests.get(url, timeout=(15, 300))
        except requests.RequestException as exc:
            attempt += 1
            if attempt > retries:
                raise RuntimeError(f"download failed ({type(exc).__name__}) from {display_url}") from exc
            log.warning("download error (%s) from %s; retrying in %.0fs",
                        type(exc).__name__, display_url, 2 ** attempt)
            time.sleep(2 ** attempt)
            continue

        if resp.status_code == 429:
            wait = _parse_retry_after(resp.headers.get("Retry-After"), attempt)
            attempt += 1
            if attempt > retries:
                raise RuntimeError(f"download rate limited (HTTP 429) from {display_url}")
            log.warning("download rate limited; backing off %.0fs", wait)
            time.sleep(wait)
            continue

        if resp.status_code >= 500:
            attempt += 1
            if attempt > retries:
                raise RuntimeError(f"download server error (HTTP {resp.status_code}) from {display_url}")
            log.warning("download server error (%d); retrying in %.0fs", resp.status_code, 2 ** attempt)
            time.sleep(2 ** attempt)
            continue

        try:
            resp.raise_for_status()
        except requests.HTTPError as exc:
            raise RuntimeError(f"download failed (HTTP {resp.status_code}) from {display_url}") from exc

        dest.parent.mkdir(parents=True, exist_ok=True)
        with open(dest, "wb") as fh:
            fh.write(resp.content)
        return dest.stat().st_size


def _download_verified(url: str, dest: Path, slug: str) -> None:
    size = download_url(url, dest)
    if size <= MIN_FILE_BYTES:
        raise RuntimeError(f"{dest.name} for {slug} too small ({size} bytes) — possible truncation")


# --------------------------------------------------------------------------- #
# Prompt builders
# --------------------------------------------------------------------------- #

# Meshy hard-limits the text-to-3d "prompt" field to 800 chars (confirmed via a
# 400 "Prompt must be a maximum of 800 characters" response). The spec caps the
# refine texture_prompt at 600; the preview prompt needs its own 800-char cap.
MAX_PREVIEW_PROMPT_CHARS = 800
MAX_TEXTURE_PROMPT_CHARS = 600


def _append_style(char_text: str, max_chars: int) -> str:
    combined = char_text.strip() + " " + STYLE_SUFFIX
    if len(combined) > max_chars:
        combined = combined[:max_chars].rstrip()
    return combined


def build_preview_prompt(char: dict) -> str:
    return _append_style(char["preview_prompt"], MAX_PREVIEW_PROMPT_CHARS)


def build_texture_prompt(char: dict) -> str:
    return _append_style(char["texture_prompt"], MAX_TEXTURE_PROMPT_CHARS)


def build_preview_payload(char: dict) -> dict:
    """Stage 1 payload. pose_mode is humanoid-only; rango uses a lower polycount."""
    payload = {
        "mode": "preview",
        "prompt": build_preview_prompt(char),
        "should_remesh": True,
        "target_polycount": 40000 if char["is_humanoid"] else 15000,
        "topology": "triangle",
    }
    if char["is_humanoid"]:
        payload["pose_mode"] = "a-pose"
    return payload


def build_refine_payload(char: dict, preview_task_id: str) -> dict:
    return {
        "mode": "refine",
        "preview_task_id": preview_task_id,
        "enable_pbr": True,
        "texture_resolution": "2k",
        "texture_prompt": build_texture_prompt(char),
        "target_formats": ["glb", "usdz"],
    }


def build_rig_payload(char: dict, refine_task_id: str) -> dict:
    return {
        "input_task_id": refine_task_id,
        "height_meters": char["height_meters"],
    }


# --------------------------------------------------------------------------- #
# Per-character state
# --------------------------------------------------------------------------- #

def _resolve_slug_dir(cfg, slug: str) -> Path:
    """Return cfg.output/slug, refusing to escape the output root via symlinks.

    Resolves the output root and the target (following any existing symlink
    components) and requires the target to stay inside the root, so a symlinked
    slug directory can't redirect model/texture/state writes elsewhere.
    """
    target = cfg.output.joinpath(slug)
    root_real = cfg.output.resolve()
    target_real = target.resolve()
    if not target_real.is_relative_to(root_real):
        raise RuntimeError(f"refusing to write outside output root (symlink?): {target}")
    return target


def load_state(cfg, slug: str) -> dict:
    p = _resolve_slug_dir(cfg, slug) / "state.json"
    if not p.exists():
        return {}
    try:
        return json.loads(p.read_text(encoding="utf-8"))
    except (json.JSONDecodeError, OSError) as exc:
        log.warning("%s: could not read state.json (%s) — treating as empty", slug, exc)
        return {}


def save_state(cfg, slug: str, state: dict) -> None:
    p = _resolve_slug_dir(cfg, slug) / "state.json"
    p.parent.mkdir(parents=True, exist_ok=True)
    state.setdefault("slug", slug)
    tmp = p.with_suffix(".json.tmp")
    tmp.write_text(json.dumps(state, indent=2) + "\n", encoding="utf-8")
    tmp.replace(p)  # atomic, so an interrupted run never leaves a half-written state


def write_meta(char: dict, state: dict, cfg) -> None:
    slug = char["slug"]
    meta = {
        "name": char["name"],
        "slug": slug,
        "is_humanoid": char["is_humanoid"],
        "height_meters": char["height_meters"],
        "prompts": {
            "preview": build_preview_prompt(char),
            "texture": build_texture_prompt(char),
        },
        "task_ids": {
            "preview": (state.get("preview") or {}).get("task_id"),
            "refine": (state.get("refine") or {}).get("task_id"),
            "rig": (state.get("rig") or {}).get("task_id"),
        },
        "credits": sum(int((state.get(s) or {}).get("credits") or 0)
                       for s in ("preview", "refine", "rig")),
        "generated_at": utc_now_iso(),
    }
    p = _resolve_slug_dir(cfg, slug) / "meta.json"
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(json.dumps(meta, indent=2) + "\n", encoding="utf-8")


# --------------------------------------------------------------------------- #
# Download parsing
# --------------------------------------------------------------------------- #

def _normalize_texture_key(name) -> str:
    key = re.sub(r"[^a-z0-9]+", "_", str(name).lower()).strip("_")
    return key if key in TEXTURE_KEYS else None


def iter_texture_files(texture_urls):
    """Yield (key, url) pairs from Meshy's `texture_urls` payload.

    Meshy returns a list of dicts. Each dict is either {"name": "base_color",
    "url": ...} or carries the texture type directly as a key. We accept both and
    normalise to our fixed key set.
    """
    for tex in texture_urls or []:
        if not isinstance(tex, dict):
            continue
        name = tex.get("name")
        url = tex.get("url")
        if name and url:
            key = _normalize_texture_key(name)
            if key:
                yield key, url
            continue
        for key in TEXTURE_KEYS:
            url = tex.get(key)
            if url:
                yield key, url


def iter_animation_files(basic_animations):
    """Yield (filename, url) pairs for the free walk/run clips.

    Meshy's rig `result.basic_animations` is an OBJECT (not a list) keyed by
    walking_fbx_url / walking_glb_url / running_fbx_url / running_glb_url (plus
    optional *_armature_glb_url keys, which the spec's output layout skips). The
    spec requires walk.fbx / walk.glb / run.fbx / run.glb on disk.
    """
    anims = basic_animations or {}
    for dest, key in (("walk.fbx", "walking_fbx_url"),
                      ("walk.glb", "walking_glb_url"),
                      ("run.fbx", "running_fbx_url"),
                      ("run.glb", "running_glb_url")):
        url = anims.get(key)
        if url:
            yield dest, url


# --------------------------------------------------------------------------- #
# Stage runners
# --------------------------------------------------------------------------- #

def _stage_already_done(state, stage, cfg, slug):
    """Return True if the stage is already complete and its key outputs exist."""
    rec = state.get(stage) or {}
    if rec.get("status") != "SUCCEEDED":
        return False
    if stage == "refine":
        return (_resolve_slug_dir(cfg, slug) / "_source" / "model.glb").exists()
    if stage == "rig":
        return (_resolve_slug_dir(cfg, slug) / "_source" / "rigged" / "rigged_character.glb").exists()
    return True  # preview has no downloads


def run_preview(client: MeshyClient, char: dict, cfg) -> dict:
    slug = char["slug"]
    state = load_state(cfg, slug)
    rec = state.get("preview") or {}
    task_id = rec.get("task_id")

    if rec.get("status") == "SUCCEEDED":
        log.info("%s: preview already succeeded (%s) — skipping", slug, task_id)
        return {"stage": "preview", "status": "skipped", "task_id": task_id, "credits": 0, "note": None}
    if rec.get("status") == "FAILED":
        log.warning("%s: preview previously FAILED — not auto-retrying; delete its state entry to force a re-run", slug)
        return {"stage": "preview", "status": "failed", "task_id": task_id, "credits": 0, "note": "previously failed"}

    if not task_id:
        task_id = client.create_task(TEXT_TO_3D_URL, build_preview_payload(char))
        state["preview"] = {"task_id": task_id, "status": "PENDING"}
        save_state(cfg, slug, state)
        log.info("%s: preview task %s created", slug, task_id)
    else:
        log.info("%s: resuming preview task %s", slug, task_id)

    data = client.poll_until_terminal(TEXT_TO_3D_URL, task_id, cfg.poll_interval, cfg.timeout, "preview")
    status = data.get("status")
    credits = int(data.get("consumed_credits") or 0)
    state["preview"] = {"task_id": task_id, "status": status, "credits": credits}
    save_state(cfg, slug, state)

    if status != "SUCCEEDED":
        raise RuntimeError(f"preview {task_id} ended with status {status}")
    log.info("%s: preview SUCCEEDED (%s)", slug, task_id)
    return {"stage": "preview", "status": "succeeded", "task_id": task_id, "credits": credits, "note": None}


def run_refine(client: MeshyClient, char: dict, cfg) -> dict:
    slug = char["slug"]
    state = load_state(cfg, slug)
    preview_rec = state.get("preview") or {}
    preview_task_id = preview_rec.get("task_id")

    if preview_rec.get("status") != "SUCCEEDED" or not preview_task_id:
        raise RuntimeError("preview has not succeeded yet — run `--stage preview` first")

    rec = state.get("refine") or {}
    refine_task_id = rec.get("task_id")

    if rec.get("status") == "SUCCEEDED":
        if _stage_already_done(state, "refine", cfg, slug):
            log.info("%s: refine already succeeded (%s) — skipping", slug, refine_task_id)
            return {"stage": "refine", "status": "skipped", "task_id": refine_task_id, "credits": 0, "note": None}
        log.warning("%s: refine marked SUCCEEDED but output files are missing — delete its state entry to re-run", slug)
        return {"stage": "refine", "status": "failed", "task_id": refine_task_id, "credits": 0, "note": "files missing"}
    if rec.get("status") == "FAILED":
        log.warning("%s: refine previously FAILED — not auto-retrying", slug)
        return {"stage": "refine", "status": "failed", "task_id": refine_task_id, "credits": 0, "note": "previously failed"}

    if not refine_task_id:
        refine_task_id = client.create_task(TEXT_TO_3D_URL, build_refine_payload(char, preview_task_id))
        state["refine"] = {"task_id": refine_task_id, "status": "PENDING"}
        save_state(cfg, slug, state)
        log.info("%s: refine task %s created", slug, refine_task_id)
    else:
        log.info("%s: resuming refine task %s", slug, refine_task_id)

    data = client.poll_until_terminal(TEXT_TO_3D_URL, refine_task_id, cfg.poll_interval, cfg.timeout, "refine")
    status = data.get("status")
    credits = int(data.get("consumed_credits") or 0)

    if status != "SUCCEEDED":
        state["refine"] = {"task_id": refine_task_id, "status": status, "credits": credits}
        save_state(cfg, slug, state)
        raise RuntimeError(f"refine {refine_task_id} ended with status {status}")

    download_refine_outputs(char, data, cfg)
    state["refine"] = {"task_id": refine_task_id, "status": "SUCCEEDED", "credits": credits}
    save_state(cfg, slug, state)
    log.info("%s: refine SUCCEEDED (%d credits)", slug, credits)
    return {"stage": "refine", "status": "succeeded", "task_id": refine_task_id, "credits": credits, "note": None}


def download_refine_outputs(char: dict, data: dict, cfg) -> None:
    slug = char["slug"]
    asset_dir = _resolve_slug_dir(cfg, slug)
    source_dir = asset_dir / "_source"

    model_urls = data.get("model_urls") or {}
    for fmt in ("glb", "usdz"):
        url = model_urls.get(fmt)
        if not url:
            log.warning("%s: no '%s' URL in refine response", slug, fmt)
            continue
        _download_verified(url, source_dir / f"model.{fmt}", slug)

    for key, url in iter_texture_files(data.get("texture_urls")):
        _download_verified(url, source_dir / "textures" / f"{key}.png", slug)

    if not char["is_humanoid"]:
        # For the non-humanoid mascot, the refine-stage USDZ *is* the final asset —
        # promote it to the top-level model.usdz that gets dragged into Xcode.
        src = source_dir / "model.usdz"
        if src.exists():
            shutil.copy2(src, asset_dir / "model.usdz")
            log.info("%s: refine USDZ promoted to model.usdz (non-humanoid)", slug)
        else:
            log.warning("%s: no refine USDZ available to promote to model.usdz", slug)


def run_rig(client: MeshyClient, char: dict, cfg) -> dict:
    slug = char["slug"]

    # Meshy's auto-rig is unsuitable for non-humanoid assets — skip entirely.
    if not char["is_humanoid"]:
        log.info("%s: static model only, no rig attempted (non-humanoid)", slug)
        return {"stage": "rig", "status": "skipped", "task_id": None, "credits": 0, "note": "non-humanoid"}

    state = load_state(cfg, slug)
    refine_rec = state.get("refine") or {}
    refine_task_id = refine_rec.get("task_id")

    if refine_rec.get("status") != "SUCCEEDED" or not refine_task_id:
        raise RuntimeError("refine has not succeeded yet — run `--stage refine` first")

    rec = state.get("rig") or {}
    rig_task_id = rec.get("task_id")

    if rec.get("status") == "SUCCEEDED":
        if _stage_already_done(state, "rig", cfg, slug):
            log.info("%s: rig already succeeded (%s) — skipping", slug, rig_task_id)
            return {"stage": "rig", "status": "skipped", "task_id": rig_task_id, "credits": 0, "note": None}
        log.warning("%s: rig marked SUCCEEDED but output files are missing — delete its state entry to re-run", slug)
        return {"stage": "rig", "status": "failed", "task_id": rig_task_id, "credits": 0, "note": "files missing"}
    if rec.get("status") == "FAILED":
        log.warning("%s: rig previously FAILED — not auto-retrying", slug)
        return {"stage": "rig", "status": "failed", "task_id": rig_task_id, "credits": 0, "note": "previously failed"}

    if not rig_task_id:
        try:
            rig_task_id = client.create_task(RIGGING_URL, build_rig_payload(char, refine_task_id))
        except requests.HTTPError as exc:
            if exc.response is not None and exc.response.status_code == 422:
                log.warning(
                    "%s: rigging failed — mesh may not have had a clean a-pose/T-pose silhouette, "
                    "consider re-running preview with a more explicit standing a-pose description", slug)
                return {"stage": "rig", "status": "failed", "task_id": None, "credits": 0,
                        "note": "422 pose-estimation failed"}
            raise
        state["rig"] = {"task_id": rig_task_id, "status": "PENDING"}
        save_state(cfg, slug, state)
        log.info("%s: rig task %s created", slug, rig_task_id)
    else:
        log.info("%s: resuming rig task %s", slug, rig_task_id)

    data = client.poll_until_terminal(RIGGING_URL, rig_task_id, cfg.poll_interval, cfg.timeout, "rig")
    status = data.get("status")
    credits = int(data.get("consumed_credits") or 0)

    if status != "SUCCEEDED":
        state["rig"] = {"task_id": rig_task_id, "status": status, "credits": credits}
        save_state(cfg, slug, state)
        raise RuntimeError(f"rig {rig_task_id} ended with status {status}")

    download_rig_outputs(char, data, cfg)
    state["rig"] = {"task_id": rig_task_id, "status": "SUCCEEDED", "credits": credits}
    save_state(cfg, slug, state)
    log.info("%s: rig SUCCEEDED (%d credits)", slug, credits)
    print_usdz_instruction(slug, cfg)
    return {"stage": "rig", "status": "succeeded", "task_id": rig_task_id, "credits": credits, "note": None}


def download_rig_outputs(char: dict, data: dict, cfg) -> None:
    slug = char["slug"]
    rig_dir = _resolve_slug_dir(cfg, slug) / "_source" / "rigged"
    # The rigging task object nests its outputs under a "result" object.
    result = data.get("result") or {}

    for ext, key in (("fbx", "rigged_character_fbx_url"),
                     ("glb", "rigged_character_glb_url")):
        url = result.get(key)
        if url:
            _download_verified(url, rig_dir / f"rigged_character.{ext}", slug)
        else:
            log.warning("%s: no %s in rig response", slug, key)

    for filename, url in iter_animation_files(result.get("basic_animations")):
        _download_verified(url, rig_dir / filename, slug)


def print_usdz_instruction(slug: str, cfg) -> None:
    print()
    print("─" * 68)
    print(f"  {slug}: rigged character downloaded (FBX + GLB + walk/run clips).")
    print("  Meshy's rigging endpoint does not return a USDZ.")
    print("  To get a RealityKit-ready USDZ for the rigged mesh, convert the FBX locally:")
    print(f"    1. Open Apple's Reality Converter and drag in:")
    print(f"         CharacterAssets/{slug}/_source/rigged/rigged_character.fbx")
    print(f"    2. Export as USDZ to:")
    print(f"         CharacterAssets/{slug}/model.usdz")
    print("       (or use `usdzconvert` if you have the USD Python tools installed)")
    print("  Basic walk/run included. For additional animations, browse the Animation")
    print("  Library reference, note the action_id you want, and I can add a")
    print("  --animate <slug> <action_id> flag on request.")
    print("─" * 68)


def run_stage(client: MeshyClient, char: dict, stage: str, cfg) -> dict:
    """Dispatch one stage; convert any unexpected error into a failed result."""
    runner = {"preview": run_preview, "refine": run_refine, "rig": run_rig}[stage]
    try:
        return runner(client, char, cfg)
    except Exception as exc:  # noqa: BLE001 — per-stage isolation
        note = sanitize_error(str(exc))
        log.error("%s / %s: %s", char["slug"], stage, note)
        return {"stage": stage, "status": "failed", "task_id": None, "credits": 0, "note": note}


# --------------------------------------------------------------------------- #
# Character config loading
# --------------------------------------------------------------------------- #

# A slug is used directly as a directory name under the output root, so it must
# be a single safe path segment (no separators, no "..", no leading dot).
_SLUG_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*$")


def _clean_char(c: dict) -> dict:
    return {
        "slug": c["slug"].strip(),
        "name": (c.get("name") or c["slug"]).strip(),
        "is_humanoid": bool(c["is_humanoid"]),
        "height_meters": float(c["height_meters"]),
        "preview_prompt": c["preview_prompt"].strip(),
        "texture_prompt": c["texture_prompt"].strip(),
    }


def load_characters(path: str) -> list:
    p = Path(path)
    if not p.exists():
        p.write_text(json.dumps(DEFAULT_CHARACTERS, indent=2) + "\n", encoding="utf-8")
        log.info("wrote default characters.json (%d characters)", len(DEFAULT_CHARACTERS))
    try:
        data = json.loads(p.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        raise SystemExit(f"characters.json is not valid JSON: {exc}") from exc

    if not isinstance(data, list) or not data:
        raise SystemExit("characters.json must be a non-empty JSON list")

    seen = set()
    cleaned = []
    for i, c in enumerate(data):
        if not isinstance(c, dict):
            raise SystemExit(f"characters.json[{i}] is not an object")
        slug = (c.get("slug") or "").strip()
        if not slug:
            raise SystemExit(f"characters.json[{i}]: missing 'slug'")
        if slug in seen:
            raise SystemExit(f"characters.json: duplicate slug '{slug}'")
        if not _SLUG_RE.match(slug):
            raise SystemExit(
                f"character '{slug}': 'slug' must be a single safe path segment "
                f"(a-z, 0-9, '.', '_', '-')"
            )
        seen.add(slug)
        if not isinstance(c.get("is_humanoid"), bool):
            raise SystemExit(f"character '{slug}': 'is_humanoid' must be true/false")
        if not isinstance(c.get("height_meters"), (int, float)) or c["height_meters"] <= 0:
            raise SystemExit(f"character '{slug}': 'height_meters' must be a positive number")
        if not (c.get("preview_prompt") or "").strip():
            raise SystemExit(f"character '{slug}': missing 'preview_prompt'")
        if not (c.get("texture_prompt") or "").strip():
            raise SystemExit(f"character '{slug}': missing 'texture_prompt'")
        cleaned.append(_clean_char(c))
    return cleaned


def filter_characters(characters: list, slugs: str) -> list:
    if not slugs:
        return characters
    wanted = [s.strip() for s in slugs.split(",") if s.strip()]
    by_slug = {c["slug"]: c for c in characters}
    missing = [s for s in wanted if s not in by_slug]
    if missing:
        raise SystemExit(f"unknown character slug(s): {missing}. Available: {sorted(by_slug)}")
    return [by_slug[s] for s in wanted]


# --------------------------------------------------------------------------- #
# Dry-run
# --------------------------------------------------------------------------- #

def print_dry_run(characters: list, args) -> None:
    print("DRY RUN — no API calls will be made.\n")
    print(f"  characters.json:    {args.characters_file}  ({len(characters)} selected)")
    print(f"  stage:              {args.stage}")
    print(f"  concurrency:        {args.concurrency}")
    print(f"  output root:        {args.output}")
    print(f"  poll interval:      {args.poll_interval}s")
    print(f"  per-stage timeout:  {args.timeout}s")
    print(f"  MESHY_API_KEY:      {'set' if args.api_key_set else 'NOT SET (required for a real run)'}")
    print("\nSHARED STYLE SUFFIX (appended verbatim to every prompt below):")
    print(f"  {STYLE_SUFFIX}\n")

    for i, c in enumerate(characters, start=1):
        print("=" * 68)
        print(f"[{i}/{len(characters)}] {c['slug']} — {c['name']}")
        print(f"  is_humanoid:  {c['is_humanoid']}")
        print(f"  height:       {c['height_meters']} m")
        print(f"  polycount:    {40000 if c['is_humanoid'] else 15000}")
        print(f"  pose_mode:    {'a-pose' if c['is_humanoid'] else '(omitted — non-humanoid)'}")
        print(f"  rigging:      {'yes (humanoid)' if c['is_humanoid'] else 'SKIPPED (non-humanoid)'}")
        print("  ── STAGE 1 · PREVIEW prompt ──")
        print(f"  {build_preview_prompt(c)}")
        print("  ── STAGE 2 · REFINE texture_prompt (truncated to 600 chars) ──")
        print(f"  {build_texture_prompt(c)}")
        print()

    print("REMINDER: check current Meshy pricing before a real run.")
    print("Run `python3 meshy_characters.py --stage preview` (or omit --stage) to start spending credits.")


# --------------------------------------------------------------------------- #
# Summary / manifest / run log
# --------------------------------------------------------------------------- #

def _stage_cell(state: dict, stage: str) -> str:
    rec = state.get(stage) or {}
    return rec.get("status") or "—"


def print_summary(characters: list, cfg) -> None:
    print()
    print("=" * 68)
    print("SUMMARY")
    print("=" * 68)
    header = (f"{'slug':<16}{'name':<16}{'preview':<11}{'refine':<11}{'rig':<11}{'credits':>8}")
    print(header)
    print("-" * len(header))
    for c in characters:
        state = load_state(cfg, c["slug"])
        credits = sum(int((state.get(s) or {}).get("credits") or 0)
                      for s in ("preview", "refine", "rig"))
        rig_cell = "—" if not c["is_humanoid"] else _stage_cell(state, "rig")
        print(f"{c['slug']:<16}{c['name']:<16}{_stage_cell(state, 'preview'):<11}"
              f"{_stage_cell(state, 'refine'):<11}{rig_cell:<11}{credits:>8}")
    print()


def write_run_log(results: list, cfg) -> None:
    run_log = cfg.output / "run_log.csv"
    write_header = not run_log.exists()
    ts = utc_now_iso()
    with run_log.open("a", newline="", encoding="utf-8") as fh:
        writer = csv.writer(fh)
        if write_header:
            writer.writerow(["timestamp", "slug", "name", "stage", "status", "task_id", "credits", "note"])
        for r in results:
            writer.writerow([ts, r["slug"], r["name"], r["stage"], r["status"],
                             r["task_id"] or "", r["credits"], r["note"] or ""])


def write_manifest(characters: list, cfg) -> None:
    manifest = {"generated_at": utc_now_iso(), "style_suffix": STYLE_SUFFIX, "characters": {}}
    for c in characters:
        state = load_state(cfg, c["slug"])
        manifest["characters"][c["slug"]] = {
            "name": c["name"],
            "is_humanoid": c["is_humanoid"],
            "preview": state.get("preview") or None,
            "refine": state.get("refine") or None,
            "rig": state.get("rig") or None,
            "credits": sum(int((state.get(s) or {}).get("credits") or 0)
                           for s in ("preview", "refine", "rig")),
        }
    (cfg.output / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")


def print_preview_reminder(characters: list) -> None:
    print()
    print("=" * 68)
    print("PREVIEW STAGE COMPLETE — review before continuing")
    print("=" * 68)
    print("Review the previews side by side (in the Meshy web UI) for style consistency.")
    print("This is the only real consistency check available — Meshy has no shared")
    print("style/seed across independent generations.")
    print()
    print("If one character reads off-style:")
    print("  - tweak that character's preview_prompt in characters.json (NOT the shared")
    print("    STYLE_SUFFIX)")
    print("  - delete CharacterAssets/<slug>/state.json (or just its 'preview' entry)")
    print("  - re-run:  python3 meshy_characters.py --characters <slug> --stage preview")
    print()
    print("When all four look consistent, run the expensive/slow stages:")
    print("  python3 meshy_characters.py --stage refine")
    print("  python3 meshy_characters.py --stage rig")
    print("=" * 68)


# --------------------------------------------------------------------------- #
# Main
# --------------------------------------------------------------------------- #

def parse_args(argv):
    p = argparse.ArgumentParser(
        description="Generate a stylistically-consistent set of cartoony 3D characters via Meshy.ai.",
    )
    p.add_argument("--dry-run", action="store_true",
                   help="Validate characters.json and print the planned prompts without calling the API")
    p.add_argument("--stage", choices=["preview", "refine", "rig", "all"], default="all",
                   help="Which stage to run (default: all — runs preview then stops for review)")
    p.add_argument("--characters", default=None,
                   help="Comma-separated slug subset, e.g. 'rango' or 'kwame,elin' (default: all)")
    p.add_argument("--characters-file", default="characters.json",
                   help="Path to characters.json (default: characters.json)")
    p.add_argument("--concurrency", type=int, default=1,
                   help="Concurrent characters (default: 1, sequential)")
    p.add_argument("--poll-interval", type=float, default=5.0,
                   help="Seconds between polls (default: 5)")
    p.add_argument("--timeout", type=float, default=600.0,
                   help="Per-stage timeout in seconds (default: 600)")
    p.add_argument("--output", default="./CharacterAssets",
                   help="Output root (default: ./CharacterAssets)")
    return p.parse_args(argv)


def resolve_stages(stage: str) -> list:
    # 'all' is the default and, per the credit-safety design, stops after preview
    # so the four previews can be reviewed before refine + rig are approved.
    if stage in ("preview", "all"):
        return ["preview"]
    return [stage]


def process_character(api_key: str, char: dict, stages: list, cfg) -> dict:
    """Run one character through its stages. Never raises; returns a result dict."""
    client = MeshyClient(api_key)
    results = []
    credits = 0
    for stage in stages:
        res = run_stage(client, char, stage, cfg)
        results.append(res)
        credits += res["credits"]
        log.info("%s / %s: %s (stage +%d credits)", char["slug"], stage, res["status"], res["credits"])
    write_meta(char, load_state(cfg, char["slug"]), cfg)
    return {"slug": char["slug"], "name": char["name"], "results": results, "credits": credits}


def main(argv=None) -> int:
    args = parse_args(argv)
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)-7s %(message)s", datefmt="%H:%M:%S")

    if args.concurrency < 1:
        raise SystemExit("--concurrency must be >= 1")
    if args.poll_interval <= 0:
        raise SystemExit("--poll-interval must be > 0")
    if args.timeout <= 0:
        raise SystemExit("--timeout must be > 0")

    characters = load_characters(args.characters_file)
    characters = filter_characters(characters, args.characters)

    args.output = Path(args.output)
    args.api_key_set = bool(os.environ.get("MESHY_API_KEY"))

    if args.dry_run:
        print_dry_run(characters, args)
        return 0

    api_key = os.environ.get("MESHY_API_KEY")
    if not api_key:
        log.error("MESHY_API_KEY environment variable is not set. Export it and re-run.")
        return 1

    stages = resolve_stages(args.stage)
    args.output.mkdir(parents=True, exist_ok=True)
    cfg = argparse.Namespace(
        output=args.output,
        poll_interval=args.poll_interval,
        timeout=args.timeout,
    )

    print()
    print("=" * 68)
    print(f"  characters: {', '.join(c['slug'] for c in characters)}")
    print(f"  stage:      {' -> '.join(stages)}")
    print(f"  concurrency {args.concurrency} — CREDITS WILL BE SPENT")
    print("=" * 68)

    all_results = []
    run_credits = 0

    def on_done(r):
        nonlocal run_credits
        run_credits += r["credits"]
        for res in r["results"]:
            res["slug"] = r["slug"]
            res["name"] = r["name"]
            all_results.append(res)
        log.info("running total: %d credit(s) spent this run", run_credits)

    if args.concurrency == 1:
        for char in characters:
            on_done(process_character(api_key, char, stages, cfg))
    else:
        with ThreadPoolExecutor(max_workers=args.concurrency) as ex:
            futures = {ex.submit(process_character, api_key, c, stages, cfg): c for c in characters}
            for fut in as_completed(futures):
                on_done(fut.result())

    write_run_log(all_results, cfg)
    write_manifest(characters, cfg)
    print_summary(characters, cfg)

    if args.stage in ("all", "preview"):
        print_preview_reminder(characters)

    return 0 if all(r["status"] in ("succeeded", "skipped") for r in all_results) else 1


if __name__ == "__main__":
    sys.exit(main())
