"""Journaled deletion of catalog-owned assets; never touches meeting media."""
import json
import os
from pathlib import Path
import shutil
import uuid
from .models import MANIFEST, ModelAssets
from .paths import atomic_json, no_symlinks
from .errors import ServiceError

def selected_assets(selection):
    item=MANIFEST['models'].get(selection)
    if item is None or item.get('role') not in ('speech','notes','speakers','retired'):
        raise ServiceError('invalid_model','Choose a supported model.',400)
    return [selection]+item.get('dependencies',[])

def _purge(path):
    if path.is_symlink():path.unlink()
    elif path.is_dir():shutil.rmtree(path)
    elif path.exists():path.unlink()

def recover_removals(root):
    models=root/'models';no_symlinks(models)
    if not models.exists():return
    for journal in models.glob('.remove-*.json'):
        no_symlinks(journal)
        record=json.loads(journal.read_text())
        for entry in record['entries']:
            name=entry['name']; trash=entry['trash']
            if name not in MANIFEST['models'] or not trash.startswith('.removed-') or '/' in trash or '..' in trash:
                raise ServiceError('invalid_cleanup','Model cleanup record is invalid.',500)
            source=models/name
            if source.exists() or source.is_symlink():os.replace(source,models/trash)
            _purge(models/trash)
            repo=MANIFEST['models'][name]['repo']
            # A repo cache is owned by this application, not the user's global HF cache.
            other_installed=any(k!=name and v['repo']==repo and (models/k).exists() for k,v in MANIFEST['models'].items())
            if not other_installed:
                cache=models/'hub'/('models--'+repo.replace('/','--'))
                no_symlinks(cache.parent);_purge(cache)
        journal.unlink()

def remove_model(root,selection,*,in_use=()):
    names=selected_assets(selection)
    if set(names)&set(in_use):raise ServiceError('model_in_use','Stop processing before removing this model.',409,True)
    models=root/'models';no_symlinks(models);models.mkdir(parents=True,exist_ok=True)
    recover_removals(root)
    retained=set()
    for name,item in MANIFEST['models'].items():
        if name not in names and (models/name).exists():retained.update(item.get('dependencies',[]))
    names=[name for name in names if name==selection or name not in retained]
    record={'entries':[{'name':name,'trash':'.removed-'+name+'-'+uuid.uuid4().hex} for name in names]}
    journal=models/('.remove-'+uuid.uuid4().hex+'.json')
    atomic_json(journal,record);recover_removals(root)
    return names
