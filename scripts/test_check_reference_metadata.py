import unittest
import numpy as np

from check_reference_metadata import bound_title, supports_nominal, tempo_candidates


class MetadataTests(unittest.TestCase):
    def test_pulses_support_nominal_tempos_and_reject_wrong_tempo(self):
        for bpm in [79, 85, 92, 98, 105]:
            with self.subTest(bpm=bpm):
                samples = np.zeros(16000 * 28)
                pulse = np.exp(-np.arange(800) / 120) * np.sin(np.arange(800) * 2 * np.pi * 120 / 16000)
                for onset in np.arange(1, 27, 60 / bpm):
                    start = round(onset * 16000)
                    samples[start:start + len(pulse)] += pulse
                candidates = tempo_candidates(samples)
                self.assertTrue(supports_nominal(candidates, bpm))
                self.assertFalse(supports_nominal(candidates, 117))

    def test_silence_short_and_nonfinite_input_are_inconclusive(self):
        for samples in [np.zeros(16000 * 20), np.ones(100), np.full(16000 * 20, np.nan)]:
            self.assertEqual(tempo_candidates(samples), [])
        self.assertFalse(supports_nominal([], 79))

    def test_title_cannot_cross_source_identity(self):
        observation = {'lessonTitle': 'Baby (original scratch)', 'sourceTitle': 'Scratch_t00', 'sourceSHA256': 'abc'}
        self.assertEqual(bound_title(observation, {'title': 'Scratch_t00', 'sha256': 'abc'}), observation['lessonTitle'])
        for source in [{'title': 'Scratch_t01', 'sha256': 'abc'}, {'title': 'Scratch_t00', 'sha256': 'changed'}]:
            with self.assertRaises(ValueError):
                bound_title(observation, source)


if __name__ == '__main__':
    unittest.main()
