"""Literal vocabulary hints/corrections. Recognition output remains recoverable."""
import re
import unicodedata
from difflib import SequenceMatcher

def normalize(value):
    return ' '.join(unicodedata.normalize('NFKC',value).split())

def validate_entries(entries):
    if sum(e.get('enabled',True) for e in entries)>500: raise ValueError('Use at most 500 vocabulary entries.')
    output=[]; spellings=set(); aliases={}; ids=set()
    for entry in entries:
        spelling=normalize(entry['spelling'])
        ident=str(entry['id'])
        if not spelling or len(spelling)>50 or spelling.casefold() in spellings or not ident or ident in ids:
            raise ValueError('Vocabulary needs unique IDs and spellings of 1–50 characters.')
        spellings.add(spelling.casefold()); ids.add(ident)
        values=[]
        for value in entry.get('aliases',[]):
            alias=normalize(value)
            if not alias or len(alias)>50:raise ValueError('Aliases must contain 1–50 characters.')
            key=alias.casefold()
            if key in aliases and aliases[key]!=ident:raise ValueError('An alias can belong to only one spelling.')
            aliases[key]=ident
            if alias not in values:values.append(alias)
        output.append(dict(id=ident,spelling=spelling,aliases=values,enabled=entry.get('enabled',True),important=entry.get('important',False)))
    for entry in output:
        key=entry['spelling'].casefold()
        if key in aliases and aliases[key]!=entry['id']:raise ValueError('An alias cannot replace a different preferred spelling.')
    return output

def prompt_terms(entries,encode,budget=200):
    selected=[]
    for entry in sorted(entries,key=lambda x:(not x.get('important',False),x['spelling'].casefold(),x['id'])):
        if not entry.get('enabled',True):continue
        candidate=', '.join(selected+[entry['spelling']])
        if len(encode(candidate))<=budget:selected.append(entry['spelling'])
    return ', '.join(selected)

def correct(text,entries,*,fuzzy=False):
    enabled=[e for e in entries if e.get('enabled',True)]
    candidates=[]
    for entry in enabled:
        for alias in entry['aliases']:
            pattern=r'(?<!\w)'+r'\s+'.join(re.escape(p) for p in alias.split())+r'(?!\w)'
            for match in re.finditer(pattern,text,re.IGNORECASE):
                candidates.append((match.start(),match.end(),entry))
    # Conservative opt-in spelling correction; ambiguous or common short words are untouched.
    if fuzzy:
        for match in re.finditer(r'\b[A-Za-z]{5,}\b',text):
            if re.search(r'[@:/\d]',text[max(0,match.start()-1):min(len(text),match.end()+1)]):continue
            scores=[]
            for entry in enabled:
                target=entry['spelling']
                if not re.fullmatch(r'[A-Za-z]{5,}',target) or abs(len(target)-len(match.group()))>2:continue
                score=1-SequenceMatcher(None,match.group().lower(),target.lower()).ratio()
                if 0<score<=0.18:scores.append((score,entry['id'],entry))
            scores.sort(key=lambda x:(x[0],x[1]))
            if scores and (len(scores)==1 or scores[1][0]-scores[0][0]>=0.08):
                candidates.append((match.start(),match.end(),scores[0][2]))
    candidates.sort(key=lambda x:(x[0],-(x[1]-x[0]),x[2]['id']))
    output=[]; changes=[]; cursor=0; length=0
    for begin,end,entry in candidates:
        if begin<cursor:continue
        prefix=text[cursor:begin]; output.append(prefix);length+=len(prefix)
        replacement=entry['spelling']; output.append(replacement)
        changes.append(dict(entry_id=entry['id'],original_start=begin,original_end=end,start=length,end=length+len(replacement)))
        length+=len(replacement);cursor=end
    output.append(text[cursor:])
    return ''.join(output),changes
