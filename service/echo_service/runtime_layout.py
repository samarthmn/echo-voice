"""Signed bundled code is separate from writable model and meeting storage."""
import os
from pathlib import Path


def community_environment(root):
    bundle = os.environ.get('ECHO_BUNDLED_RUNTIME')
    return Path(bundle) / 'community' if bundle else root / 'runtime/community-venv'


def community_python(root):
    return community_environment(root) / ('bin/python3.11' if os.environ.get('ECHO_BUNDLED_RUNTIME') else 'bin/python')
