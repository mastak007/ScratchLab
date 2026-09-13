#!/usr/bin/env python3
"""Batch-generate 3D models from Meshy.ai's Text-to-3D API (v2) and download them
in formats suitable for a SceneKit / RealityKit iOS project.

API contract (docs.meshy.ai/en/api/text-to-3d):
  - Base:      https://api.meshy.ai/openapi/v2/text-to-3d
  - Auth:      Authorization: Bearer $MESHY_API_KEY
  - Preview:   POST /openapi/v2/text-to-3d  {"mode": "preview", ...}
  - Refine:    POST /openapi/v2/text-to-3d  {"mode": "refine", "preview_task_id": ...}
  - Poll:      GET  /openapi/v2/text-to-3d/{id}
"""

import argparse
import base64
import csv
import json
import logging
import os
import re
import sys
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime, timezone
from pathlib import Path

import requests

API_BASE = "https://api.meshy.ai/openapi/v2/text-to-3d"
IMAGE_API_BASE = "https://api.meshy.ai/openapi/v1/image-to-3d"
MULTI_IMAGE_API_BASE = "https://api.meshy.ai/openapi/v1/multi-image-to-3d"
VALID_AI_MODELS = ("meshy-5", "meshy-6", "meshy-7", "latest")
IMAGE_MIME = {".png": "image/png", ".jpg": "image/jpeg", ".jpeg": "image/jpeg", ".webp": "image/webp"}
TEXTURE_KEYS = ("base_color", "metallic", "roughness", "normal", "emission")
VALID_TEXTURE_RESOLUTIONS = ("2k", "4k", "8k")
VALID_FORMATS = {"glb", "fbx", "obj", "usdz", "stl", "3mf"}
MIN_FILE_BYTES = 1024  # a truncated download is worse than a clear failure
PRICING_URL = "https://www.meshy.ai/pricing"

log = logging.getLogger("meshy_batch")


# --------------------------------------------------------------------------- #
# Small helpers
# --------------------------------------------------------------------------- #

def slugify(text: str) -> str:
    """Lowercase, spaces -> hyphens, strip punctuation, truncate to 40 chars."""
    slug = text.lower()
    slug = re.sub(r"\s+", "-", slug)            # spaces (and other whitespace) -> hyphen
    slug = re.sub(r"[^a-z0-9-]", "", slug)      # strip remaining punctuation
    slug = re.sub(r"-+", "-", slug)             # collapse repeated hyphens
    slug = slug.strip("-")                      # trim leading/trailing hyphens
    slug = slug[:40].rstrip("-")                # truncate, re-trim trailing hyphen
    return slug


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
    out of log lines, manifest.json, and run_log.csv. Applied defensively on top
    of download_url's own redaction.
    """
    return _URL_RE.sub(lambda m: m.group(0).split("?")[0], msg)


def _unique_slug(base: str, used: set) -> str:
    candidate = base
    n = 2
    while candidate in used:
        candidate = f"{base}-{n}"
        n += 1
    used.add(candidate)
    return candidate


def image_to_data_uri(path_or_url: str) -> str:
    """Return a base64 data URI for a local image, or pass through http(s) URLs.

    Meshy's image_url / image_urls fields accept a public URL or a base64 data
    URI. Encoding local files as a data URI means the reference photo never has
    to be hosted somewhere public.
    """
    if re.match(r"^https?://", path_or_url, re.IGNORECASE):
        return path_or_url
    p = Path(path_or_url)
    if not p.exists():
        raise RuntimeError(f"image file not found: {p}")
    mime = IMAGE_MIME.get(p.suffix.lower(), "image/png")
    data = base64.b64encode(p.read_bytes()).decode("ascii")
    return f"data:{mime};base64,{data}"


# --------------------------------------------------------------------------- #
# API client
# --------------------------------------------------------------------------- #

class MeshyClient:
    def __init__(self, api_key: str, base_url: str = API_BASE):
        self.session = requests.Session()
        self.session.headers["Authorization"] = f"Bearer {api_key}"
        self.base_url = base_url

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
                log.warning("network error (%s); retrying in %.0fs (%d/%d)", exc, wait, attempt, retries)
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

            resp.raise_for_status()
            return resp

    def create_task(self, payload: dict) -> str:
        resp = self._request("POST", self.base_url, json=payload)
        data = resp.json()
        task_id = data.get("result")
        if not task_id:
            raise RuntimeError(f"create task returned no 'result': {data}")
        return task_id

    def get_task(self, task_id: str) -> dict:
        resp = self._request("GET", f"{self.base_url}/{task_id}")
        return resp.json()

    def poll_until_terminal(self, task_id: str, poll_interval: float, timeout: float, stage: str) -> dict:
        """Poll until SUCCEEDED / FAILED / CANCELED, or raise TimeoutError."""
        deadline = time.monotonic() + timeout
        while True:
            data = self.get_task(task_id)
            status = data.get("status")
            if status in ("SUCCEEDED", "FAILED", "CANCELED"):
                return data
            if time.monotonic() >= deadline:
                raise TimeoutError(f"{stage} task {task_id} did not finish within {timeout:.0f}s")
            time.sleep(poll_interval)


def download_url(url: str, dest: Path, retries: int = 3) -> int:
    """Download a (signed) URL to disk WITHOUT the auth header, with retry/backoff.

    Signed model/texture URLs are served by a CDN; we deliberately do not attach
    the Authorization header here so the API key is never sent to that host.
    Returns the number of bytes written. Errors are raised with the URL's query
    string stripped so signed credentials never reach logs or persisted output.
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


# --------------------------------------------------------------------------- #
# Per-asset processing
# --------------------------------------------------------------------------- #

def _download_verified(url: str, dest: Path, slug: str) -> None:
    size = download_url(url, dest)
    if size <= MIN_FILE_BYTES:
        raise RuntimeError(f"{dest.name} for {slug} too small ({size} bytes) — possible truncation")


def _download_model_and_textures(task_data: dict, formats: list, slug: str, asset_dir: Path) -> int:
    """Download model_urls + texture_urls from a SUCCEEDED task into asset_dir.

    Returns consumed_credits (int). Shared by the text and image pipelines.
    """
    source_dir = asset_dir / "_source"
    credits = int(task_data.get("consumed_credits") or 0)
    model_urls = task_data.get("model_urls") or {}
    if "usdz" in formats and not model_urls.get("usdz"):
        raise RuntimeError("usdz requested but absent from model_urls")
    for fmt in formats:
        url = model_urls.get(fmt)
        if not url:
            log.warning("no '%s' URL in response for %s", fmt, slug)
            continue
        dest = (asset_dir / "model.usdz") if fmt == "usdz" else (source_dir / f"model.{fmt}")
        _download_verified(url, dest, slug)
    texture_urls = task_data.get("texture_urls") or []
    for tex in texture_urls:
        if not isinstance(tex, dict):
            continue
        for key in TEXTURE_KEYS:
            url = tex.get(key)
            if not url:
                continue
            _download_verified(url, source_dir / "textures" / f"{key}.png", slug)
    return credits


def write_manifest(output: Path, results: list) -> None:
    """Merge this run's results into manifest.json, keyed by slug (upsert).

    Preserves entries from previous runs (and any other tool that wrote the same
    file), so manifest.json accumulates into a rolling index instead of being
    overwritten each run.
    """
    manifest_path = output / "manifest.json"
    index = {}
    if manifest_path.exists():
        try:
            data = json.loads(manifest_path.read_text(encoding="utf-8"))
            if isinstance(data, list):
                index = {e.get("slug"): e for e in data if isinstance(e, dict)}
        except (json.JSONDecodeError, TypeError, OSError):
            index = {}
    for r in results:
        index[r["slug"]] = {
            "name": r["name"],
            "slug": r["slug"],
            "status": r["status"],
            "local_usdz_path": r["local_usdz"],
            "consumed_credits": r["credits"],
            "error": r["error"],
        }
    manifest_path.write_text(json.dumps([index[k] for k in sorted(index)], indent=2) + "\n", encoding="utf-8")


def process_asset(cfg, api_key: str, item: dict, total: int) -> dict:
    """Run one asset end-to-end. Never raises; returns a result dict."""
    index, name, prompt, slug = item["index"], item["name"], item["prompt"], item["slug"]
    result = {
        "index": index,
        "name": name or slug,
        "slug": slug,
        "status": "failed",
        "credits": 0,
        "local_usdz": None,
        "error": None,
    }
    client = MeshyClient(api_key)
    try:
        # 1) Preview
        preview_id = client.create_task({
            "mode": "preview",
            "prompt": prompt,
            "should_remesh": True,
            "target_polycount": cfg.polycount,
            "topology": "triangle",
        })
        log.info("[%d/%d] %s: preview %s", index, total, slug, preview_id)
        preview = client.poll_until_terminal(preview_id, cfg.poll_interval, cfg.timeout, "preview")
        if preview.get("status") != "SUCCEEDED":
            # Never retry a FAILED/CANCELED task — log and move on.
            raise RuntimeError(f"preview {preview_id} ended with status {preview.get('status')}")

        # 2) Refine
        refine_id = client.create_task({
            "mode": "refine",
            "preview_task_id": preview_id,
            "enable_pbr": True,
            "texture_resolution": cfg.texture_resolution,
            "target_formats": cfg.formats,
        })
        log.info("[%d/%d] %s: refine %s", index, total, slug, refine_id)
        refine = client.poll_until_terminal(refine_id, cfg.poll_interval, cfg.timeout, "refine")
        if refine.get("status") != "SUCCEEDED":
            raise RuntimeError(f"refine {refine_id} ended with status {refine.get('status')}")

        # 3) Download immediately (Meshy retains files ~3 days).
        asset_dir = cfg.output / slug
        credits = _download_model_and_textures(refine, cfg.formats, slug, asset_dir)

        # 4) Metadata
        meta = {
            "name": name or None,
            "slug": slug,
            "prompt": prompt,
            "preview_task_id": preview_id,
            "refine_task_id": refine_id,
            "consumed_credits": credits,
            "polycount": cfg.polycount,
            "texture_resolution": cfg.texture_resolution,
            "formats": cfg.formats,
            "generated_at": utc_now_iso(),
        }
        (asset_dir / "meta.json").write_text(json.dumps(meta, indent=2) + "\n", encoding="utf-8")

        result.update(
            status="succeeded",
            credits=credits,
            local_usdz=str(asset_dir / "model.usdz") if "usdz" in cfg.formats else None,
        )
        log.info("[%d/%d] %s: done (%d credits)", index, total, slug, credits)
    except Exception as exc:  # noqa: BLE001 — per-asset isolation: one failure must not kill the batch
        result["error"] = sanitize_error(str(exc))
        log.error("[%d/%d] %s: FAILED — %s", index, total, slug, result["error"])
    return result


def process_asset_image(cfg, api_key: str, item: dict, total: int) -> dict:
    """Run one image-to-3d asset end-to-end (single- or multi-view). Never raises."""
    index, name, slug = item["index"], item["name"], item["slug"]
    images = item["images"]
    result = {
        "index": index,
        "name": name or slug,
        "slug": slug,
        "status": "failed",
        "credits": 0,
        "local_usdz": None,
        "error": None,
    }
    multi = len(images) > 1
    base_url = MULTI_IMAGE_API_BASE if multi else IMAGE_API_BASE
    client = MeshyClient(api_key, base_url)
    try:
        payload = {
            "ai_model": cfg.ai_model,
            "should_texture": True,
            "enable_pbr": True,
            "texture_resolution": cfg.texture_resolution,
            "should_remesh": True,
            "topology": "triangle",
            "target_polycount": cfg.polycount,
            "target_formats": cfg.formats,
        }
        if multi:
            payload["image_urls"] = [image_to_data_uri(i) for i in images]
        else:
            payload["image_url"] = image_to_data_uri(images[0])

        task_id = client.create_task(payload)
        log.info("[%d/%d] %s: image task %s (%s)", index, total, slug, task_id,
                 "multi-view" if multi else "single-view")
        task = client.poll_until_terminal(task_id, cfg.poll_interval, cfg.timeout, "image")
        if task.get("status") != "SUCCEEDED":
            raise RuntimeError(f"image task {task_id} ended with status {task.get('status')}")

        asset_dir = cfg.output / slug
        credits = _download_model_and_textures(task, cfg.formats, slug, asset_dir)

        meta = {
            "name": name or None,
            "slug": slug,
            "mode": "image",
            "images": images,
            "task_id": task_id,
            "consumed_credits": credits,
            "polycount": cfg.polycount,
            "texture_resolution": cfg.texture_resolution,
            "ai_model": cfg.ai_model,
            "formats": cfg.formats,
            "generated_at": utc_now_iso(),
        }
        (asset_dir / "meta.json").write_text(json.dumps(meta, indent=2) + "\n", encoding="utf-8")

        result.update(
            status="succeeded",
            credits=credits,
            local_usdz=str(asset_dir / "model.usdz") if "usdz" in cfg.formats else None,
        )
        log.info("[%d/%d] %s: done (%d credits)", index, total, slug, credits)
    except Exception as exc:  # noqa: BLE001
        result["error"] = sanitize_error(str(exc))
        log.error("[%d/%d] %s: FAILED — %s", index, total, slug, result["error"])
    return result


# --------------------------------------------------------------------------- #
# CSV / dry-run
# --------------------------------------------------------------------------- #

def read_csv(path: str) -> list:
    p = Path(path)
    if not p.exists():
        raise SystemExit(f"input CSV not found: {p}")
    with p.open(newline="", encoding="utf-8-sig") as fh:
        reader = csv.DictReader(fh)
        if reader.fieldnames is None:
            raise SystemExit(f"input CSV is empty: {p}")
        cleaned_fields = {fn.strip().lstrip("﻿").lower(): fn for fn in reader.fieldnames}
        if "prompt" not in cleaned_fields:
            raise SystemExit(f"input CSV missing a 'prompt' column; got {reader.fieldnames}")
        rows = []
        for line_no, raw in enumerate(reader, start=2):
            cleaned = {k.strip().lstrip("﻿").lower(): v for k, v in raw.items()}
            prompt = (cleaned.get("prompt") or "").strip()
            name = (cleaned.get("name") or "").strip()
            if prompt:
                rows.append({"name": name, "prompt": prompt, "line": line_no})
            else:
                log.warning("skipping line %d: empty prompt", line_no)
        return rows


IMAGE_COLUMNS = ("image", "image1", "image2", "image3", "image4")


def read_image_csv(path: str) -> list:
    """Read a CSV for image-to-3d: name + up to 4 image columns (image or image1..image4)."""
    p = Path(path)
    if not p.exists():
        raise SystemExit(f"input CSV not found: {p}")
    with p.open(newline="", encoding="utf-8-sig") as fh:
        reader = csv.DictReader(fh)
        if reader.fieldnames is None:
            raise SystemExit(f"input CSV is empty: {p}")
        rows = []
        for line_no, raw in enumerate(reader, start=2):
            cleaned = {k.strip().lstrip("﻿").lower(): v for k, v in raw.items()}
            name = (cleaned.get("name") or "").strip()
            images = []
            for col in IMAGE_COLUMNS:
                v = (cleaned.get(col) or "").strip()
                if v:
                    images.append(v)
            if images:
                rows.append({"name": name, "images": images, "line": line_no})
            else:
                log.warning("skipping line %d: no image path/URL", line_no)
        return rows


def slug_for(row: dict) -> str:
    if row.get("name"):
        return slugify(row["name"])
    if row.get("prompt"):
        return slugify(row["prompt"])
    images = row.get("images") or []
    if images:
        first = images[0]
        if re.match(r"^https?://", first, re.IGNORECASE):
            stem = Path(first.split("?")[0]).stem
        else:
            stem = Path(first).stem
        return slugify(stem)
    return ""


def print_dry_run(rows, formats, cfg, api_key_set):
    print("DRY RUN — no API calls will be made.\n")
    print(f"  Mode:               {cfg.mode}")
    print(f"  CSV:                {cfg.input}  ({len(rows)} row(s))")
    print(f"  Formats:            {', '.join(formats)}")
    print(f"  Texture resolution: {cfg.texture_resolution}")
    print(f"  Polycount:          {cfg.polycount}")
    if cfg.mode == "image":
        print(f"  AI model:           {cfg.ai_model}")
    print(f"  Concurrency:        {cfg.concurrency}")
    print(f"  Output root:        {cfg.output}")
    print(f"  MESHY_API_KEY:      {'set' if api_key_set else 'NOT SET (required for a real run)'}")
    print("\nPlanned batch:")
    used = set()
    for i, row in enumerate(rows, start=1):
        slug = _unique_slug(slug_for(row), used) or "asset"
        if row.get("prompt"):
            detail = row["prompt"]
        else:
            detail = f"images: {', '.join(row['images'])}"
        print(f"  {i:>3}. {slug:<42} {detail}")
    print("\nREMINDER: check current Meshy pricing at %s before running for real." % PRICING_URL)
    print("Run without --dry-run to start spending credits.")


# --------------------------------------------------------------------------- #
# Main
# --------------------------------------------------------------------------- #

def parse_args(argv):
    p = argparse.ArgumentParser(
        description="Batch-generate 3D models from the Meshy.ai Text-to-3D and Image-to-3D APIs.",
    )
    p.add_argument("--input", default="assets.csv", help="CSV input (default: assets.csv)")
    p.add_argument("--mode", choices=("text", "image"), default="text",
                   help="text: name,prompt CSV; image: name,image[1..4] CSV (default: text)")
    p.add_argument("--ai-model", default="meshy-6",
                   help="image mode only: meshy-5 / meshy-6 / meshy-7 / latest (default: meshy-6)")
    p.add_argument("--formats", default="usdz,glb", help="Comma list of target formats (default: usdz,glb)")
    p.add_argument("--texture-resolution", default="2k", help="2k, 4k, or 8k (default: 2k)")
    p.add_argument("--polycount", type=int, default=30000, help="target_polycount (default: 30000)")
    p.add_argument("--concurrency", type=int, default=1, help="Concurrent assets (default: 1)")
    p.add_argument("--limit", type=int, default=None, help="Process only the first N CSV rows")
    p.add_argument("--dry-run", action="store_true", help="Validate and print the plan without calling the API")
    p.add_argument("--poll-interval", type=float, default=5.0, help="Seconds between polls (default: 5)")
    p.add_argument("--timeout", type=float, default=600.0, help="Per-stage timeout in seconds (default: 600)")
    p.add_argument("--output", default="./MeshyAssets", help="Output root (default: ./MeshyAssets)")
    return p.parse_args(argv)


def main(argv=None) -> int:
    args = parse_args(argv)
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)-7s %(message)s", datefmt="%H:%M:%S")

    formats = [f.strip().lower() for f in args.formats.split(",") if f.strip()]
    if not formats:
        raise SystemExit("--formats resolved to an empty list")
    bad_fmt = [f for f in formats if f not in VALID_FORMATS]
    if bad_fmt:
        raise SystemExit(f"unsupported format(s) {bad_fmt}; valid: {sorted(VALID_FORMATS)}")
    args.formats = formats

    args.texture_resolution = args.texture_resolution.strip().lower()
    if args.texture_resolution not in VALID_TEXTURE_RESOLUTIONS:
        raise SystemExit(f"invalid --texture-resolution '{args.texture_resolution}'; choose 2k/4k/8k")
    if args.mode == "image" and args.ai_model not in VALID_AI_MODELS:
        raise SystemExit(f"invalid --ai-model '{args.ai_model}'; valid: {list(VALID_AI_MODELS)}")
    if args.polycount <= 0:
        raise SystemExit("--polycount must be positive")
    if args.concurrency < 1:
        raise SystemExit("--concurrency must be >= 1")
    if args.poll_interval <= 0:
        raise SystemExit("--poll-interval must be > 0")
    if args.timeout <= 0:
        raise SystemExit("--timeout must be > 0")

    if args.mode == "image":
        rows = read_image_csv(args.input)
        process_fn = process_asset_image
    else:
        rows = read_csv(args.input)
        process_fn = process_asset
    if args.limit is not None:
        rows = rows[: max(0, args.limit)]

    api_key = os.environ.get("MESHY_API_KEY")

    if args.dry_run:
        print_dry_run(rows, formats, args, bool(api_key))
        return 0

    if not api_key:
        log.error("MESHY_API_KEY environment variable is not set. Export it and re-run.")
        return 1

    if not rows:
        log.error("no rows to process (empty CSV or all prompts/images blank)")
        return 1

    output = Path(args.output)
    output.mkdir(parents=True, exist_ok=True)

    # Pre-assign slugs deterministically (also dedupes colliding slugs).
    used = set()
    planned = []
    for i, row in enumerate(rows, start=1):
        slug = _unique_slug(slug_for(row) or f"asset-{i:02d}", used)
        planned.append({
            "index": i,
            "name": row.get("name", ""),
            "prompt": row.get("prompt"),
            "images": row.get("images"),
            "slug": slug,
        })

    total = len(planned)
    log.info("processing %d asset(s), mode=%s, concurrency=%d, formats=%s",
             total, args.mode, args.concurrency, formats)

    # A tiny namespace to pass the resolved config around without threading argparse internals.
    cfg = argparse.Namespace(
        polycount=args.polycount,
        texture_resolution=args.texture_resolution,
        ai_model=args.ai_model,
        formats=formats,
        poll_interval=args.poll_interval,
        timeout=args.timeout,
        output=output,
    )

    results = []
    credits_spent = 0

    def on_done(res):
        nonlocal credits_spent
        credits_spent += res["credits"]
        log.info("running total: %d credit(s) spent so far", credits_spent)

    if args.concurrency == 1:
        for item in planned:
            res = process_fn(cfg, api_key, item, total)
            results.append(res)
            on_done(res)
    else:
        with ThreadPoolExecutor(max_workers=args.concurrency) as ex:
            futures = {ex.submit(process_fn, cfg, api_key, item, total): item for item in planned}
            for fut in as_completed(futures):
                res = fut.result()
                results.append(res)
                on_done(res)
        results.sort(key=lambda r: r["index"])

    # manifest.json — merge this run's results into the rolling index (keyed by slug)
    write_manifest(output, results)

    # run_log.csv — append-only across runs
    run_log = output / "run_log.csv"
    write_header = not run_log.exists()
    with run_log.open("a", newline="", encoding="utf-8") as fh:
        writer = csv.writer(fh)
        if write_header:
            writer.writerow(["timestamp", "name", "status", "credits", "notes"])
        ts = utc_now_iso()
        for r in results:
            writer.writerow([ts, r["slug"], r["status"], r["credits"], r["error"] or ""])

    succeeded = [r for r in results if r["status"] == "succeeded"]
    failed = [r for r in results if r["status"] != "succeeded"]

    print()
    print("=" * 64)
    print("SUMMARY")
    print(f"  succeeded: {len(succeeded)}")
    print(f"  failed:    {len(failed)}")
    print(f"  credits:   {credits_spent}")
    print("=" * 64)
    for r in failed:
        print(f"  FAILED  {r['slug']}: {r['error']}")
    return 0 if not failed else 1


if __name__ == "__main__":
    sys.exit(main())
