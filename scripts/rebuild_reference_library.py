#!/usr/bin/env python3
"""Rebuild audited MKV sequences into a separate, resumable viewing library.

Requires ffmpeg/ffprobe. Never edits a source, assigns canonical approval,
filters audio, trains models, or transfers operator observations to new views.
"""
import argparse
from concurrent.futures import ThreadPoolExecutor
from fractions import Fraction
import hashlib
import json
import math
from pathlib import Path
import re
import shutil
import subprocess

from prepare_reference_examples import sha

VERSION = 'source-sequences/1'
SCHEMA = 'scratchlab_reference_examples_v2'


def write_json(path, value):
    temporary = path.with_suffix(path.suffix + '.partial')
    temporary.write_text(json.dumps(value, sort_keys=True, indent=2) + '\n')
    temporary.replace(path)


def run(arguments):
    return subprocess.run(arguments, check=True, capture_output=True).stdout


def probe(path):
    return json.loads(run(['ffprobe', '-v', 'error', '-show_streams', '-show_format', '-of', 'json', str(path)]))


def sequence_ranges(chapter, offset_frames, state):
    start, end = chapter
    if not all(math.isfinite(v) for v in chapter) or not 0 <= start < end or offset_frames <= 0:
        raise ValueError('Invalid source range')
    if state not in ('verified_duplicate_half', 'verified_partial_repeat'):
        raise ValueError('Repeat analysis is not verified')
    boundary = start + offset_frames * 1001 / 30000
    if not start < boundary < end:
        raise ValueError('Searched repeat boundary is outside chapter')
    ranges = [(start, boundary)]
    if state == 'verified_partial_repeat':
        ranges.append((boundary, end))
    return ranges


def audio_keys(verdict):
    return ['withBeat', 'noBeat', 'beatOnly'] if verdict == 'CONFIRMED for this technique' else ['track0', 'track1', 'track2']


def safe_source(root, title):
    if not re.fullmatch(r'Scratch_t\d+', title):
        raise ValueError('Invalid source title')
    path = (root / (title + '.mkv')).resolve()
    if not path.is_relative_to(root) or not path.is_file():
        raise ValueError(f'Missing or unsafe source {title}')
    return path


def independent_output(output, inputs):
    output = output.resolve()
    for source in inputs:
        source = source.resolve()
        if output == source or output.is_relative_to(source) or source.is_relative_to(output):
            raise ValueError('Output and every input must be separate')
    if output.exists():
        raise ValueError('Completed output already exists; select a new version')


def pcm_hashes(source):
    text = run(['ffmpeg', '-nostdin', '-v', 'error', '-i', str(source), '-map', '0:a',
                '-ac', '2', '-ar', '48000', '-c:a', 'pcm_s16le', '-f', 'streamhash',
                '-hash', 'sha256', '-']).decode()
    return [line.rsplit('=', 1)[1] for line in text.splitlines() if line and not line.startswith('#')]


def video_filter(start, end):
    return (f'bwdif=mode=send_field:parity=bff:deint=all,trim=start={start:.12f}:end={end:.12f},'
            f'setpts=PTS-{start:.12f}/TB,setsar=8/9,setparams=field_mode=prog')


def verify_video(path, timing, duration):
    info = probe(path)
    streams = info['streams']
    if len(streams) != 1 or streams[0]['codec_type'] != 'video':
        raise ValueError('Video must contain exactly one video stream')
    stream = streams[0]
    if (stream.get('field_order') != 'progressive' or stream.get('sample_aspect_ratio') != '8:9'
            or (stream['width'], stream['height']) != (720, 480)):
        raise ValueError('Unexpected rebuilt video geometry or field order')
    # Decode every output frame; compare its presentation timestamps with the
    # same filtered source frames sent to the encoder, including a partial head.
    frames = json.loads(run(['ffprobe', '-v', 'error', '-select_streams', 'v:0', '-show_frames',
                             '-show_entries', 'frame=best_effort_timestamp_time', '-of', 'json', str(path)]))['frames']
    actual = [float(f['best_effort_timestamp_time']) for f in frames]
    lines = timing.read_text().splitlines()
    timebase = Fraction(next(line.split(': ', 1)[1] for line in lines if line.startswith('#tb 0:')))
    expected = [float(int(line.split(',')[2]) * timebase) for line in lines if line and not line.startswith('#')]
    if not expected or len(actual) != len(expected) or max(abs(a - b) for a, b in zip(actual, expected)) > 0.001:
        raise ValueError(f'Rebuilt frame timestamps/count differ from source: {path.name}')
    if actual[0] < -0.001 or actual[0] > 0.034 or abs(float(info['format']['duration']) - duration) > 0.06:
        raise ValueError('Rebuilt video does not cover the selected source range')
    # ffprobe can report recoverable decode errors with exit zero; a strict
    # full decode must also succeed before the receipt can be accepted.
    run(['ffmpeg', '-nostdin', '-v', 'error', '-xerror', '-i', str(path), '-map', '0:v', '-f', 'null', '-'])
    return {'frames': len(actual), 'firstPTS': actual[0], 'lastPTS': actual[-1],
            'duration': float(info['format']['duration']), 'maxTimestampErrorSeconds': max(abs(a - b) for a, b in zip(actual, expected))}


def render_video(source, start, end, target, fingerprint):
    receipt_path = target.with_suffix('.receipt.json')
    timing = target.with_suffix('.source-frames.md5')
    if target.exists() and receipt_path.exists():
        receipt = json.loads(receipt_path.read_text())
        if receipt['fingerprint'] == fingerprint and receipt['sha256'] == sha(target) and receipt['timingSHA256'] == sha(timing):
            return receipt
        raise ValueError(f'Existing derivative differs; use a new output version: {target}')
    partial = target.with_name(target.stem + '.partial.mp4')
    run(['ffmpeg', '-nostdin', '-v', 'error', '-y', '-copyts', '-ss', str(max(0, start - 2)), '-i', str(source),
         '-filter_complex', f'[0:v:0]{video_filter(start, end)},split=2[v][timing]',
         '-map', '[v]', '-an', '-map_metadata', '-1', '-map_chapters', '-1', '-c:v', 'libx264', '-threads', '2',
         '-preset', 'fast', '-crf', '18', '-pix_fmt', 'yuv420p', '-fps_mode', 'passthrough',
         '-enc_time_base', '1:60000', '-video_track_timescale', '60000', '-movflags', '+faststart', str(partial),
         '-map', '[timing]', '-c:v', 'rawvideo', '-threads', '1', '-fps_mode', 'passthrough',
         '-enc_time_base', '1:60000', '-f', 'framemd5', str(timing)])
    qa = verify_video(partial, timing, end - start)
    partial.replace(target)
    receipt = {'fingerprint': fingerprint, 'sha256': sha(target), 'timingSHA256': sha(timing), 'qa': qa}
    write_json(receipt_path, receipt)
    return receipt


def render_audio(source, ordinal, start, end, target):
    # WAV carries no start timestamp. Sample-quantize the common source origin
    # (less than one sample); never normalize each source stream independently.
    audio_filter = f'atrim=start={start:.12f}:end={end:.12f},asetpts=PTS-{start:.12f}/TB'
    partial = target.with_name(target.stem + '.partial.wav')
    base = ['ffmpeg', '-nostdin', '-v', 'error', '-copyts', '-i', str(source), '-map', f'0:a:{ordinal}',
            '-af', audio_filter, '-c:a', 'pcm_f32le', '-ar', '48000', '-ac', '2']
    run(base + ['-y', str(partial)])
    expected = run(base + ['-f', 'f32le', '-'])
    actual = run(['ffmpeg', '-nostdin', '-v', 'error', '-i', str(partial), '-map', '0:a:0', '-c:a', 'pcm_f32le', '-f', 'f32le', '-'])
    if expected != actual or abs(len(actual) / 8 / 48000 - (end - start)) > 1 / 48000 + 1e-9:
        raise ValueError('Rebuilt audio samples/duration differ from the exact source trim')
    partial.replace(target)
    return {'frames': len(actual) // 8, 'pcmSHA256': hashlib.sha256(actual).hexdigest(), 'sourcePCMExact': True}


def create(source, audit, review, previous, output, workers=2):
    source, audit, review, previous, output = [p.resolve() for p in (source, audit, review, previous, output)]
    independent_output(output, [source, audit, review, previous])
    state = json.loads((audit / 'batch-state.json').read_text())['techniques']
    reviewed = json.loads((review / 'plan.json').read_text())['items']
    observations = json.loads((review / 'review-observations.json').read_text())
    old = json.loads((previous / 'manifest.json').read_text())
    if len(state) != 23 or {k.rsplit('_', 1)[0] for k in state} != {e['classLabel'] for e in old['examples']}:
        raise ValueError('Expected the audited 23-technique corpus')
    staging = output.with_name(output.name + '.building')
    staging.mkdir(parents=True, exist_ok=True)
    (staging / 'assets').mkdir(exist_ok=True)
    evidence = staging / 'evidence'
    evidence.mkdir(exist_ok=True)
    input_identity = {str(p): sha(p) for p in [audit / 'batch-state.json', review / 'plan.json', review / 'review-observations.json', previous / 'manifest.json']}
    identity = {'version': VERSION, 'builderSHA256': sha(Path(__file__)), 'inputs': input_identity,
                'sourceRoot': str(source), 'ffmpeg': run(['ffmpeg', '-version']).decode().splitlines()[0]}
    checkpoint = staging / 'build-identity.json'
    if checkpoint.exists() and json.loads(checkpoint.read_text()) != identity:
        raise ValueError('Build inputs changed; select a new output version')
    write_json(checkpoint, identity)
    assets, examples, provenance = [], [], []

    def add(path, role, original):
        digest = sha(path)
        asset = {'id': path.stem, 'relativePath': str(path.relative_to(staging)), 'originalRelativePath': original,
                 'role': role, 'sha256': digest, 'byteCount': path.stat().st_size}
        assets.append(asset)
        return asset['id']

    for key, entry in sorted(state.items()):
        print(f'Preparing {key}', flush=True)
        detail_path = audit / 'techniques' / (key + '.json')
        detail = json.loads(detail_path.read_text())
        label, bpm = key.rsplit('_', 1)
        bpm = int(bpm.removesuffix('bpm'))
        ranges = sequence_ranges(detail['chapter2'], entry['offset_frames_searched'], entry['state'])
        full_review = next(i for i in reviewed if i['id'] == key + '__full_sequence')
        if max(abs(a - b) for a, b in zip(ranges[0], full_review['candidate_range_s'])) > 1e-8:
            raise ValueError('Rebuild range differs from the operator review range')
        mapping = detail['angle_to_title']
        if not mapping or any(a not in ('1', '2', '3', '4') for a in mapping):
            raise ValueError('Invalid audited camera mapping')
        source_records = {}
        for angle, title in sorted(mapping.items()):
            path = safe_source(source, title)
            stat = path.stat()
            recorded = entry['fingerprint']['sources'][title]
            if (stat.st_size, stat.st_mtime_ns) != (recorded['bytes'], recorded['mtime_ns']):
                raise ValueError(f'Source changed since audit: {title}')
            source_sha = sha(path)
            receipt_path = evidence / (title + '.source.json')
            if receipt_path.exists():
                record = json.loads(receipt_path.read_text())
                if record['sha256'] != source_sha:
                    raise ValueError('Source changed since rebuild began')
            else:
                info = probe(path)
                vs = [s for s in info['streams'] if s['codec_type'] == 'video']
                audios = [s for s in info['streams'] if s['codec_type'] == 'audio']
                if (len(vs) != 1 or vs[0].get('field_order') != 'bb' or vs[0].get('sample_aspect_ratio') != '8:9'
                        or len(audios) != 3 or any(s.get('sample_rate') != '48000' or s.get('channels') != 2
                            or float(s.get('start_time', 'nan')) != 0 for s in audios)):
                    raise ValueError(f'Unsupported source geometry/audio timestamps: {title}')
                hashes = pcm_hashes(path)
                expected = [detail['audio']['streams'][title][f'a{i}']['sha256'] for i in range(3)]
                if hashes != expected:
                    raise ValueError(f'Decoded source audio no longer matches audit: {title}')
                record = {'title': title, 'sha256': source_sha, 'bytes': stat.st_size, 'mtime_ns': stat.st_mtime_ns,
                          'pcmS16SHA256': hashes, 'probe': info}
                write_json(receipt_path, record)
            source_records[angle] = record
        if len({tuple(r['pcmS16SHA256']) for r in source_records.values()}) != 1:
            raise ValueError('Camera titles do not share the same source audio')
        keys = audio_keys(detail['audio']['roles']['verdict'])
        audio_title = mapping.get('3', mapping.get('1'))
        for pass_index, (start, end) in enumerate(ranges, 1):
            take = f'take{pass_index:02d}'
            stem = f'{key}_{take}'
            audio_ids, audio_qa = {}, {}
            for ordinal, audio_key in enumerate(keys):
                target = staging / 'assets' / f'{stem}_{audio_key}.wav'
                audio_qa[audio_key] = render_audio(safe_source(source, audio_title), ordinal, start, end, target)
                audio_ids[audio_key] = add(target, 'audio', audio_title + '.mkv')
            def camera(item):
                angle, title = item
                target = staging / 'assets' / f'{stem}_angle_{angle}.mp4'
                fingerprint = hashlib.sha256(json.dumps([identity, source_records[angle]['sha256'], start, end], sort_keys=True).encode()).hexdigest()
                receipt = render_video(safe_source(source, title), start, end, target, fingerprint)
                return angle, title, target, receipt
            with ThreadPoolExecutor(max_workers=workers) as pool:
                rendered = list(pool.map(camera, sorted(mapping.items())))
            angles = [{'id': 'angle_' + angle, 'videoAssetID': add(target, 'video', title + '.mkv'),
                       'handCacheAssetID': None} for angle, title, target, receipt in rendered]
            warnings = []
            if len(ranges) == 2:
                warnings.append('The two Tears passes repeat the picture but contain a known audio difference. Neither pass is established as the faithful pairing; both are retained for review.')
            if len(angles) < 4:
                warnings.append('Camera 2 is absent from the source: its delivered title duplicates another camera. Three distinct views are available.')
            if keys[0] == 'track0':
                warnings.append('Audio roles are unconfirmed. Track numbers retain the original source order.')
            sequence = {'performanceID': f'cxl-mkv:{label}:{bpm}', 'sourcePass': pass_index,
                        'startSeconds': start, 'endSeconds': end, 'repeatOffsetFrames': entry['offset_frames_searched'],
                        'audioRolesConfirmed': keys[0] != 'track0', 'pairedSyncStatus': 'unresolvedSourceDifference' if len(ranges) == 2 else 'notEstablished',
                        'warnings': warnings}
            examples.append({'id': f'cxl-mkv-v2:{label}:{bpm}:{take}', 'classLabel': label, 'bpm': bpm, 'take': take,
                             'labelStatus': 'sourceLabelUnreviewed', 'canonicalApproval': False,
                             'angles': angles, 'audioAssetIDs': audio_ids, 'sequence': sequence})
            provenance.append({'exampleID': examples[-1]['id'], 'sequence': sequence, 'auditSHA256': sha(detail_path),
                               'sourceRecords': {a: {'title': r['title'], 'sha256': r['sha256']} for a, r in source_records.items()},
                               'audioSourceTitle': audio_title, 'audioSourceOrdinals': dict(zip(keys, range(3))),
                               'audioQA': audio_qa, 'cameraQA': {a: r for a, _, _, r in rendered},
                               'observations': {k: v for k, v in observations['observations'].items() if k.startswith(key + '__')},
                               'observationScope': 'Original reviewed title/range/track only; no automatic approval of a different source pass or view.'})
            print(f'Completed {stem}: {len(angles)} cameras, 3 exact PCM tracks, {end-start:.3f}s', flush=True)
        for record in source_records.values():
            if sha(safe_source(source, record['title'])) != record['sha256']:
                raise ValueError('Source changed during rendering')
    models = []
    old_assets = {a['id']: a for a in old['assets']}
    for model in old['models']:
        asset = old_assets[model['assetID']]
        path = (previous / asset['relativePath']).resolve()
        if not path.is_relative_to(previous) or sha(path) != asset['sha256']:
            raise ValueError('Original advisory model missing or changed')
        target = staging / 'assets' / (model['modality'] + '_unchanged_model.mlmodel')
        shutil.copy2(path, target)
        models.append({**model, 'assetID': add(target, 'model', asset['originalRelativePath'])})
    for path, digest in input_identity.items():
        if sha(Path(path)) != digest:
            raise ValueError('Planning/review input changed during rebuild')
    write_json(evidence / 'provenance.json', provenance)
    shutil.copy2(audit / 'reports/REVIEW_QUEUE.json', evidence / 'source-review-queue.json')
    manifest = {'schema': SCHEMA, 'id': 'cxl-mkv-source-sequences-v2', 'title': 'Scratch reference sequences',
                'sourceManifestSHA256': sha(evidence / 'provenance.json'),
                'selection': 'Whole first sequences at searched repeat boundaries; all distinct source cameras. Both Tears source passes are retained as versions of the same performance.',
                'limitations': ['Source labels await expert review. These examples are not canonical approvals or new training data.',
                    'Absolute hand-to-sound synchronization is not established; the source timeline is preserved without an inferred correction.',
                    'Only recorded operator observations establish reviewed boundaries, on their specified view and track. Other boundaries remain candidates.',
                    'Video is field-deinterlaced at original resolution. Old hand caches were not reused against the rebuilt timeline.',
                    'Audio is a lossless PCM decode of the selected source range. Hum and other source sound are retained.',
                    'Both advisory models are unchanged. Existing-corpus examples do not establish unseen-performance accuracy.'],
                'examples': examples, 'assets': assets, 'models': models}
    write_json(staging / 'manifest.json', manifest)
    (staging / 'manifest.sha256').write_text(sha(staging / 'manifest.json') + '\n')
    for asset in assets:
        if sha(staging / asset['relativePath']) != asset['sha256']:
            raise ValueError('Output changed before publication')
    staging.rename(output)
    return {'path': str(output), 'examples': len(examples), 'assets': len(assets),
            'bytes': sum(a['byteCount'] for a in assets), 'manifestSHA256': sha(output / 'manifest.json')}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('source', 'audit', 'review', 'previous', 'output'):
        parser.add_argument('--' + name, type=Path, required=True)
    parser.add_argument('--workers', type=int, default=2, choices=range(1, 5))
    args = parser.parse_args()
    print(json.dumps(create(**vars(args)), indent=2))
