"""Times remain in source audio seconds; ranges are UTF-16 offsets for AppKit."""
import math
import re

def utf16_length(text):return len(text.encode('utf-16-le'))//2

def locate(text,word,cursor):
    word=word.strip()
    if not word:return None
    match=re.search(re.escape(word),text[cursor:],flags=re.IGNORECASE)
    if not match:return None
    return cursor+match.start(),cursor+match.end()

def whisper_words(items,text,offset,duration):
    result=[];cursor=0;last=0.
    for item in items:
        start=float(item.get('start',float('nan')));end=float(item.get('end',float('nan')))
        span=locate(text,str(item.get('word','')),cursor)
        if not span or not math.isfinite(start) or not math.isfinite(end) or start<last-0.001 or start<0 or end<=start or end>duration+0.1:return []
        begin,stop=span
        result.append(dict(text=text[begin:stop],location=utf16_length(text[:begin]),length=utf16_length(text[begin:stop]),start=start+offset,end=min(end,duration)+offset,source='nativeWord',derived=False,probability=item.get('probability')))
        cursor=stop;last=start
    return result

def parakeet_words(tokens,timestamps,text,offset,duration):
    if len(tokens)!=len(timestamps):return []
    groups=[];last=-1.
    for token,time in zip(tokens,timestamps):
        time=float(time)
        if not math.isfinite(time) or time<last or time<0 or time>duration:return []
        last=time
        if token.startswith(('▁',' ')) or not groups:groups.append([token.lstrip('▁ '),time])
        else:groups[-1][0]+=token
    if ''.join(re.findall(r'\w+', ' '.join(g[0] for g in groups))).casefold()!= ''.join(re.findall(r'\w+',text)).casefold():return []
    result=[];cursor=0
    for word,time in groups:
        span=locate(text,word,cursor)
        if not span:return []
        begin,stop=span
        result.append(dict(text=text[begin:stop],location=utf16_length(text[:begin]),length=utf16_length(text[begin:stop]),start=time+offset,end=None,source='tokenEmission',derived=True,probability=None))
        cursor=stop
    return result

def corrected_words(original,corrected,words,changes):
    if not changes:return words
    # Preserve unaffected words and align each explicit replacement to its source span.
    result=[];consumed=set()
    for change in changes:
        lo=utf16_length(original[:change['original_start']]);hi=utf16_length(original[:change['original_end']])
        matching=[(i,w) for i,w in enumerate(words) if w['location']<hi and w['location']+w['length']>lo]
        if matching:
            consumed.update(i for i,_ in matching)
            first=matching[0][1];last=matching[-1][1]
            result.append({**first,'text':corrected[change['start']:change['end']],'location':utf16_length(corrected[:change['start']]),'length':utf16_length(corrected[change['start']:change['end']]),'end':last['end']})
    for index,word in enumerate(words):
        if index in consumed:continue
        shift=0
        for change in changes:
            if utf16_length(original[:change['original_end']])<=word['location']:
                shift+=utf16_length(corrected[change['start']:change['end']])-utf16_length(original[change['original_start']:change['original_end']])
        result.append({**word,'location':word['location']+shift})
    return sorted(result,key=lambda w:w['location'])
