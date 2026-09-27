#!/usr/bin/env python3
"""Generate the dependency-free landing page from reviewed screenshots and release state."""
import base64
import html
import json
from pathlib import Path
import re
from urllib.parse import urlparse
ROOT=Path(__file__).resolve().parents[1]

def render():
    release=json.loads((ROOT/'website/release.json').read_text())
    version=release['version']
    if not re.fullmatch(r'\d+\.\d+\.\d+',version): raise ValueError('Invalid version')
    direct=release['direct']; store=release['appStore']
    def button(label,url=None,secondary=False):
        css='button'+(' secondary' if secondary else '')
        return f'<a class="{css}" href="{html.escape(url,quote=True)}">{label}</a>' if url else f'<button class="{css}" type="button" disabled>{label}</button>'
    if direct['available']:
        expected=f'https://github.com/samarthmn/echo-voice/releases/download/v{version}/Echo-Voice-{version}-arm64.dmg'
        if direct['url']!=expected or not re.fullmatch(r'[0-9a-f]{64}',direct.get('sha256') or ''): raise ValueError('A verified versioned release asset and checksum are required')
    if store['available'] and (not isinstance(store['url'],str) or not re.fullmatch(r'https://apps\.apple\.com/(?:[a-z]{2}/)?app/[a-z0-9-]+/id\d+',store['url'])): raise ValueError('Use the approved public Store listing URL')
    values={'version':version,'directButton':button('Download for Mac',direct['url'] if direct['available'] else None),'storeButton':button('Mac App Store',store['url'] if store['available'] else None,True),'directStatus':'Direct download available.' if direct['available'] else 'Direct download: signing and release qualification pending.','storeStatus':'Available on the Mac App Store.' if store['available'] else 'Mac App Store: not available; submission is deferred.','canonical':''}
    canonical=release.get('canonical')
    if canonical:
        if urlparse(canonical).scheme!='https': raise ValueError('Canonical website must use HTTPS')
        values['canonical']='<link rel="canonical" href="'+html.escape(canonical,quote=True)+'">'
    structured={'@context':'https://schema.org','@type':'SoftwareApplication','name':'Echo Voice','softwareVersion':version,'operatingSystem':'macOS 14.2 or later, Apple Silicon','applicationCategory':'ProductivityApplication','license':'https://github.com/samarthmn/echo-voice/blob/main/LICENSE','description':'A local meeting workspace with transcription, notes and audio-linked review. Public release qualification is pending.'}
    if direct['available']: structured['downloadUrl']=direct['url']
    if canonical: structured['url']=canonical
    values['structured']=json.dumps(structured).replace('<','\\u003c')
    for key,file in [('transcriptImage','transcript.jpg'),('notesImage','notes.jpg'),('setupImage','in-person.jpg')]:
        values[key]='data:image/jpeg;base64,'+base64.b64encode((ROOT/'docs/screenshots'/file).read_bytes()).decode()
    catalog=json.loads((ROOT/'service/models.json').read_text())['models']
    def size(model):
        ids=set()
        def visit(i):
            if i in ids:return
            ids.add(i)
            for dependency in catalog[i].get('dependencies',[]):visit(dependency)
        visit(model)
        value=sum(sum(f['size'] for f in catalog[i]['files']) for i in ids)
        return f'{value/1e9:.2f} GB' if value>=1e9 else f'{value/1e6:.1f} MB'
    rows=[]
    for label,ids in [('Speech recognition',['parakeet','asr']),('Meeting notes',['notes','gemma','gptoss']),('Speaker grouping',['diarization','community1'])]:
        rows.append('<tr><td>'+label+'</td><td>'+'<br>'.join(html.escape(catalog[i]['display_name']) for i in ids)+'</td><td>'+'<br>'.join(size(i) for i in ids)+'</td></tr>')
    values['models']=''.join(rows)
    page=(ROOT/'website/echo-voice.template.html').read_text()
    page=re.sub(r'\{\{([A-Za-z]+)\}\}',lambda m:values[m[1]],page)
    if '{{' in page:raise ValueError('Unresolved template field')
    (ROOT/'website/echo-voice.html').write_text(page)
if __name__=='__main__':render()
