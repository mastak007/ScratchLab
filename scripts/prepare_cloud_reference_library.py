#!/usr/bin/env python3
"""Fetch the pinned private build library and verify bytes before bundling it."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import tempfile


def sha(path):
    digest = hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(chunk)
    return digest.hexdigest()


def verify(library, lock):
    library = library.resolve()
    manifest_path = library / 'manifest.json'
    expected = lock['manifestSHA256']
    if sha(manifest_path) != expected or (library / 'manifest.sha256').read_text().strip() != expected:
        raise ValueError('Reference manifest does not match the pinned build dependency')
    manifest = json.loads(manifest_path.read_text())
    if manifest['schema'] != 'scratchlab_reference_examples_v2':
        raise ValueError('Unsupported reference-library schema')
    if sha(library / 'evidence/provenance.json') != manifest['sourceManifestSHA256']:
        raise ValueError('Reference provenance has changed')
    for asset in manifest['assets']:
        relative = Path(asset['relativePath'])
        path = (library / relative).resolve()
        if relative.is_absolute() or '..' in relative.parts or library not in path.parents:
            raise ValueError('Reference asset leaves the library')
        if path.stat().st_size != asset['byteCount'] or sha(path) != asset['sha256']:
            raise ValueError(f"Reference asset missing or changed: {relative}")
    print(f"Verified {len(manifest['assets'])} reference assets; manifest {expected}")


def prepare(repository):
    repository = repository.resolve()
    lock = json.loads((repository / 'ci_scripts/reference-library.lock.json').read_text())
    if not re.fullmatch(r'[0-9a-f]{40}', lock['revision']):
        raise ValueError('Reference dependency must pin a full Git commit')
    if lock['repository'] != 'https://github.com/mastak007/ScratchLab-ReferenceAssets.git':
        raise ValueError('Unexpected reference dependency repository')
    destination = repository / 'LocalReferenceLibrary/ReferenceExamples'
    if destination.exists():
        # Local developers retain their existing library, including symlinks.
        verify(destination, lock)
        return
    if destination.is_symlink():
        raise ValueError('Existing reference-library symlink is broken; it was not replaced')
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='.cloud-reference-', dir=destination.parent) as temporary:
        checkout = Path(temporary)
        subprocess.run(['git', 'init', '--quiet', str(checkout)], check=True)
        subprocess.run(['git', '-C', str(checkout), 'remote', 'add', 'origin', lock['repository']], check=True)
        subprocess.run(['git', '-C', str(checkout), 'fetch', '--depth', '1', 'origin', lock['revision']], check=True)
        actual = subprocess.check_output(['git', '-C', str(checkout), 'rev-parse', 'FETCH_HEAD'], text=True).strip()
        if actual != lock['revision']:
            raise ValueError('Fetched reference revision differs from lock')
        subprocess.run(['git', '-C', str(checkout), 'checkout', '--quiet', '--detach', actual], check=True)
        source = checkout / 'ReferenceExamples'
        verify(source, lock)
        source.rename(destination)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--repository', required=True, type=Path)
    prepare(parser.parse_args().repository)
