"""Only called by an explicit Community-1 installation request."""
import hashlib
import os
from pathlib import Path
import subprocess
import sys
from .paths import no_symlinks, atomic_json
from .errors import ServiceError

def install_runtime(root, progress):
    if os.environ.get('ECHO_BUNDLED_RUNTIME'):
        from .runtime_layout import community_environment, community_python
        environment = community_environment(root)
        if not community_python(root).is_file() or not (environment / '.echo-runtime.json').is_file():
            raise ServiceError('runtime_unavailable', 'Reinstall Echo Voice to restore its bundled speaker runtime.', 503)
        progress(stage='runtime', status='Using the speaker runtime included with Echo Voice')
        return
    runtime = root / 'runtime'
    environment = runtime / 'community-venv'
    lock = Path(__file__).parents[1] / 'community' / 'requirements.lock'
    uv = runtime / 'bin' / 'uv'
    for path in (environment, lock, uv): no_symlinks(path)
    if not lock.is_file() or not uv.is_file():
        raise ServiceError('runtime_unavailable', 'Repair the speech runtime before installing Community-1.', 503)
    progress(stage='runtime', status='Installing the isolated Community-1 runtime')
    env = dict(os.environ)
    env['UV_CACHE_DIR'] = str(runtime / 'cache' / 'uv')
    try:
        subprocess.run([str(uv), 'venv', '--python', sys.executable, str(environment), '--allow-existing'], env=env, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        subprocess.run([str(uv), 'pip', 'sync', '--python', str(environment / 'bin' / 'python'), '--require-hashes', str(lock)], env=env, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        atomic_json(environment / '.echo-runtime.json', {'lock_sha256': hashlib.sha256(lock.read_bytes()).hexdigest(), 'pyannote': '4.0.4'})
    except subprocess.CalledProcessError:
        raise ServiceError('runtime_unavailable', 'Community-1 runtime setup failed. Verified downloads are retained for retry.', 503, True) from None
