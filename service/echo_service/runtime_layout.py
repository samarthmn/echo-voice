"""Signed bundled code is separate from writable model and meeting storage."""
import os
from pathlib import Path


def activate_worker_environment():
    """Undo spawn's inherited site-packages when using a different interpreter.

    multiprocessing copies the parent's sys.path even after set_executable.
    Community-1 must import its pinned pyannote 4 environment, not speech's
    pyannote 3 dependencies. Keep application source paths and standard library.
    """
    import site
    import sys
    own_packages = list(dict.fromkeys(site.getsitepackages([sys.prefix, sys.exec_prefix])))
    application_paths = [entry for entry in sys.path
                         if not {'site-packages', 'dist-packages'}.intersection(Path(entry).parts)]
    sys.path[:] = own_packages + [entry for entry in application_paths if entry not in own_packages]


def community_environment(root):
    bundle = os.environ.get('ECHO_BUNDLED_RUNTIME')
    return Path(bundle) / 'community' if bundle else root / 'runtime/community-venv'


def community_python(root):
    return community_environment(root) / ('bin/python3.11' if os.environ.get('ECHO_BUNDLED_RUNTIME') else 'bin/python')
