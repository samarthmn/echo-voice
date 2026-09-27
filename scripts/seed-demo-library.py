#!/usr/bin/env python3
"""Populate an EMPTY, initialized project-tmp library with clearly fictional screenshot text.

Quit the test app first. This is presentation data, not recognition or timing evidence.
No audio, model-result provenance, or model-readiness receipt is fabricated.
"""
import argparse
from datetime import datetime, timezone
import json
from pathlib import Path
import sqlite3

ROOT = Path(__file__).resolve().parents[1]

def seed(root):
    root = root.resolve()
    if not root.is_relative_to(ROOT / 'tmp'):
        raise ValueError('Demo libraries must remain inside this project tmp directory')
    dbpath = root / 'echo.sqlite'
    if not dbpath.is_file(): raise ValueError('Launch the isolated app once to initialize its schema, then quit it')
    db = sqlite3.connect(dbpath)
    if db.execute('SELECT COUNT(*) FROM meetings').fetchone()[0]: raise ValueError('Refusing to modify a nonempty library')
    started = datetime(2026, 9, 23, 9, 0, tzinfo=timezone.utc).timestamp()
    meeting = 'fictional-design-workshop'
    passages = [
        ('alex', 0, 17, 'Let’s keep the first release focused. People should be able to find the recording, check the transcript, and return to the decision without searching through an entire meeting.'),
        ('jamie', 18, 37, 'Agreed. We’ll use a simple library on the left and keep the transcript and notes together. The original audio should always stay available for review.'),
        ('alex', 38, 59, 'I’ll prepare the revised onboarding copy by Friday. Let’s also make the selected models visible before someone starts a recording.'),
        ('jamie', 60, 82, 'We should test the room-microphone flow next. We haven’t assigned an owner or a date for that yet. For today, the decision is to keep the first screen simple.')]
    with db:
        db.execute('INSERT INTO meetings(id,title,started_at,ended_at,state,language,source_name,uses_echo_cancellation,transcript_revision,speech_model,recording_mode) VALUES(?,?,?,?,?,?,?,?,?,?,?)', (meeting,'Design workshop · fictional example',started,started+90,'ready','en','Fictional example',0,0,'parakeet','inPerson'))
        for identity,label in [('alex','Alex'),('jamie','Jamie')]: db.execute('INSERT INTO speakers VALUES(?,?,?,?)',(meeting,identity,label,0))
        for index,(speaker,start,end,text) in enumerate(passages):
            sid = 'demo-' + str(index)
            db.execute('INSERT INTO transcript_segments(meeting_id,id,window_id,track,start_time,end_time,text,speaker_id,is_uncertain,is_provisional,is_edited) VALUES(?,?,?,?,?,?,?,?,?,?,?)',(meeting,sid,'demo-window','microphone',start,end,text,speaker,0,0,1))
            db.execute('INSERT INTO segment_fts(meeting_id,segment_id,text) VALUES(?,?,?)',(meeting,sid,text))
        def items(values): return json.dumps([dict(id='note-'+str(i),text=text,evidenceIDs=refs) for i,(text,refs) in enumerate(values)]).encode()
        db.execute('INSERT INTO meeting_notes(meeting_id,id,created_at,transcript_revision,summary_json,decisions_json,action_items_json,is_edited,is_partial) VALUES(?,?,?,?,?,?,?,?,?)', (meeting,'demo-notes',started+90,0,items([('The team discussed a focused first release with transcripts, notes and original audio in one workspace.',['demo-0','demo-1'])]),items([('Keep the first screen simple and show the selected models before recording.',['demo-2','demo-3'])]),items([('Prepare revised onboarding copy. Alex volunteered to complete it by Friday.',['demo-2']),('Test the room-microphone flow. An owner and date are still unassigned.',['demo-3'])]),1,0))
    (root/'meetings'/meeting).mkdir(parents=True, exist_ok=True)
    (root/'FICTIONAL-DEMO.txt').write_text(__doc__)
    db.close()

if __name__ == '__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('root',type=Path)
    seed(parser.parse_args().root)
