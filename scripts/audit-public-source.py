#!/usr/bin/env python3
"""Report risky publication paths and secret-shaped values without printing their contents."""
import json
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]
PATTERNS = [re.compile(rb'-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----'), re.compile(rb'\bhf_[A-Za-z0-9]{24,}\b'), re.compile(rb'\b(?:ghp_|github_pat_)[A-Za-z0-9_]{30,}\b'), re.compile(rb'\bsk-[A-Za-z0-9_-]{32,}\b')]
PRIVATE_SUFFIXES = {'.wav', '.flac', '.caf', '.sqlite', '.p12', '.cer', '.key'}
INTERNAL_HISTORY = {'docs/CONTRACTS.md', 'docs/IMPLEMENTATION.md', 'docs/VALIDATION.md', 'service/README.md'}

def git(*args): return subprocess.check_output(['git', '-C', str(ROOT), *args])
def findings(data, path):
    result = []
    if any(pattern.search(data) for pattern in PATTERNS): result.append({'path': path, 'kind': 'secret-shaped value; inspect privately'})
    if Path(path).suffix.lower() in PRIVATE_SUFFIXES and not path.startswith('Resources/Demo/'):
        result.append({'path': path, 'kind': 'private-media/database/signing-material candidate'})
    return result

if __name__ == '__main__':
    results = []
    files = git('ls-files', '--cached', '--others', '--exclude-standard', '-z').decode().split('\0')
    for name in files:
        path = ROOT / name
        if name and path.is_file(): results += findings(path.read_bytes(), name)
    commits = git('rev-list', '--all').decode().splitlines()
    checked = set()
    for commit in commits:
        for entry in git('ls-tree', '-rz', commit).split(b'\0'):
            if not entry: continue
            header, name = entry.split(b'\t', 1)
            mode, kind, oid = header.decode().split()
            if kind != 'blob' or (oid, name) in checked: continue
            checked.add((oid, name))
            historical_path = name.decode()
            if historical_path in INTERNAL_HISTORY or historical_path.startswith(('docs/evidence/', 'docs/plans/')):
                results.append({'path': commit[:12] + ':' + historical_path, 'kind': 'internal document present in Git history; publish a clean-history export'})
            results += findings(git('cat-file', 'blob', oid), commit[:12] + ':' + name.decode())
    print(json.dumps({'workingFiles': len([f for f in files if f]), 'commits': len(commits), 'historicalBlobs': len(checked), 'findings': results, 'limitations': 'Pattern scan only; review notices, generated screenshots and arbitrary credentials manually before publishing.'}, indent=2))
    raise SystemExit(1 if results else 0)
