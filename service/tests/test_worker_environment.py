import sys
from unittest.mock import patch

from echo_service.runtime_layout import activate_worker_environment


def test_spawn_uses_child_dependencies_and_preserves_service_source():
    original = sys.path[:]
    try:
        sys.path[:] = ['/app/service', '/runtime/speech/lib/python3.11/site-packages',
                       '/runtime/community/lib/python3.11', '/user/lib/dist-packages', '']
        with patch('site.getsitepackages', return_value=['/runtime/community/lib/python3.11/site-packages']):
            activate_worker_environment()
        assert sys.path == ['/runtime/community/lib/python3.11/site-packages', '/app/service',
                            '/runtime/community/lib/python3.11', '']
    finally:
        sys.path[:] = original
