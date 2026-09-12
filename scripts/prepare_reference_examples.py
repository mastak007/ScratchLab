#!/usr/bin/env python3
"""Prepare a local, hashed viewing/advisory library; never alter source files.

The generated folder is excluded from Git. It is copied as an app resource for
the user's separately requested CXL and full-app builds. No training occurs.
"""
import argparse
import csv
import hashlib
import json
from pathlib import Path
import re
import shutil
import tempfile

SCHEMA = 'scratchlab_reference_examples_v1'


def sha(path):
    result = hashlib.sha256()
    with path.open('rb') as stream:
        while chunk := stream.read(1024 * 1024):
            result.update(chunk)
    return result.hexdigest()


def create(source, destination):
    source, destination = source.resolve(), destination.resolve()
    if source == destination or source in destination.parents or destination in source.parents:
        raise ValueError('Library output must be separate from source data')
    if destination.exists():
        raise ValueError('Choose a new output version; an existing library is never overwritten')
    destination.parent.mkdir(parents=True, exist_ok=True)
    temporary = Path(tempfile.mkdtemp(prefix='.reference-examples-', dir=destination.parent))
    try:
        with (source / 'manifest.csv').open() as stream:
            rows = list(csv.DictReader(stream))
        chosen = {}
        for row in rows:
            key = row['scratch']
            identity = (int(row['bpm']), row['take'])
            if key not in chosen or identity < chosen[key]:
                chosen[key] = identity
        assets = []
        known = {}
        identifiers = set()

        def add(relative, role):
            if relative in known:
                return known[relative]
            path = source / relative
            if not path.is_file() or not path.resolve().is_relative_to(source):
                raise ValueError(f'Missing or unsafe source: {relative}')
            fingerprint = sha(path)
            identifier = fingerprint + '-' + role
            # Byte-identical sources can still have different provenance. Keep
            # each source association without emitting duplicate catalogue IDs.
            if identifier in identifiers:
                identifier += '-' + hashlib.sha256(relative.encode()).hexdigest()[:16]
            identifiers.add(identifier)
            output_relative = 'assets/' + identifier + path.suffix
            target = temporary / output_relative
            target.parent.mkdir(exist_ok=True)
            shutil.copy2(path, target)
            if sha(target) != fingerprint or sha(path) != fingerprint:
                raise ValueError('Source changed while preparing library')
            assets.append({'id': identifier, 'relativePath': output_relative, 'sha256': fingerprint,
                           'byteCount': path.stat().st_size, 'role': role, 'originalRelativePath': relative})
            known[relative] = identifier
            return identifier

        examples = []
        for label, (bpm, take) in sorted(chosen.items()):
            selected = [r for r in rows if r['scratch'] == label and int(r['bpm']) == bpm and r['take'] == take]
            angles = []
            for row in sorted(selected, key=lambda r: r['angle']):
                if not (source / row['video']).is_file():
                    continue
                stem = Path(row['video']).stem
                cache = f'action_features_cache/{label}/{stem}.jsonl'
                angles.append({'id': row['angle'], 'videoAssetID': add(row['video'], 'video'),
                               'handCacheAssetID': add(cache, 'handCache') if (source / cache).exists() else None})
            if not angles:
                raise ValueError(f'No source video for {label}')
            audio = {}
            for variant in ['noBeat', 'withBeat', 'beatOnly']:
                path = re.sub(r'_angle_[1-4]_', '_angle_4_', selected[0]['audio_' + variant])
                audio[variant] = add(path, 'audio')
            examples.append({'id': f'pro-dj-v1:{label}:{bpm}:{take}', 'classLabel': label, 'bpm': bpm, 'take': take,
                             'labelStatus': 'sourceLabelUnreviewed', 'angles': angles, 'audioAssetIDs': audio,
                             'canonicalApproval': False})
        models = []
        for modality, name in [('audio', 'ScratchSoundClassifier'), ('motion', 'ScratchActionClassifier')]:
            models.append({'modality': modality, 'assetID': add('models/' + name + '.mlmodel', 'model'),
                           'evaluationStatus': 'unseenPerformanceAccuracyUnverified', 'advisoryOnly': True})
        manifest = {'schema': SCHEMA, 'id': 'pro-dj-offline-examples-v1', 'title': 'Scratch reference examples',
                    'examples': examples, 'assets': assets, 'models': models,
                    'sourceManifestSHA256': sha(source / 'manifest.csv'),
                    'selection': 'First named take at the lowest listed BPM for each source technique; not selected by model score.',
                    'limitations': ['Technique names are source labels awaiting expert review, not canonical approvals.',
                         'Examples belong to the existing model corpus; analyzing them does not test unseen performance accuracy.',
                         'Hand tracks are estimates. Hand identity, actual historical extraction frames and hardware synchronization are unverified.',
                         'Model scores are uncalibrated; suggestions must not set the selected technique, scoring or approval.',
                         'Missing Watch, MIDI, fader calibration and capture identities have not been reconstructed.']}
        (temporary / 'manifest.json').write_text(json.dumps(manifest, sort_keys=True, indent=2) + '\n')
        (temporary / 'manifest.sha256').write_text(sha(temporary / 'manifest.json') + '\n')
        temporary.rename(destination)
        return {'examples': len(examples), 'assets': len(assets), 'bytes': sum(a['byteCount'] for a in assets),
                'manifestSHA256': sha(destination / 'manifest.json'), 'path': str(destination)}
    except Exception:
        # Only this invocation's staging directory is disposable; sources and
        # previous completed versions are never touched.
        shutil.rmtree(temporary)
        raise


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    arguments = parser.parse_args()
    print(json.dumps(create(arguments.source, arguments.output), indent=2))
