import unittest
import os
from pathlib import Path
import shutil
import uuid
from echo_service.model_lifecycle import remove_model

class ModelLifecycleTests(unittest.TestCase):
    def setUp(self):
        self.root=Path(os.environ.get('ECHO_TEST_ROOT', Path(__file__).resolve().parents[2].parent/'tmp'/'tests'))/('lifecycle-'+uuid.uuid4().hex)
        self.root.mkdir(parents=True)
    def tearDown(self):shutil.rmtree(self.root)
    def test_removal_preserves_meetings_and_other_models(self):
        for name in ['notes','parakeet']:
            (self.root/'models'/name).mkdir(parents=True)
            (self.root/'models'/name/'asset').write_text('test')
        (self.root/'meetings').mkdir();(self.root/'meetings'/'keep').write_text('recording')
        self.assertEqual(remove_model(self.root,'notes'),['notes'])
        self.assertFalse((self.root/'models'/'notes').exists())
        self.assertTrue((self.root/'models'/'parakeet'/'asset').exists())
        self.assertTrue((self.root/'meetings'/'keep').exists())
    def test_in_use_model_cannot_be_removed(self):
        with self.assertRaises(Exception):remove_model(self.root,'parakeet',in_use=['parakeet'])
