#!/usr/bin/env python3
"""Check nominal BPM and attach observed lesson titles without re-encoding media.

Requires ffmpeg, numpy and scipy. This checks support for an existing integer
tempo; metrical aliases remain possible. It never relabels a training class or
declares an expert-approved performance. Outputs are separate and immutable.
"""
import argparse
import json
from pathlib import Path
import shutil
import subprocess

import numpy as np
from scipy import signal

from prepare_reference_examples import sha
from rebuild_reference_library import independent_output, write_json

VERSION = 'nominal-tempo-title-check/1'


def tempo_candidates(samples):
    if len(samples) < 16000 * 8 or not np.all(np.isfinite(samples)) or np.max(np.abs(samples)) < 1e-6:
        return []
    _, _, spectrum = signal.stft(samples, fs=16000, nperseg=512, noverlap=384, boundary=None)
    magnitude = np.abs(spectrum)[2:170]
    magnitude /= np.mean(magnitude, axis=1, keepdims=True) + 1e-5
    envelope = np.maximum(np.diff(np.log1p(magnitude), axis=1), 0).mean(axis=0)
    envelope -= envelope.mean()
    autocorrelation = signal.correlate(envelope, envelope, mode='full', method='fft')[len(envelope) - 1:]
    energy = np.concatenate(([0], np.cumsum(envelope ** 2)))
    lags = np.arange(len(envelope))
    autocorrelation /= np.sqrt(energy[len(envelope) - lags] * (energy[-1] - energy[lags])) + 1e-12
    tempos = np.arange(40.0, 220.001, .02)
    scores = np.zeros_like(tempos)
    for multiple, weight in [(1, .2), (2, .3), (4, .5), (8, .7)]:
        scores += weight * np.interp(60 * 125 / tempos * multiple, lags, autocorrelation)
    peaks = signal.find_peaks(scores, distance=50, prominence=.03)[0]
    # No filename/nominal BPM participates in candidate generation or ranking.
    return sorted([{'bpm': round(float(tempos[i]), 3), 'score': round(float(scores[i]), 4)}
                   for i in peaks], key=lambda item: item['score'], reverse=True)[:16]


def supports_nominal(candidates, bpm):
    return bool(candidates) and any(abs(item['bpm'] - bpm) < .5 and item['score'] >= .6
                                   and item['score'] >= .7 * candidates[0]['score'] for item in candidates)


def measure_track(path, bpm):
    raw = subprocess.check_output(['ffmpeg', '-nostdin', '-v', 'error', '-i', str(path),
                                   '-ar', '16000', '-ac', '1', '-f', 'f32le', '-'])
    samples = np.frombuffer(raw, dtype='<f4')
    halves = len(samples) // 2
    windows = {'whole': samples, 'firstHalf': samples[:halves], 'secondHalf': samples[halves:]}
    candidates = {key: tempo_candidates(values) for key, values in windows.items()}
    return {'candidates': candidates, 'supportsNominal': all(supports_nominal(c, bpm) for c in candidates.values())}


def bound_title(observation, source_record):
    title = observation['lessonTitle']
    if not title.strip() or len(title) > 120 or observation['sourceTitle'] != source_record['title'] \
            or observation['sourceSHA256'] != source_record['sha256']:
        raise ValueError('Lesson title observation does not match this source')
    return title


def checked_asset(root, asset):
    relative = Path(asset['relativePath'])
    if relative.is_absolute() or '..' in relative.parts:
        raise ValueError('Asset path must stay relative to the library')
    path = (root / relative).resolve()
    if not path.is_relative_to(root) or not path.is_file() or path.stat().st_size != asset['byteCount'] \
            or sha(path) != asset['sha256']:
        raise ValueError('Asset is missing, outside the library, or changed')
    return path


def check(library, titles, output):
    library, titles, output = [path.resolve() for path in (library, titles, output)]
    independent_output(output, [library, titles.parent])
    manifest_path = library / 'manifest.json'
    manifest_hash = sha(manifest_path)
    if (library / 'manifest.sha256').read_text().strip() != manifest_hash:
        raise ValueError('Input manifest changed')
    manifest = json.loads(manifest_path.read_text())
    provenance_path = library / 'evidence/provenance.json'
    if manifest['schema'] != 'scratchlab_reference_examples_v2' or sha(provenance_path) != manifest['sourceManifestSHA256']:
        raise ValueError('Input provenance changed or unsupported schema')
    provenance = json.loads(provenance_path.read_text())
    records = {row['exampleID']: row for row in provenance}
    observations = json.loads(titles.read_text())
    assets = {asset['id']: asset for asset in manifest['assets']}
    paths = {key: checked_asset(library, asset) for key, asset in assets.items()}
    measurements = []
    for example in manifest['examples']:
        record = records[example['id']]
        observation = observations[example['classLabel']]
        title = bound_title(observation, record['sourceRecords']['1'])
        tracks = {key: measure_track(paths[asset_id], example['bpm']) for key, asset_id in example['audioAssetIDs'].items()}
        supported = sum(track['supportsNominal'] for track in tracks.values()) >= 2
        measurement = {'exampleID': example['id'], 'nominalBPM': example['bpm'], 'supported': supported, 'tracks': tracks}
        measurements.append(measurement)
        print(example['id'], 'supported' if supported else 'NEEDS REVIEW', flush=True)
        if not supported:
            raise ValueError(f'Nominal BPM needs review; no relabel or publication: {example["id"]}')
        example['sequence']['lessonTitle'] = title
        record['sequence']['lessonTitle'] = title
        record['metadataReview'] = {'titleObservation': observation, 'nominalTempo': measurement,
                                    'method': VERSION, 'meaning': 'Source title and nominal musical tempo; not expert performance approval.'}
    staging = output.with_name(output.name + '.checking')
    if staging.exists():
        raise ValueError('Staging output exists; use a new output path or inspect the incomplete result')
    (staging / 'evidence').mkdir(parents=True)
    # Copy only declared playback/model assets. Machine-local build paths,
    # decoder receipts and working caches stay in the original evidence root.
    for key, asset in assets.items():
        destination = staging / asset['relativePath']
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(paths[key], destination)
        checked_asset(staging, asset)
    write_json(staging / 'evidence/provenance.json', provenance)
    shutil.copy2(library / 'evidence/source-review-queue.json', staging / 'evidence/source-review-queue.json')
    manifest['sourceManifestSHA256'] = sha(staging / 'evidence/provenance.json')
    manifest['limitations'].append('Lesson titles were checked against source title cards. Beat periodicity supports the nominal integer BPMs; metrical aliases and small source-tempo deviations remain possible.')
    write_json(staging / 'manifest.json', manifest)
    (staging / 'manifest.sha256').write_text(sha(staging / 'manifest.json') + '\n')
    if sha(manifest_path) != manifest_hash:
        raise ValueError('Input manifest changed during checking')
    staging.rename(output)
    return {'output': str(output), 'examples': len(measurements), 'nominalBPMsSupported': len(measurements),
            'manifestSHA256': sha(output / 'manifest.json'), 'assetsUnchanged': len(assets)}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('library', 'titles', 'output'):
        parser.add_argument('--' + name, type=Path, required=True)
    print(json.dumps(check(**vars(parser.parse_args())), indent=2))
