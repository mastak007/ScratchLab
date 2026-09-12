#!/usr/bin/env python3
"""Source-selection and real-media regressions for the derivative builder."""
import json
from pathlib import Path
import tempfile
import unittest

import rebuild_reference_library as rebuild


class SourceSequenceTests(unittest.TestCase):
    def testSearchedOffsetKeepsWholeBabySequenceRatherThanHalfChapter(self):
        actual = rebuild.sequence_ranges([35.035, 83.450033], 726, 'verified_duplicate_half')
        self.assertEqual(len(actual), 1)
        self.assertAlmostEqual(actual[0][1], 59.2592)
        self.assertNotAlmostEqual(actual[0][1], (35.035 + 83.450033) / 2)

    def testTearsRetainsBothUnequalSourcePassesWithoutChoosingFaithfulAudio(self):
        ranges = rebuild.sequence_ranges([43.043, 121.376], 1175, 'verified_partial_repeat')
        self.assertEqual(len(ranges), 2)
        self.assertAlmostEqual(ranges[0][1], 82.2488333333)
        self.assertEqual(ranges[0][1], ranges[1][0])
        self.assertEqual(ranges[1][1], 121.376)
        self.assertNotEqual(ranges[0][1] - ranges[0][0], ranges[1][1] - ranges[1][0])

    def testUnverifiedOrOutOfRangeEvidenceCannotBecomeASequence(self):
        for chapter, offset, state in [([0, 4], 900, 'verified_duplicate_half'),
                                       ([0, 4], 60, 'screened_only'),
                                       ([float('nan'), 4], 60, 'verified_duplicate_half')]:
            with self.assertRaises(ValueError): rebuild.sequence_ranges(chapter, offset, state)

    def testUnconfirmedAudioNeverInheritsBabyRoleNames(self):
        self.assertEqual(rebuild.audio_keys('NOT CONFIRMED - do not reuse Baby\'s stream order here'), ['track0', 'track1', 'track2'])
        self.assertEqual(rebuild.audio_keys('CONFIRMED for this technique'), ['withBeat', 'noBeat', 'beatOnly'])

    def testOutputAndSourceTraversalProtection(self):
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            source = base / 'source'; source.mkdir()
            for output in [source, base, source / 'child']:
                with self.assertRaises(ValueError): rebuild.independent_output(output, [source])
            existing = base / 'old'; existing.mkdir()
            with self.assertRaises(ValueError): rebuild.independent_output(existing, [source])
            outside = base / 'outside.mkv'; outside.write_bytes(b'keep')
            (source / 'Scratch_t00.mkv').symlink_to(outside)
            with self.assertRaises(ValueError): rebuild.safe_source(source, 'Scratch_t00')
            with self.assertRaises(ValueError): rebuild.safe_source(source, '../outside')
            self.assertEqual(outside.read_bytes(), b'keep')

    def testRealMediaRetainsFractionalHeadFieldFramesAndExactPCMAndRejectsTampering(self):
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            source = base / 'source.mkv'
            rebuild.run(['ffmpeg', '-nostdin', '-v', 'error', '-f', 'lavfi', '-i', 'testsrc2=s=720x480:r=30000/1001',
                         '-f', 'lavfi', '-i', 'sine=frequency=997:sample_rate=48000', '-t', '1.5',
                         '-c:v', 'mpeg2video', '-flags', '+ildct+ilme', '-top', '0', '-aspect', '4:3',
                         '-c:a', 'pcm_s16le', '-ac', '2', str(source)])
            original = rebuild.sha(source)
            video, audio = base / 'view.mp4', base / 'track.wav'
            start, end = 0.03507, 1.13511
            receipt = rebuild.render_video(source, start, end, video, 'test-input-identity')
            self.assertGreater(receipt['qa']['frames'], 60)
            self.assertLessEqual(receipt['qa']['maxTimestampErrorSeconds'], 0.001)
            audio_receipt = rebuild.render_audio(source, 0, start, end, audio)
            self.assertTrue(audio_receipt['sourcePCMExact'])
            self.assertLessEqual(abs(audio_receipt['frames'] / 48000 - (end-start)), 1/48000)
            self.assertEqual(rebuild.render_video(source, start, end, video, 'test-input-identity'), receipt)
            with video.open('ab') as stream: stream.write(b'tamper')
            with self.assertRaises(ValueError): rebuild.render_video(source, start, end, video, 'test-input-identity')
            self.assertEqual(rebuild.sha(source), original)


if __name__ == '__main__':
    unittest.main()
