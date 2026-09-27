#!/usr/bin/env python3
"""Short offline startup check; does not record audio, download models or run inference."""
import argparse
import json
import os
from pathlib import Path
import secrets
import select
import signal
import subprocess
import urllib.request
import urllib.error


def verify(app, data_root):
    resources = app.resolve() / 'Contents/Resources'
    runtime = resources / 'EchoRuntime'
    data_root.mkdir(parents=True, exist_ok=True)
    environment = {key: value for key, value in os.environ.items() if key in ('HOME', 'USER', 'LANG', 'PATH')}
    environment.update(ECHO_DATA_ROOT=str(data_root.resolve()), ECHO_BUNDLED_RUNTIME=str(runtime),
                       ECHO_VOICESTUDIO_ROOT=str(runtime / 'vendor/VoiceStudio'),
                       ECHO_PARENT_PID=str(os.getpid()), PYTHONPATH=str(resources/'service'),
                       PYTHONDONTWRITEBYTECODE='1', HF_HUB_OFFLINE='1', TRANSFORMERS_OFFLINE='1',
                       HF_HUB_DISABLE_TELEMETRY='1', TMPDIR=str(data_root.resolve()),
                       MPLCONFIGDIR=str(data_root/'matplotlib'), XDG_CACHE_HOME=str(data_root/'cache'))
    token = secrets.token_hex(32)
    child = subprocess.Popen([str(runtime/'speech/bin/python3.11'), '-m', 'echo_service', 'serve', '--port', '0'],
                             env=environment, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    try:
        child.stdin.write(json.dumps({'token': token})+'\n'); child.stdin.close()
        if not select.select([child.stdout], [], [], 45)[0]: raise RuntimeError('Service startup timed out')
        line = child.stdout.readline()
        if not line: raise RuntimeError('Service failed to start: '+child.stderr.read()[:2000])
        port = json.loads(line)['port']
        url = f'http://127.0.0.1:{port}/echo/v1/health'
        request = urllib.request.Request(url, headers={'Authorization': 'Bearer '+token})
        with urllib.request.urlopen(request, timeout=15) as response: health=json.load(response)
        try:
            urllib.request.urlopen(url, timeout=5)
            raise RuntimeError('Unauthenticated health request was accepted')
        except urllib.error.HTTPError as error:
            if error.code != 401: raise
        result={'service_startup':'passed','authenticated_health':'passed','unauthenticated_request':'rejected', 'inference':'not_run','health':health}
        print(json.dumps(result, indent=2))
    finally:
        if child.poll() is None:
            child.send_signal(signal.SIGINT)
            try: child.wait(timeout=10)
            except subprocess.TimeoutExpired: child.kill(); child.wait()

if __name__ == '__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app',type=Path,required=True)
    parser.add_argument('--data-root',type=Path,required=True,help='An isolated, disposable directory under project tmp')
    args=parser.parse_args(); verify(args.app,args.data_root)
