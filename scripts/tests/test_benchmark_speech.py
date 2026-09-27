import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('benchmark_speech', Path(__file__).parents[1] / 'benchmark-speech.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

class BenchmarkTests(unittest.TestCase):
    def test_normalization_preserves_internal_apostrophes(self):
        self.assertEqual(module.words("SUN’S bow — new-comers!"), ["sun's", "bow", "new", "comers"])
    def test_edit_counts(self):
        self.assertEqual(module.errors(['one','two','three'], ['one','four','three','five']), {'substitutions':1,'deletions':0,'insertions':1})
        self.assertEqual(module.errors(['one','two'], []), {'substitutions':0,'deletions':2,'insertions':0})
    def test_current_corpus_transcripts_are_readable(self):
        corpus = Path(__file__).parents[2] / 'test-fixtures' / 'ami-meeting-corpus'
        transcripts = sorted(corpus.glob('ami-*/transcript.txt'))
        self.assertEqual(len(transcripts), 5)
        self.assertTrue(all(module.words(path.read_text()) for path in transcripts))
