#!/usr/bin/env python3
"""Answer-blind local ASR × notes benchmark. No model downloads or library writes."""
import argparse
from collections import Counter
import hashlib
import importlib.util
import json
import math
import os
from pathlib import Path, PurePosixPath
import re
import resource
import shutil
import subprocess
import sys
import time
import unicodedata
import uuid
import zipfile

PROJECT = Path(__file__).resolve().parents[1]
PIPELINE = 'meeting-benchmark-v1-30s-context-28s-ownership'
ASSETS = Path.home() / 'Library/Application Support/EchoVoice'
RUNNER = PROJECT / 'dist/EchoBenchmark.app/Contents/MacOS/EchoBenchmark'
NAMES = {'asr':'Whisper large-v3-turbo','parakeet':'Parakeet Unified English 0.6B','notes':'Qwen3 4B','gemma':'Gemma 4 E4B','gptoss':'GPT-OSS 20B'}
LABEL = re.compile(r'^\s*(?:\[(?:\d+:)?\d+:\d+(?:\.\d+)?\]\s*)?Speaker\s+[^:\n]+:\s*', re.MULTILINE)

def digest(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()

def normalized(text):
    text = unicodedata.normalize('NFKC', text).lower().replace('’', "'").replace('‘', "'")
    return re.findall(r"[^\W_]+(?:'[^\W_]+)*", text)

def reference_text(text):
    return LABEL.sub('', text)

def atomic(path, value):
    path = Path(path); path.parent.mkdir(parents=True, exist_ok=True)
    stage = path.with_name(path.name + '.partial')
    stage.write_text(json.dumps(value, indent=2, ensure_ascii=False) + '\n')
    stage.replace(path)
    if path.name == 'report.json':
        spec=importlib.util.spec_from_file_location('benchmark_html',PROJECT/'scripts/render-benchmark-report.py')
        renderer=importlib.util.module_from_spec(spec);spec.loader.exec_module(renderer)
        renderer.write_report(value,path.with_name('REPORT.html'))

def load_archive(archive, scratch):
    """Never extractall: whitelist exactly four flat files under one common folder."""
    expected = {'audio.wav', 'transcript.txt', 'transcript-timestamped.txt', 'notes.txt'}
    with zipfile.ZipFile(archive) as z:
        entries = {}; parents = set()
        for info in z.infolist():
            parts = PurePosixPath(info.filename).parts
            if info.is_dir() or (parts and parts[0] == '__MACOSX') or PurePosixPath(info.filename).name.startswith('._'):
                continue
            if not parts or PurePosixPath(info.filename).is_absolute() or '..' in parts or '\\' in info.filename or len(parts) > 2:
                raise ValueError('Unsafe archive path')
            name = parts[-1]
            if name not in expected or name in entries or (info.external_attr >> 16) & 0o170000 == 0o120000:
                raise ValueError('Unexpected, duplicate, or symbolic-link archive entry')
            if info.file_size > (4_000_000_000 if name == 'audio.wav' else 5_000_000):
                raise ValueError('Archive member exceeds benchmark size limit')
            entries[name] = info; parents.add(parts[:-1])
        if set(entries) != expected or len(parents) != 1:
            raise ValueError('Expected one audio WAV and matching plain/timestamped transcript and notes files')
        refs = {name: z.read(entries[name]).decode('utf-8-sig') for name in expected - {'audio.wav'}}
        audio = scratch / 'audio.wav'
        with z.open(entries['audio.wav']) as source, audio.open('wb') as target:
            shutil.copyfileobj(source, target, 1024 * 1024)
    return audio, refs

def load_fixture(folder):
    folder=folder.resolve()
    required={'audio.wav','transcript.txt'}
    optional={'transcript-timestamped.txt','notes.txt'}
    actual={path.name for path in folder.iterdir() if path.is_file() and path.name != 'fixture.json'}
    if not required.issubset(actual) or actual-required-optional:
        raise ValueError('Fixture folder must contain audio.wav and transcript.txt, with only optional timestamped transcript and notes files')
    if any((folder/name).is_symlink() for name in actual):
        raise ValueError('Fixture inputs must be regular files, not symbolic links')
    manifest_path=folder/'fixture.json'
    if manifest_path.is_file():
        manifest=json.loads(manifest_path.read_text())
        if set(manifest.get('files',{})) != actual: raise ValueError('Invalid fixture manifest')
        for name,checksum in manifest['files'].items():
            if digest(folder/name)!=checksum: raise ValueError('Fixture checksum changed: '+name)
    else: manifest={'files':{name:digest(folder/name) for name in sorted(actual)}}
    identity=hashlib.sha256(json.dumps(manifest['files'],sort_keys=True).encode()).hexdigest()
    refs={name:(folder/name).read_text(encoding='utf-8-sig') for name in actual-{'audio.wav'}}
    return folder/'audio.wav',refs,identity,manifest.get('source_archive_sha256')

def load_corpus(folder):
    """Validate a versioned collection of independent meeting fixtures."""
    folder=folder.resolve(); manifest_path=folder/'fixture.json'
    if not manifest_path.is_file(): return None
    manifest=json.loads(manifest_path.read_text())
    if manifest.get('schema') != 2: return None
    cases=[]; seen=set()
    for entry in manifest.get('cases',[]):
        ident=entry.get('id',''); relative=entry.get('directory','')
        if not re.fullmatch(r'[a-z0-9][a-z0-9-]{0,63}',ident) or ident in seen:
            raise ValueError('Corpus contains an invalid or duplicate case ID')
        case=(folder/relative).resolve()
        if not case.is_relative_to(folder) or not case.is_dir() or case.is_symlink():
            raise ValueError('Corpus case directory is unsafe or missing')
        files=entry.get('files',{})
        if set(files) != {'audio.wav','transcript.txt'}:
            raise ValueError('Each corpus case must contain exactly one audio WAV and transcript')
        for name,checksum in files.items():
            path=case/name
            if not path.is_file() or path.is_symlink() or digest(path) != checksum:
                raise ValueError(f'Corpus fixture changed: {ident}/{name}')
        cases.append(dict(id=ident,directory=case))
        seen.add(ident)
    if not cases: raise ValueError('Corpus contains no cases')
    identity=hashlib.sha256(json.dumps(manifest,sort_keys=True).encode()).hexdigest()
    return dict(name=manifest.get('name',folder.name),identity=identity,cases=cases)

def import_fixture(archive, destination):
    destination=destination.absolute()
    allowed=PROJECT/'test-fixtures'
    allowed.mkdir(parents=True,exist_ok=True)
    if not destination.resolve().is_relative_to(allowed.resolve()):
        raise ValueError('Keep imported fixtures under the project test-fixtures directory')
    if destination.exists():
        _,_,_,previous=load_fixture(destination)
        if previous!=digest(archive): raise ValueError('Existing fixture belongs to a different archive; choose another folder')
        print('Verified existing fixture: '+str(destination));return
    stage=allowed/('import-'+uuid.uuid4().hex);stage.mkdir()
    try:
        _,refs=load_archive(archive,stage)
        for name,text in refs.items(): (stage/name).write_text(text)
        files={name:digest(stage/name) for name in ('audio.wav','transcript.txt','transcript-timestamped.txt','notes.txt')}
        atomic(stage/'fixture.json',dict(schema=1,source_archive_sha256=digest(archive),files=files))
        stage.rename(destination)
        print('Imported fixture: '+str(destination))
    finally:
        if stage.exists(): shutil.rmtree(stage)

def word_errors(reference, hypothesis):
    """Exact Levenshtein counts via linear-memory Hirschberg alignment.

    Vectorized row evaluation avoids quadratic Python loops on long meetings.
    Ties use the earliest hypothesis split; metric is identical for both models.
    """
    try:
        import numpy as np
    except ImportError:
        spec = importlib.util.spec_from_file_location('scalar_benchmark', PROJECT/'scripts/benchmark-speech.py')
        module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
        return module.errors(reference, hypothesis)
    vocabulary = {word:index for index,word in enumerate(set(reference+hypothesis))}
    ref=np.array([vocabulary[w] for w in reference],dtype=np.int32)
    hyp=np.array([vocabulary[w] for w in hypothesis],dtype=np.int32)
    def row(a,b):
        previous=np.arange(len(b)+1,dtype=np.int32)
        positions=np.arange(len(b),dtype=np.int32)
        for i,token in enumerate(a,1):
            diagonal=np.minimum(previous[:-1]+(b!=token),previous[1:]+1)
            current=np.empty_like(previous);current[0]=i
            current[1:]=np.minimum(np.minimum.accumulate(diagonal-positions)+positions,i+positions+1)
            previous=current
        return previous
    def counts(a,b):
        if len(a)==0:return (0,0,len(b))
        if len(b)==0:return (0,len(a),0)
        if len(a)==1:
            if np.any(b==a[0]):return (0,0,len(b)-1)
            return (1,0,len(b)-1)
        midpoint=len(a)//2
        costs=row(a[:midpoint],b)+row(a[midpoint:][::-1],b[::-1])[::-1]
        split=int(np.argmin(costs))
        left=counts(a[:midpoint],b[:split]);right=counts(a[midpoint:],b[split:])
        return tuple(x+y for x,y in zip(left,right))
    substitutions,deletions,insertions=counts(ref,hyp)
    return dict(substitutions=substitutions,deletions=deletions,insertions=insertions)

def overlap_metrics(reference, candidate):
    """Lexical overlap diagnostics, deliberately NOT a factual accuracy score."""
    ref, hyp = normalized(reference), normalized(candidate)
    result = {}
    for n in (1, 2):
        r = Counter(tuple(ref[i:i+n]) for i in range(len(ref)-n+1))
        h = Counter(tuple(hyp[i:i+n]) for i in range(len(hyp)-n+1))
        match = sum((r & h).values()); nr = sum(r.values()); nh = sum(h.values())
        precision, recall = match / nh if nh else 0, match / nr if nr else 0
        result[f'rouge_{n}'] = dict(precision=precision, recall=recall, f1=2*precision*recall/(precision+recall) if precision+recall else 0)
    previous = [0] * (len(hyp)+1)
    for token in ref:
        current = [0]
        for j, other in enumerate(hyp, 1):
            current.append(previous[j-1]+1 if token == other else max(previous[j], current[-1]))
        previous = current
    match = previous[-1]; precision = match/len(hyp) if hyp else 0; recall = match/len(ref) if ref else 0
    result['rouge_l'] = dict(precision=precision, recall=recall, f1=2*precision*recall/(precision+recall) if precision+recall else 0)
    return result

def score_notes(notes, reference, segments):
    evidence = {s['id']:s['text'] for s in segments}
    items = sum((notes.get(key, []) for key in ('summary','decisions','actionItems')), [])
    invalid = []; unsupported = []
    for item in items:
        ids = item.get('evidenceIDs', [])
        if not ids or any(i not in evidence for i in ids): invalid.append(item['id'])
        source = ' '.join(evidence.get(i, '') for i in ids).casefold()
        for key in ('owner','dueDate'):
            if item.get(key) and item[key].casefold() not in source: unsupported.append(dict(id=item['id'],field=key))
    candidate = '\n'.join(item['text'] for item in items)
    result=dict(item_count=len(items), invalid_evidence_items=invalid, unsupported_owner_deadline_fields=unsupported, partial=notes.get('isPartial',False), factual_accuracy='requires_human_review')
    if reference is None:
        return dict(result,reference_notes_available=False)
    # Reference notes may repeat an overview as individual lines: report raw and exact-line-deduplicated views.
    dedup = '\n'.join(dict.fromkeys(line.strip() for line in reference.splitlines() if line.strip() and line.strip() != '*NA*'))
    return dict(result,reference_notes_available=True,lexical_overlap_raw=overlap_metrics(reference,candidate),lexical_overlap_deduplicated_lines=overlap_metrics(dedup,candidate))

def env_for(scratch, assets):
    env = os.environ.copy()
    for key in ('HF_TOKEN','HUGGING_FACE_HUB_TOKEN','HUGGINGFACE_TOKEN'): env.pop(key,None)
    env.update(PYTHONDONTWRITEBYTECODE='1', HF_HUB_OFFLINE='1', TRANSFORMERS_OFFLINE='1', HF_HUB_DISABLE_TELEMETRY='1', HF_HUB_DISABLE_IMPLICIT_TOKEN='1', DO_NOT_TRACK='1', PYANNOTE_METRICS_ENABLED='false', TOKENIZERS_PARALLELISM='false', TMPDIR=str(scratch), TMP=str(scratch), TEMP=str(scratch), XDG_CACHE_HOME=str(scratch/'cache'), HF_HOME=str(scratch/'hf'), CFFIXED_USER_HOME=str(scratch/'home'), ECHO_VOICESTUDIO_ROOT=str(assets/'runtime/vendor/VoiceStudio'))
    return env

def process(command, logfile, env):
    import psutil
    started=time.monotonic(); peak=0
    with logfile.open('w') as log:
        child=subprocess.Popen(command,stdout=log,stderr=subprocess.STDOUT,env=env)
        try:
            while child.poll() is None:
                try: peak=max(peak, psutil.Process(child.pid).memory_info().rss)
                except psutil.Error: pass
                time.sleep(.25)
        except BaseException:
            child.terminate()
            try: child.wait(timeout=10)
            except subprocess.TimeoutExpired: child.kill(); child.wait()
            raise
    if child.returncode: raise RuntimeError(f'Worker failed ({child.returncode}); see {logfile}')
    return dict(wall_seconds=time.monotonic()-started, sampled_peak_rss_bytes=peak)

def asr_worker(engine, audio_path, output, assets, scratch):
    sys.path.insert(0,str(PROJECT/'service'))
    from echo_service.environment import configure
    configure(scratch)
    def no_network(event, _):
        if event in ('socket.connect','socket.getaddrinfo'): raise RuntimeError('Offline benchmark blocked network access')
    sys.addaudithook(no_network)
    import numpy as np
    import soundfile as sf
    from scipy.signal import resample_poly
    from echo_service.adapters import WhisperAdapter, ParakeetAdapter
    started=time.monotonic()
    adapter=(WhisperAdapter if engine=='asr' else ParakeetAdapter)(assets)
    constructor=time.monotonic()-started
    segments=[]; windows=[]; fallbacks=0
    with sf.SoundFile(audio_path) as source:
        duration=len(source)/source.samplerate
        for number, ownership_start in enumerate(np.arange(0,duration,28.0)):
            ownership_start=float(ownership_start); ownership_end=min(duration,ownership_start+28)
            start=max(0,ownership_start-1); end=min(duration,ownership_end+1)
            source.seek(round(start*source.samplerate)); data=source.read(round((end-start)*source.samplerate),dtype='float32',always_2d=True).mean(axis=1)
            if source.samplerate!=16000:
                divisor=math.gcd(source.samplerate,16000)
                data=resample_poly(data,16000//divisor,source.samplerate//divisor).astype('float32')
            wav=scratch/'window.wav'; sf.write(wav,data[:480000],16000,subtype='PCM_16')
            begin=time.monotonic(); decoded=adapter.transcribe(wav); elapsed=time.monotonic()-begin
            for index,row in enumerate(decoded['segments']):
                timed=row.get('words') or []
                selected=[w for w in timed if ownership_start <= start+w['start'] < ownership_end]
                if timed:
                    if not selected: continue
                    text=' '.join(w['text'].strip() for w in selected)
                    begin_time=start+selected[0]['start']; end_time=min(end,start+(selected[-1].get('end') or row['end']))
                else:
                    midpoint=start+(row['start']+row['end'])/2
                    if not ownership_start <= midpoint < ownership_end: continue
                    text=row['text'];begin_time=start+row['start'];end_time=start+row['end'];fallbacks+=1
                segments.append(dict(id=f'{engine}-{number:04d}-{index:03d}',meetingID='benchmark',windowID=f'{engine}-{number:04d}',track='remote',startTime=begin_time,endTime=max(begin_time+.001,end_time),text=text,isUncertain=row.get('uncertain',False),isProvisional=False,isEdited=False))
            windows.append(dict(index=number,start=start,end=end,ownership_start=ownership_start,ownership_end=ownership_end,seconds=elapsed))
            print(json.dumps(dict(engine=engine,window=number+1,total=math.ceil(duration/28),seconds=round(elapsed,2))),flush=True)
    atomic(output,dict(segments=segments,windows=windows,duration=duration,constructor_seconds=constructor,inference_seconds=sum(w['seconds'] for w in windows),first_window_seconds=windows[0]['seconds'] if windows else 0,peak_memory_bytes=resource.getrusage(resource.RUSAGE_SELF).ru_maxrss,passage_fallbacks=fallbacks))

def run_corpus(args, corpus, output):
    """Run each meeting independently and aggregate micro/macro ASR results."""
    case_reports=[]
    for index,case in enumerate(corpus['cases'],1):
        print(f"Corpus case {index}/{len(corpus['cases'])}: {case['id']}",flush=True)
        command=[sys.executable,str(Path(__file__).resolve()),'--fixture',str(case['directory']),'--assets',str(args.assets),'--output',str(output/'cases'/case['id']),'--asr',args.asr,'--notes-runner',str(args.notes_runner)]
        if args.asr_only: command.append('--asr-only')
        else: command += ['--notes',args.notes]
        if args.resume: command.append('--resume')
        completed=subprocess.run(command)
        if completed.returncode: raise RuntimeError(f"Corpus case failed: {case['id']}")
        case_reports.append((case['id'],json.loads((output/'cases'/case['id']/'report.json').read_text())))

    engine=args.asr
    rows=[report['asr'][engine] for _,report in case_reports]
    words=sum(report['reference_words'] for _,report in case_reports)
    counts={name:sum(row[name] for row in rows) for name in ('substitutions','deletions','insertions')}
    per_case=[]
    for ident,report in case_reports:
        row=report['asr'][engine]
        per_case.append(dict(id=ident,audio_seconds=report['audio']['seconds'],reference_words=report['reference_words'],word_error_rate=row['word_error_rate'],substitutions=row['substitutions'],deletions=row['deletions'],insertions=row['insertions'],inference_seconds=row['inference_seconds'],passage_fallbacks=row['passage_fallbacks']))
    aggregate=dict(
        model=rows[0]['model'],revision=rows[0]['revision'],**counts,
        word_error_rate=sum(counts.values())/words,
        macro_word_error_rate=sum(row['word_error_rate'] for row in rows)/len(rows),
        hypothesis_words=sum(row['hypothesis_words'] for row in rows),
        inference_seconds=sum(row['inference_seconds'] for row in rows),
        real_time_factor=sum(row['inference_seconds'] for row in rows)/sum(report['audio']['seconds'] for _,report in case_reports),
        constructor_seconds=sum(row['constructor_seconds'] for row in rows),
        first_window_seconds=sum(row['first_window_seconds'] for row in rows),
        peak_memory_bytes=max(row['peak_memory_bytes'] for row in rows),
        passage_fallbacks=sum(row['passage_fallbacks'] for row in rows),reused=all(row['reused'] for row in rows))
    combinations={}
    if not args.asr_only:
        key=f'{engine}+{args.notes}'
        note_rows=[report['combinations'][key] for _,report in case_reports]
        failed=[row for row in note_rows if row['status']=='failed']
        combinations[key]=dict(
            status='failed' if failed else 'completed_unscored',
            error='; '.join(row.get('error','') for row in failed) if failed else None,
            reference_notes_available=False,
            item_count=sum(row.get('item_count',0) for row in note_rows),
            invalid_evidence_items=sum(len(row.get('invalid_evidence_items',[])) for row in note_rows),
            unsupported_owner_deadline_fields=sum(len(row.get('unsupported_owner_deadline_fields',[])) for row in note_rows),
            partial_cases=sum(bool(row.get('partial')) for row in note_rows),
            seconds=sum(row.get('seconds',0) for row in note_rows),
            notes_provider=note_rows[0].get('notes_provider') if note_rows else None,
            notes_revision=note_rows[0].get('notes_revision') if note_rows else None,
            notes_repository=note_rows[0].get('notes_repository') if note_rows else None,
            runtime_version=note_rows[0].get('runtime_version') if note_rows else None,
            factual_accuracy='requires_human_review')
    report=dict(
        schema=2,fixture=corpus['name'],selected_pair=dict(asr=engine,notes=args.notes),
        identity=dict(fixture_sha256=corpus['identity'],pipeline=PIPELINE),
        audio=dict(seconds=sum(report['audio']['seconds'] for _,report in case_reports),files=len(case_reports)),
        reference_words=words,notes_reference_available=False,asr={engine:aggregate},
        combinations=combinations,per_case=per_case,
        limits=['No reference notes were supplied, so generated notes have no automatic accuracy score.','Notes citation IDs and owner/deadline grounding are structural checks; factual accuracy requires human review.','Reference transcripts contain disfluencies, non-speech markers, and overlapping speakers; strict WER counts all normalized reference words.','Each audio file is processed independently with bounded 30-second windows and a 28-second ownership stride.'])
    output.mkdir(parents=True,exist_ok=True)
    atomic(output/'report.json',report)
    lines=['# Local model accuracy benchmark','',f"Corpus: {corpus['name']} · {len(case_reports)} recordings · {report['audio']['seconds']/60:.2f} minutes · {words} reference words.",'',f"Micro WER: {aggregate['word_error_rate']:.2%} · Macro WER: {aggregate['macro_word_error_rate']:.2%}",'','| Recording | WER | Reference words | S | D | I | Processing |','|---|---:|---:|---:|---:|---:|---:|']
    for row in per_case: lines.append(f"| {row['id']} | {row['word_error_rate']:.2%} | {row['reference_words']} | {row['substitutions']} | {row['deletions']} | {row['insertions']} | {row['inference_seconds']:.1f}s |")
    if combinations: lines += ['','## Meeting notes','','Generated for every recording. No reference notes were supplied, so no ROUGE or automatic notes-accuracy score is reported. Review generated notes against each reference transcript.']
    lines += ['','## Limitations','',*['- '+item for item in report['limits']]]
    (output/'REPORT.md').write_text('\n'.join(lines)+'\n')
    print(f'Reports saved: {output}',flush=True)
    if any(row['status']=='failed' for row in combinations.values()): raise RuntimeError('One or more notes cases failed; completed ASR results were preserved')

def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--archive',type=Path,help='Read a ZIP directly (or use --fixture)')
    p.add_argument('--fixture',type=Path,help='Folder containing extracted audio and reference files')
    p.add_argument('--import-archive',type=Path,help='Extract and checksum a ZIP to --fixture; no model execution')
    p.add_argument('--assets',type=Path,default=ASSETS)
    p.add_argument('--output',type=Path,help='Persistent local report directory; default reports/model-benchmarks/<timestamp>')
    p.add_argument('--asr',choices=['whisper','parakeet','asr'],help='Required speech model (asr is an alias for whisper)')
    p.add_argument('--notes',help='Notes model: qwen3, gemma, gptoss, or ollama:<installed-model-tag>')
    p.add_argument('--asr-only',action='store_true')
    p.add_argument('--check',action='store_true',help='Validate the selected installed models without running inference')
    p.add_argument('--resume',action='store_true',help='Reuse completed outputs only when inputs and implementation fingerprints match')
    p.add_argument('--notes-runner',type=Path,default=RUNNER)
    p.add_argument('--worker',nargs=3,metavar=('ENGINE','AUDIO','OUTPUT'),help=argparse.SUPPRESS)
    p.add_argument('--scratch',type=Path,help=argparse.SUPPRESS)
    args=p.parse_args()
    if args.worker:
        asr_worker(args.worker[0],Path(args.worker[1]),Path(args.worker[2]),args.assets,args.scratch);return
    if args.import_archive:
        if not args.fixture: p.error('--import-archive requires --fixture')
        import_fixture(args.import_archive,args.fixture); return
    if bool(args.archive)==bool(args.fixture): p.error('Supply exactly one of --fixture or --archive')
    if not args.asr: p.error('--asr is required: whisper or parakeet')
    if not args.asr_only and not args.notes: p.error('--notes is required: qwen3, gemma, gptoss, or ollama:<installed-model-tag>')
    if args.asr_only and args.notes: p.error('--asr-only cannot be combined with --notes')
    args.asr = {'whisper':'asr'}.get(args.asr,args.asr)
    args.notes = {'qwen3':'notes'}.get(args.notes,args.notes)
    if args.notes and args.notes not in ('notes','gemma','gptoss') and not args.notes.startswith('ollama:'): p.error('unsupported --notes model')
    output=(args.output or PROJECT/'reports/model-benchmarks'/time.strftime('%Y%m%d-%H%M%S')).resolve()
    # Reports are intentionally retained; extracted media and inference scratch are not.
    scratch=PROJECT/'tmp/meeting-benchmark'/('run-'+uuid.uuid4().hex);scratch.mkdir(parents=True)
    try:
        sys.path.insert(0,str(PROJECT/'service'))
        from echo_service.models import ModelAssets, MANIFEST
        available=ModelAssets(args.assets)
        speech=[args.asr];notes=[] if args.asr_only else [args.notes]
        selected=set(speech+[item for item in notes if not item.startswith('ollama:')])
        skipped=[dict(id=ident,reason='Not selected; not evaluated') for ident,item in MANIFEST['models'].items() if item.get('role') in ('speech','notes') and ident not in selected]
        for ident in selected:
            try: available.require(ident)
            except Exception as error: raise ValueError(f'Selected model {ident} is not verified installed: {error}') from error
        if args.check:
            if args.fixture:
                checked=load_corpus(args.fixture)
                if checked is None: load_fixture(args.fixture)
            else: load_archive(args.archive,scratch)
            print('Selected installed models: '+NAMES[args.asr]+' + '+(NAMES.get(args.notes,args.notes or 'no notes'))+'; fixture verified'); return
        if notes and not args.notes_runner.is_file(): raise ValueError('Build the notes runner first: scripts/build-benchmark.sh (or use scripts/run-model-benchmarks.sh)')
        corpus=load_corpus(args.fixture) if args.fixture else None
        if corpus:
            run_corpus(args,corpus,output); return
        output.mkdir(parents=True,exist_ok=True)
        if args.fixture:
            audio,refs,fixture_hash,archive_hash=load_fixture(args.fixture)
        else:
            audio,refs=load_archive(args.archive,scratch);archive_hash=digest(args.archive);fixture_hash=archive_hash
        import soundfile as sf
        info=sf.info(audio)
        reference=reference_text(refs['transcript.txt']);reference_tokens=normalized(reference)
        if not reference_tokens: raise ValueError('Reference transcript contains no words')
        source_paths=[Path(__file__),*sorted((PROJECT/'service/echo_service').glob('*.py'))]
        source_hash=hashlib.sha256(''.join(digest(x) for x in source_paths).encode()).hexdigest()
        identity=dict(fixture_sha256=fixture_hash,archive_sha256=archive_hash,audio_sha256=digest(audio),manifest_sha256=digest(PROJECT/'service/models.json'),pipeline=PIPELINE,source_sha256=source_hash)
        timestamped=refs.get('transcript-timestamped.txt')
        report=dict(schema=1,selected_pair=dict(asr=args.asr,notes=args.notes),identity=identity,audio=dict(seconds=info.duration,sample_rate=info.samplerate,channels=info.channels),reference_words=len(reference_tokens),timestamped_reference_matches=normalized(reference_text(timestamped))==reference_tokens if timestamped is not None else None,notes_reference_available='notes.txt' in refs,skipped_models=skipped,asr={},combinations={},limits=['Lexical summary overlap is not factual accuracy. Human review required.','Passage timestamps are not word-alignment ground truth.','Reference contains disfluencies and simultaneous speakers; single-stream WER penalizes order and formatting differences.','30-second bounded windows, 28-second ownership; native timing anchors select context-owned words; passage midpoint fallback is reported.','Whisper loads lazily; first-window time includes initial model load. Notes time includes load and generation.'])
        for name,text in refs.items(): (output/('reference-'+name)).write_text(text)
        env=env_for(scratch,args.assets)
        for engine in speech:
            target=output/engine;target.mkdir(exist_ok=True)
            key={**identity,'model':engine,'revision':MANIFEST['models'][engine]['revision']}
            meta=target/'asr-meta.json';result=target/'asr.json'
            reusable=args.resume and meta.exists() and result.exists() and json.loads(meta.read_text()).get('identity')==key
            if not reusable:
                print(f'ASR: {engine}, {info.duration/60:.1f} minutes',flush=True)
                worker=scratch/engine;worker.mkdir()
                try:
                    perf=process([sys.executable,str(Path(__file__).resolve()),'--assets',str(args.assets),'--scratch',str(worker),'--worker',engine,str(audio),str(result)],target/'asr.log',env)
                except Exception as error:
                    report['asr'][engine]=dict(status='failed',error=str(error)); atomic(output/'report.json',report); raise
                atomic(meta,dict(identity=key,performance=perf))
            data=json.loads(result.read_text());hypothesis=' '.join(s['text'] for s in data['segments'])
            (target/'transcript.txt').write_text(hypothesis+'\n')
            (target/'transcript-timestamped.txt').write_text('\n'.join(f"[{s['startTime']:.3f}] {s['text']}" for s in data['segments'])+'\n')
            counts=word_errors(reference_tokens,normalized(hypothesis))
            report['asr'][engine]=dict(model=MANIFEST['models'][engine]['repo'],revision=key['revision'],**counts,word_error_rate=sum(counts.values())/len(reference_tokens),hypothesis_words=len(normalized(hypothesis)),inference_seconds=data['inference_seconds'],real_time_factor=data['inference_seconds']/info.duration,constructor_seconds=data['constructor_seconds'],first_window_seconds=data['first_window_seconds'],peak_memory_bytes=data['peak_memory_bytes'],passage_fallbacks=data['passage_fallbacks'],reused=reusable)
            atomic(output/'report.json',report)
            for note in notes:
                case=f'{engine}+{note}';destination=target/note;destination.mkdir(exist_ok=True)
                ollama_note=note.startswith('ollama:')
                note_revision='discovered-at-run-time' if ollama_note else MANIFEST['models'][note]['revision']
                note_key={**key,'asr_sha256':digest(result),'notes_model':note,'notes_revision':note_revision,'runner_sha256':digest(args.notes_runner)}
                note_meta=destination/'meta.json';note_result=destination/'notes.json'
                reuse=args.resume and note_result.exists() and note_meta.exists() and json.loads(note_meta.read_text()).get('identity')==note_key
                try:
                    if not reuse:
                        print(f'Notes: {case}',flush=True)
                        command=[str(args.notes_runner),str(result),str(note_result),str(args.assets/'models'),str(PROJECT/'service/models.json'),note]
                        if not ollama_note: command=['/usr/bin/sandbox-exec','-p','(version 1)(allow default)(deny network*)',*command]
                        perf=process(command,destination/'notes.log',env)
                        atomic(note_meta,dict(identity=note_key,performance=perf))
                    result_notes=json.loads(note_result.read_text())
                    metrics=score_notes(result_notes['notes'],refs.get('notes.txt'),data['segments'])
                    status='completed' if metrics['reference_notes_available'] else 'completed_unscored'
                    report['combinations'][case]=dict(status=status,notes_provider=result_notes.get('provider','native'),notes_revision=result_notes.get('digest',note_key['notes_revision']),notes_repository=('Ollama local model' if ollama_note else MANIFEST['models'][note]['repo']),runtime_version=result_notes.get('runtimeVersion'),seconds=result_notes['elapsedSeconds'],performance=json.loads(note_meta.read_text())['performance'],**metrics,reused=reuse)
                    text='\n\n'.join('## '+key+'\n'+'\n'.join('- '+i['text']+' ['+', '.join(i['evidenceIDs'])+']' for i in result_notes['notes'][key]) for key in ('summary','decisions','actionItems'))
                    (destination/'notes.md').write_text(text+'\n')
                except Exception as error:
                    report['combinations'][case]=dict(status='failed',error=str(error))
                atomic(output/'report.json',report)
        lines=['# Local model accuracy benchmark','',f'Audio: {info.duration/60:.2f} minutes. Reference: {len(reference_tokens)} words.','', '| ASR | WER | Substitutions | Deletions | Insertions | Processing |','|---|---:|---:|---:|---:|---:|']
        for engine,r in report['asr'].items():lines.append(f"| {NAMES[engine]} | {r['word_error_rate']:.2%} | {r['substitutions']} | {r['deletions']} | {r['insertions']} | {r['inference_seconds']:.1f}s |")
        lines+=['','## Notes comparisons','','Lexical overlap is a diagnostic, not a correctness percentage. Review factual claims and omissions against the supplied reference.','', '| Combination | Status | ROUGE-1 F1 | ROUGE-2 F1 | ROUGE-L F1 | Invalid citations | Partial |','|---|---|---:|---:|---:|---:|---|']
        for case,r in report['combinations'].items():
            display=' + '.join(NAMES[x] for x in case.split('+'))
            if r['status']=='completed':
                m=r['lexical_overlap_deduplicated_lines'];lines.append(f"| {display} | completed | {m['rouge_1']['f1']:.3f} | {m['rouge_2']['f1']:.3f} | {m['rouge_l']['f1']:.3f} | {len(r['invalid_evidence_items'])} | {r['partial']} |")
            elif r['status']=='completed_unscored': lines.append(f"| {display} | generated; no reference notes | — | — | — | {len(r['invalid_evidence_items'])} | {r['partial']} |")
            else:lines.append(f'| {display} | failed; see report.json | — | — | — | — | — |')
        lines+=['','## Review checklist','','For each combination, mark Pass / Partial / Fail and cite a generated bullet plus the relevant source passage:','', '- Main topics and outcome coverage','- Correct final design decisions, distinguishing earlier proposals from final decisions','- Correct costs, quantities, owners, and deadlines','- No fabricated commitments or action items','- Each citation actually supports its claim (ID validity alone is insufficient)','- No important omissions; concise, non-repetitive summary','','## Limitations','',*['- '+x for x in report['limits']]]
        (output/'REPORT.md').write_text('\n'.join(lines)+'\n')
        print(f'Reports saved: {output}',flush=True)
        if any(r['status']=='failed' for r in report['combinations'].values()):raise RuntimeError('One or more notes cases failed; completed ASR results were preserved')
    finally:
        shutil.rmtree(scratch)

if __name__=='__main__':main()
