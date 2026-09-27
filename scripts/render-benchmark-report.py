#!/usr/bin/env python3
"""Render benchmark JSON as a standalone, offline HTML report."""
import argparse
import html
import json
import math
from pathlib import Path

NAMES = {'asr':'Whisper large-v3-turbo','parakeet':'Parakeet Unified English 0.6B','notes':'Qwen3 4B','gemma':'Gemma 4 E4B','gptoss':'GPT-OSS 20B'}
def escape(value): return html.escape(str(value), quote=True)
def number(value, places=1, suffix=''):
    return f'{value:,.{places}f}{suffix}' if isinstance(value,(float,int)) and math.isfinite(value) else '—'
def cell(value): return '<td>'+escape(value)+'</td>'
def table(headers, rows):
    return '<div class="table-wrap"><table><thead><tr>'+''.join('<th>'+escape(h)+'</th>' for h in headers)+'</tr></thead><tbody>'+''.join('<tr>'+''.join(cell(c) for c in row)+'</tr>' for row in rows)+'</tbody></table></div>'
def render(data):
    results=data.get('asr',{}); combinations=data.get('combinations',{})
    measured=any('word_error_rate' in r for r in results.values())
    failed=any(r.get('status')=='failed' for r in [*results.values(),*combinations.values()])
    notes_done=any(r.get('status')=='completed' for r in combinations.values())
    status='Needs attention' if failed else ('Results available' if measured else 'Accuracy test not run')
    seconds=data.get('audio',{}).get('seconds',data.get('duration_seconds'))
    duration=f'{int(seconds)//60}m {round(seconds)%60:02d}s' if seconds is not None else '—'
    selected=data.get('selected_pair',{})
    pair=' + '.join(NAMES.get(selected[k],selected[k]) for k in ('asr','notes') if selected.get(k)) or 'Not selected'
    identity=data.get('identity',data)
    asr_rows=[]
    for ident,row in results.items():
        if row.get('status')=='failed':asr_rows.append([NAMES.get(ident,ident),'Failed','—','—','—','—','—']);continue
        asr_rows.append([NAMES.get(ident,ident),number(row.get('word_error_rate',0)*100,2,'%'),row.get('substitutions','—'),row.get('deletions','—'),row.get('insertions','—'),number(row.get('inference_seconds'),1,' s'),number(row.get('peak_memory_bytes',0)/1024**3,2,' GiB')])
    notes_rows=[]
    for ident,row in combinations.items():
        name=' + '.join(NAMES.get(i,i) for i in ident.split('+'))
        metrics=row.get('lexical_overlap_deduplicated_lines',{})
        invalid=row.get('invalid_evidence_items','—')
        if isinstance(invalid,list): invalid=len(invalid)
        partial=row.get('partial',row.get('partial_cases'))
        notes_rows.append([name,row.get('status','Unknown').replace('_',' '),number(metrics.get('rouge_1',{}).get('f1'),3),number(metrics.get('rouge_2',{}).get('f1'),3),number(metrics.get('rouge_l',{}).get('f1'),3),invalid,('Yes' if partial else 'No') if partial is not None else '—',number(row.get('seconds'),1,' s')])
    checks=[]
    if 'unit_tests_passed' in data:checks.append(['Benchmark script checks',f"{data['unit_tests_passed']} passed"])
    if 'native_notes_runner_build' in data:checks.append(['Native notes runner build',data['native_notes_runner_build']])
    if 'synthetic_qwen_handoff' in data:checks.append(['Synthetic Qwen handoff',data['synthetic_qwen_handoff']])
    if 'timestamped_reference_matches' in data:checks.append(['Plain / timestamped reference consistency','Match' if data['timestamped_reference_matches'] else 'Mismatch — review before interpreting scores'])
    limits=data.get('limits',[
        'The full recording has not been evaluated. No ASR or notes accuracy score is available.',
        'The synthetic notes check verifies the runner, not accuracy on this meeting.',
        'Notes lexical overlap is not factual accuracy; claims and omissions require human review.',
        'Passage timestamps are not ground truth for individual word alignment.'
    ])
    revisions=[]
    for ident,row in results.items():
        if row.get('revision'):revisions.append([NAMES.get(ident,ident),row.get('model',''),row['revision'],'Native'])
    for ident,row in combinations.items():
        if row.get('notes_revision'):revisions.append([NAMES.get(ident.split('+')[-1],ident),row.get('notes_repository',''),row['notes_revision'],row.get('runtime_version') or row.get('notes_provider','Native')])
    errors=''.join('<p class="error">'+escape(r['error'])+'</p>' for r in [*results.values(),*combinations.values()] if r.get('error'))
    case_rows=[[row['id'],number(row['word_error_rate']*100,2,'%'),row['reference_words'],row['substitutions'],row['deletions'],row['insertions'],number(row['inference_seconds'],1,' s')] for row in data.get('per_case',[])]
    command='scripts/run-model-benchmarks.sh \\\n  --fixture test-fixtures/ami-meeting-corpus \\\n  --asr parakeet \\\n  --notes qwen3'
    body=f'''
<header><div class="eyebrow">ECHO VOICE · LOCAL MODEL EVALUATION</div><span class="badge {'warning' if failed or not measured else ''}">{escape(status)}</span>
<h1>Meeting benchmark</h1><p class="subtitle">Remote control design meeting</p>
<p class="intro">A clear record of speech recognition and meeting-notes performance. All processing runs locally.</p></header>
<div class="stats"><article><span>Recording</span><strong>{escape(duration)}</strong></article><article><span>Reference words</span><strong>{number(data.get('reference_words'),0)}</strong></article><article><span>Selected models</span><strong class="pair">{escape(pair)}</strong></article></div>
{errors}
<section><div class="section-heading"><h2>01 <span>Speech recognition</span></h2><span class="muted">Lower WER is better</span></div>
<p>Word error rate counts substitutions, deletions and insertions against the reference transcript. It is not a confidence score.</p>
{table(['Model','Word error rate','Substitutions','Deletions','Insertions','Inference time','Peak memory'],asr_rows) if asr_rows else '<div class="empty"><strong>No ASR results yet</strong><p>The full recording has not been transcribed by a selected model for this benchmark. A missing result is not a zero error rate.</p></div>'}</section>
{('<section><div class="section-heading"><h2>Per-recording results</h2><span class="muted">Micro aggregate above</span></div>'+table(['Recording','WER','Reference words','Substitutions','Deletions','Insertions','Processing'],case_rows)+'</section>') if case_rows else ''}
<section><div class="section-heading"><h2>02 <span>Meeting notes</span></h2><span class="muted">Lexical overlap + evidence checks</span></div>
<p>{'No reference notes were supplied. Generated notes are available for human review; only evidence-link structure and owner/deadline grounding are checked automatically.' if data.get('notes_reference_available') is False else 'ROUGE measures overlap with the supplied notes. A high score does not establish factual correctness, and valid citation IDs do not prove that a claim is supported.'}</p>
{table(['Model pair','Status','ROUGE-1 F1','ROUGE-2 F1','ROUGE-L F1','Invalid citations','Partial draft','Time'],notes_rows) if notes_rows else '<div class="empty"><strong>No meeting-notes evaluation yet</strong><p>The notes model will receive the generated transcript, without seeing the reference answers.</p></div>'}
</section>
<section><h2>03 <span>Verification & scope</span></h2>{table(['Check','Result'],checks) if checks else '<p>See the model results and limitations below for this run.</p>'}
<ul>{''.join('<li>'+escape(x)+'</li>' for x in limits)}</ul></section>
<section><h2>04 <span>Run a selected pair</span></h2><p>Example: Parakeet + Qwen3. Change the model arguments to run another pair. Only installed, explicitly selected models run.</p><pre><code>{escape(command)}</code></pre><p class="muted">Every run writes REPORT.html, REPORT.md and report.json alongside its generated transcripts and notes.</p></section>
<details><summary>Provenance and model revisions</summary><dl><dt>Fixture</dt><dd>{escape(data.get('fixture','See input hashes below'))}</dd><dt>Archive SHA-256</dt><dd>{escape(identity.get('archive_sha256','Not available'))}</dd><dt>Fixture SHA-256</dt><dd>{escape(identity.get('fixture_sha256','Not available'))}</dd></dl>{table(['Model','Repository','Revision / digest','Runtime'],revisions) if revisions else '<p>No model inference revisions recorded for a full run yet.</p>'}</details>
<footer>Self-contained report · No external scripts, fonts, analytics or network requests · Missing results are shown explicitly.</footer>
'''
    css='''
:root{color-scheme:light dark;--bg:#f5f6f4;--card:#fff;--text:#202d29;--muted:#64716b;--line:#dfe5df;--accent:#286450;--soft:#edf3ef;--warn:#81581a}*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--text);font:15px/1.65 -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif}main{max-width:1120px;margin:auto;padding:56px 28px}header{position:relative;margin-bottom:30px}.eyebrow{font-size:11px;letter-spacing:.15em;font-weight:700;color:var(--accent)}h1{font-size:44px;line-height:1.12;letter-spacing:-.04em;margin:22px 0 8px}h2{font-size:14px;color:var(--accent);margin:0 0 15px;font-weight:600}h2 span{font-size:21px;color:var(--text);margin-left:14px;letter-spacing:-.02em}.subtitle{font-size:21px;margin:0;color:var(--muted)}.intro{max-width:650px;color:var(--muted);margin:16px 0}.badge{display:inline-block;float:right;border:1px solid var(--line);border-radius:30px;padding:5px 13px;font-size:12px;font-weight:600;color:var(--accent);background:var(--card)}.warning{color:var(--warn)}.stats{display:grid;grid-template-columns:1fr 1fr 2fr;gap:14px;margin-bottom:30px}.stats article{padding:20px 24px;background:var(--card);border:1px solid var(--line);border-radius:12px}.stats span{display:block;font-size:12px;color:var(--muted)}.stats strong{display:block;font-size:28px;letter-spacing:-.03em;font-variant-numeric:tabular-nums}.stats .pair{font-size:18px;padding-top:7px}section{background:var(--card);border:1px solid var(--line);border-radius:12px;padding:26px;margin-bottom:18px}section>p{color:var(--muted);max-width:900px}.section-heading{display:flex;justify-content:space-between;align-items:baseline;gap:16px}.muted{color:var(--muted);font-size:12px}.empty{background:var(--soft);border-radius:8px;padding:20px 22px}.empty p{margin:4px 0 0;color:var(--muted);font-size:14px}.table-wrap{overflow:auto}table{width:100%;border-collapse:collapse;font-size:13px;text-align:left;font-variant-numeric:tabular-nums}th{font-size:11px;color:var(--muted);font-weight:600;white-space:nowrap}th,td{padding:12px;border-bottom:1px solid var(--line);vertical-align:top}td:first-child{font-weight:500}tr:last-child td{border-bottom:0}pre{padding:20px;background:var(--soft);border-radius:8px;overflow:auto;font:13px/1.8 ui-monospace,SFMono-Regular,monospace}ul{padding-left:20px;color:var(--muted);font-size:13px}li{margin:8px 0}details{padding:18px 24px;border:1px solid var(--line);border-radius:12px}summary{cursor:pointer;font-weight:600}dl{font-size:12px}dt{color:var(--muted);margin-top:12px}dd{margin:0;overflow-wrap:anywhere;font-family:ui-monospace,monospace}footer{font-size:11px;color:var(--muted);margin-top:28px}.error{border-left:3px solid var(--warn);padding:14px;background:var(--card);overflow-wrap:anywhere}@media(prefers-color-scheme:dark){:root{--bg:#171d1a;--card:#202924;--text:#e2eae4;--muted:#a5b3a9;--line:#36433a;--accent:#9ac8b1;--soft:#27362d;--warn:#ebc58b}}@media(max-width:650px){main{padding:30px 16px}h1{font-size:36px}.badge{float:none;margin-top:14px}.stats{grid-template-columns:1fr 1fr}.stats article:last-child{grid-column:1/-1}.section-heading{display:block}section{padding:20px}}@media print{body{background:white;color:black}main{padding:0}section{break-inside:avoid}.badge{float:none}details{display:block}footer{margin-top:15px}}
'''
    return '<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta http-equiv="Content-Security-Policy" content="default-src \'none\'; style-src \'unsafe-inline\'; base-uri \'none\'; form-action \'none\'"><title>Echo Voice · Meeting benchmark</title><style>'+css+'</style></head><body><main>'+body+'</main></body></html>'

def write_report(data, destination):
    destination=Path(destination);destination.parent.mkdir(parents=True,exist_ok=True)
    stage=destination.with_name(destination.name+'.partial');stage.write_text(render(data));stage.replace(destination)

if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('input',type=Path);parser.add_argument('output',type=Path);args=parser.parse_args()
    write_report(json.loads(args.input.read_text()),args.output)
    print(args.output.resolve())
