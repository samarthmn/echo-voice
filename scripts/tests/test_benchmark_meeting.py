import importlib.util
import tempfile
import unittest
from pathlib import Path
import zipfile

ROOT=Path(__file__).resolve().parents[2]
spec=importlib.util.spec_from_file_location('meeting_benchmark',ROOT/'scripts/benchmark-meeting.py')
m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)

class MeetingBenchmarkTests(unittest.TestCase):
    def test_reference_labels_are_not_scored(self):
        plain='Speaker A: Hello world.\nSpeaker B: That’s right.'
        timed='[00:25.380] Speaker A: Hello world.\n[01:01.400] Speaker B: That’s right.'
        self.assertEqual(m.normalized(m.reference_text(plain)),m.normalized(m.reference_text(timed)))
        self.assertEqual(m.normalized(m.reference_text(plain)),['hello','world',"that's",'right'])
    def test_word_error_and_overlap_scores(self):
        self.assertEqual(sum(m.word_errors(['one','two'],['one','three']).values()),1)
        self.assertEqual(m.overlap_metrics('same words','same words')['rouge_l']['f1'],1)
        self.assertEqual(m.overlap_metrics('same words','unrelated text')['rouge_1']['f1'],0)
    def test_valid_citation_does_not_imply_factual_accuracy(self):
        notes={'summary':[{'id':'a','text':'A fabricated assertion','evidenceIDs':['real'],'owner':'Invented'}]}
        score=m.score_notes(notes,'Reference fact',[{'id':'real','text':'Real fact'}])
        self.assertEqual(score['invalid_evidence_items'],[])
        self.assertEqual(len(score['unsupported_owner_deadline_fields']),1)
        self.assertEqual(score['factual_accuracy'],'requires_human_review')
    def test_archive_rejects_path_traversal(self):
        tmp=ROOT/'tmp/benchmark-tests';tmp.mkdir(parents=True,exist_ok=True)
        with tempfile.TemporaryDirectory(dir=tmp) as directory:
            root=Path(directory);archive=root/'bad.zip'
            with zipfile.ZipFile(archive,'w') as z:z.writestr('../audio.wav',b'bad')
            with self.assertRaises(ValueError):m.load_archive(archive,root)
    def test_archive_requires_all_four_unique_inputs(self):
        tmp=ROOT/'tmp/benchmark-tests';tmp.mkdir(parents=True,exist_ok=True)
        with tempfile.TemporaryDirectory(dir=tmp) as directory:
            root=Path(directory);archive=root/'missing.zip'
            with zipfile.ZipFile(archive,'w') as z:z.writestr('audio.wav',b'bad')
            with self.assertRaises(ValueError):m.load_archive(archive,root)


class LongAlignmentTests(unittest.TestCase):
    def test_vectorized_alignment_matches_scalar_distance(self):
        import random
        spec=importlib.util.spec_from_file_location('scalar_benchmark',ROOT/'scripts/benchmark-speech.py')
        scalar=importlib.util.module_from_spec(spec);spec.loader.exec_module(scalar)
        rng=random.Random(17)
        for _ in range(100):
            a=[rng.choice(['a','b','c']) for _ in range(rng.randrange(25))]
            b=[rng.choice(['a','b','c']) for _ in range(rng.randrange(25))]
            self.assertEqual(sum(m.word_errors(a,b).values()),sum(scalar.errors(a,b).values()))

class FixtureFolderTests(unittest.TestCase):
    def test_folder_detects_changes_without_deleting_inputs(self):
        import hashlib
        import json
        tmp=ROOT/'tmp/benchmark-tests';tmp.mkdir(parents=True,exist_ok=True)
        with tempfile.TemporaryDirectory(dir=tmp) as directory:
            root=Path(directory)
            for name in ['audio.wav','transcript.txt','transcript-timestamped.txt','notes.txt']:(root/name).write_bytes(b'fixture')
            hashes={p.name:m.digest(p) for p in root.iterdir()}
            (root/'fixture.json').write_text(json.dumps({'files':hashes,'source_archive_sha256':'source'}))
            self.assertEqual(m.load_fixture(root)[3],'source')
            (root/'notes.txt').write_text('modified')
            with self.assertRaises(ValueError):m.load_fixture(root)
            self.assertTrue((root/'audio.wav').exists())

    def test_corpus_manifest_validates_each_pair(self):
        import json
        tmp=ROOT/'tmp/benchmark-tests';tmp.mkdir(parents=True,exist_ok=True)
        with tempfile.TemporaryDirectory(dir=tmp) as directory:
            root=Path(directory);case=root/'meeting-01';case.mkdir()
            (case/'audio.wav').write_bytes(b'audio')
            (case/'transcript.txt').write_text('[00:01] Speaker A: Hello')
            files={name:m.digest(case/name) for name in ('audio.wav','transcript.txt')}
            (root/'fixture.json').write_text(json.dumps({'schema':2,'name':'Corpus','cases':[{'id':'meeting-01','directory':'meeting-01','files':files}]}))
            corpus=m.load_corpus(root)
            self.assertEqual(corpus['name'],'Corpus')
            self.assertEqual([case['id'] for case in corpus['cases']],['meeting-01'])
            (case/'transcript.txt').write_text('changed')
            with self.assertRaises(ValueError):m.load_corpus(root)

    def test_notes_without_reference_are_explicitly_unscored(self):
        notes={'summary':[{'id':'item','text':'Summary','evidenceIDs':['segment'],'owner':None,'dueDate':None}]}
        score=m.score_notes(notes,None,[{'id':'segment','text':'Source evidence'}])
        self.assertFalse(score['reference_notes_available'])
        self.assertNotIn('lexical_overlap_raw',score)
        self.assertEqual(score['factual_accuracy'],'requires_human_review')

if __name__=='__main__':unittest.main()
