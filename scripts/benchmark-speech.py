#!/usr/bin/env python3
"""Local, answer-blind ASR benchmark. Model inference never receives references."""
import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import resource
import sys
import time
import unicodedata
import zipfile

ARCHIVE_SHA256 = '0e2d980726d0ce3343e669477ec04ccfc1bf660ef09b93b14fe729e520f95625'
PROJECT = Path(__file__).resolve().parents[1]

def words(text):
    text = unicodedata.normalize('NFKC', text).lower().replace('’', "'").replace('‘', "'")
    return re.findall(r"[^\W_]+(?:'[^\W_]+)*", text, re.UNICODE)

def errors(reference, hypothesis):
    # Levenshtein with deterministic S/D/I tie breaking and linear row storage.
    previous = [(j, 0, 0, j) for j in range(len(hypothesis) + 1)]
    for i, expected in enumerate(reference, 1):
        current = [(i, 0, i, 0)]
        for j, actual in enumerate(hypothesis, 1):
            if expected == actual:
                current.append(previous[j-1]); continue
            c,s,d,n = previous[j-1]; substitute=(c+1,s+1,d,n)
            c,s,d,n = previous[j]; delete=(c+1,s,d+1,n)
            c,s,d,n = current[j-1]; insert=(c+1,s,d,n+1)
            current.append(min((substitute,delete,insert),key=lambda x:x[0]))
        previous=current
    _,s,d,i=previous[-1]
    return dict(substitutions=s,deletions=d,insertions=i)

def read_archive(path):
    with path.open('rb') as stream:
        if hashlib.file_digest(stream,'sha256').hexdigest()!=ARCHIVE_SHA256:
            raise ValueError('Archive checksum differs from the approved benchmark.')
    with zipfile.ZipFile(path) as archive:
        actual={}
        for item in archive.infolist():
            if item.is_dir() or item.filename.startswith('__MACOSX/'):
                continue
            parts=PurePosixPath(item.filename).parts
            if len(parts)!=2 or parts[0]!='audio tests' or item.file_size>2_000_000 or item.filename in actual:
                raise ValueError('Unexpected or unsafe archive member')
            actual[item.filename]=item
        transcript='audio tests/84-121550.trans.txt'
        refs={}
        for line in archive.read(transcript).decode('utf-8-sig').splitlines():
            ident,ref=line.split(' ',1)
            if ident in refs or not re.fullmatch(r'84-121550-\d{4}',ident):
                raise ValueError('Invalid or duplicate reference ID')
            refs[ident]=ref
        expected={transcript}|{f'audio tests/{ident}.flac' for ident in refs}
        if set(actual)!=expected or len(refs)!=36:
            raise ValueError('Audio/reference coverage differs from the approved set')
        return [dict(id=ident,reference=refs[ident],audio=archive.read(f'audio tests/{ident}.flac')) for ident in sorted(refs)]

def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('--archive',type=Path,required=True)
    parser.add_argument('--assets',type=Path,required=True)
    parser.add_argument('--engine',choices=['whisper','parakeet'],required=True)
    parser.add_argument('--label',required=True)
    parser.add_argument('--output',type=Path,required=True)
    parser.add_argument('--service-source',type=Path,default=PROJECT/'service')
    parser.add_argument('--subset',choices=['all','development','heldout'],default='all')
    args=parser.parse_args()
    root=PROJECT/'tmp'/'update-20260921'/'benchmark'/args.label/args.engine
    root.mkdir(parents=True,exist_ok=True)
    sys.path.insert(0,str(args.service_source))
    os.environ['ECHO_VOICESTUDIO_ROOT']=str(args.assets/'runtime'/'vendor'/'VoiceStudio')
    from echo_service.environment import configure
    configure(root)
    # Inference may read installed models but cannot connect to any network endpoint.
    def forbid_network(event, values):
        if event in ('socket.connect','socket.getaddrinfo'):
            raise RuntimeError('Network access attempted during offline benchmark')
    sys.addaudithook(forbid_network)
    import soundfile as sf
    import io
    from echo_service.adapters import WhisperAdapter,ParakeetAdapter
    fixtures=read_archive(args.archive)
    if args.subset!='all':
        fixtures=[f for f in fixtures if (int(f['id'][-4:])<12)==(args.subset=='development')]
    begin=time.monotonic()
    adapter=(WhisperAdapter if args.engine=='whisper' else ParakeetAdapter)(args.assets)
    load_seconds=time.monotonic()-begin
    rows=[]
    for fixture in fixtures:
        audio,sample_rate=sf.read(io.BytesIO(fixture['audio']),dtype='float32')
        wav=root/(fixture['id']+'.wav')
        sf.write(wav,audio,sample_rate,subtype='PCM_16')
        started=time.monotonic()
        result=adapter.transcribe(wav)
        elapsed=time.monotonic()-started
        hypothesis=' '.join(s['text'] for s in result['segments'])
        counts=errors(words(fixture['reference']),words(hypothesis))
        rows.append(dict(id=fixture['id'],subset='development' if int(fixture['id'][-4:])<12 else 'heldout',audio_sha256=hashlib.sha256(fixture['audio']).hexdigest(),audio_seconds=len(audio)/sample_rate,inference_seconds=elapsed,reference_words=len(words(fixture['reference'])),hypothesis=hypothesis,segments=result['segments'],**counts))
        print(json.dumps(dict(id=fixture['id'],seconds=round(elapsed,3),errors=sum(counts.values()))),flush=True)
        wav.unlink()
    summary={}
    for name in ['all','development','heldout']:
        selected=[r for r in rows if name=='all' or r['subset']==name]
        n=sum(r['reference_words'] for r in selected)
        if n:
            summary[name]=dict(clips=len(selected),reference_words=n,word_error_rate=sum(r[k] for r in selected for k in ['substitutions','deletions','insertions'])/n,inference_seconds=sum(r['inference_seconds'] for r in selected),audio_seconds=sum(r['audio_seconds'] for r in selected))
    report=dict(schema=1,label=args.label,engine=args.engine,archive_sha256=ARCHIVE_SHA256,vocabulary_enabled=False,load_seconds=load_seconds,peak_memory_bytes=resource.getrusage(resource.RUSAGE_SELF).ru_maxrss,summary=summary,rows=rows)
    args.output.parent.mkdir(parents=True,exist_ok=True)
    args.output.write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps(dict(engine=args.engine,summary=summary,output=str(args.output))),flush=True)

if __name__=='__main__': main()
