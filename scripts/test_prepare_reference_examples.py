#!/usr/bin/env python3
import csv
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('prepare', Path(__file__).with_name('prepare_reference_examples.py'))
prepare = importlib.util.module_from_spec(spec)
spec.loader.exec_module(prepare)

class ReferenceExamplePreparationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.base = Path(self.temporary.name)
        self.source = self.base / 'source'
        self.source.mkdir()
        fields = ['scratch', 'bpm', 'take', 'angle', 'video', 'audio_noBeat', 'audio_withBeat', 'audio_beatOnly']
        rows = []
        for angle in [1, 2]:
            row = dict(scratch='baby', bpm='79', take='take01', angle=f'angle_{angle}', video=f'baby_{angle}.mp4')
            # Identical video content is intentional: provenance must stay unique.
            (self.source / row['video']).write_bytes(b'video')
            for variant in ['noBeat', 'withBeat', 'beatOnly']:
                row['audio_' + variant] = f'baby_angle_{angle}_{variant}.wav'
                (self.source / f'baby_angle_4_{variant}.wav').write_bytes(variant.encode())
            rows.append(row)
        with (self.source / 'manifest.csv').open('w') as stream:
            writer = csv.DictWriter(stream, fieldnames=fields)
            writer.writeheader(); writer.writerows(rows)
        models = self.source / 'models'
        models.mkdir()
        for name in ['ScratchSoundClassifier', 'ScratchActionClassifier']:
            (models / (name + '.mlmodel')).write_bytes(name.encode())
        self.destination = self.base / 'library'

    def testCopiesExactBytesAndUniqueSourceIdentities(self):
        originals = {p.relative_to(self.source): prepare.sha(p) for p in self.source.rglob('*') if p.is_file()}
        result = prepare.create(self.source, self.destination)
        manifest = json.loads((self.destination / 'manifest.json').read_text())
        ids = [asset['id'] for asset in manifest['assets']]
        self.assertEqual(len(ids), len(set(ids)))
        self.assertEqual(result['examples'], 1)
        self.assertFalse(manifest['examples'][0]['canonicalApproval'])
        for asset in manifest['assets']:
            self.assertEqual(prepare.sha(self.destination / asset['relativePath']), asset['sha256'])
            self.assertEqual(prepare.sha(self.source / asset['originalRelativePath']), asset['sha256'])
        self.assertEqual(originals, {p.relative_to(self.source): prepare.sha(p) for p in self.source.rglob('*') if p.is_file()})

    def testExistingLibraryIsNeverReplaced(self):
        prepare.create(self.source, self.destination)
        before = (self.destination / 'manifest.json').read_bytes()
        with self.assertRaises(ValueError): prepare.create(self.source, self.destination)
        self.assertEqual(before, (self.destination / 'manifest.json').read_bytes())

    def testMissingModelLeavesNoPartialLibrary(self):
        (self.source / 'models/ScratchSoundClassifier.mlmodel').unlink()
        with self.assertRaises(ValueError): prepare.create(self.source, self.destination)
        self.assertFalse(self.destination.exists())
        self.assertEqual(list(self.base.glob('.reference-examples-*')), [])

    def testOutputCannotOverlapSource(self):
        with self.assertRaises(ValueError): prepare.create(self.source, self.source / 'output')
        with self.assertRaises(ValueError): prepare.create(self.source, self.base)

    def testEscapingSourceSymlinkRejected(self):
        outside = self.base / 'outside'
        outside.write_bytes(b'unrelated')
        model = self.source / 'models/ScratchSoundClassifier.mlmodel'
        model.unlink(); model.symlink_to(outside)
        with self.assertRaises(ValueError): prepare.create(self.source, self.destination)
        self.assertFalse(self.destination.exists())

if __name__ == '__main__': unittest.main()
