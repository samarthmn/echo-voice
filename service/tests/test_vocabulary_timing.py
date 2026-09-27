import unittest
from echo_service.vocabulary import validate_entries, correct, prompt_terms
from echo_service.word_timing import parakeet_words, whisper_words

class VocabularyTimingTests(unittest.TestCase):
    def test_literal_aliases_and_boundaries(self):
        entries=validate_entries([{'id':'1','spelling':'Echo Voice','aliases':['echo boys'],'enabled':True}])
        text,changes=correct('Hello, echo boys! Not echo boysenberry.',entries)
        self.assertEqual(text,'Hello, Echo Voice! Not echo boysenberry.')
        self.assertEqual(changes[0]['entry_id'],'1')
    def test_alias_collision_rejected(self):
        with self.assertRaises(ValueError):
            validate_entries([{'id':'1','spelling':'A','aliases':['same']},{'id':'2','spelling':'B','aliases':['SAME']}])
    def test_prompt_budget(self):
        entries=validate_entries([{'id':'1','spelling':'Hello','aliases':[]}])
        self.assertEqual(prompt_terms(entries,lambda s:list(s),4),'')
    def test_whisper_offsets_and_invalid_timing(self):
        result=whisper_words([{'word':'Hello','start':0.1,'end':0.5,'probability':0.9}], 'Hello',2,3)
        self.assertAlmostEqual(result[0]['start'],2.1)
        self.assertAlmostEqual(result[0]['end'],2.5)
        self.assertEqual(result[0]['source'],'nativeWord')
        self.assertEqual(whisper_words([{'word':'Hello','start':float('nan'),'end':1}], 'Hello',0,3),[])
    def test_parakeet_token_anchors_are_not_durations(self):
        result=parakeet_words(['▁HEL','LO','▁WORLD'],[0.1,0.2,0.8],'HELLO WORLD',2,4)
        self.assertEqual([w['text'] for w in result],['HELLO','WORLD'])
        self.assertIsNone(result[0]['end'])
        self.assertAlmostEqual(result[1]['start'],2.8)
        self.assertEqual(result[0]['source'],'tokenEmission')
        self.assertEqual(parakeet_words(['▁OTHER'],[0.1],'HELLO',0,2),[])
