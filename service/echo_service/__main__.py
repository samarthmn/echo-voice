import argparse
import asyncio
import json
import logging
import os
from pathlib import Path
import socket
import sys
from .environment import configure
from .errors import ServiceError


def stdin_config(required=False):
    # One bounded line. Tokens are neither command-line arguments nor saved.
    if not required and sys.stdin.isatty():
        return {}
    line = sys.stdin.readline(16385)
    if not line.strip() and not required:
        return {}
    if len(line) > 16384:
        raise ValueError("invalid startup configuration")
    config = json.loads(line)
    if not isinstance(config, dict):
        raise ValueError("invalid startup configuration")
    return config


async def serve(root, port, token):
    import uvicorn
    from .api import create_app
    app = create_app(root, token)
    server = uvicorn.Server(uvicorn.Config(app, host="127.0.0.1", port=port, log_config=None, access_log=False, log_level="critical", timeout_graceful_shutdown=3, proxy_headers=False, server_header=False))
    listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    listener.bind(("127.0.0.1", port))
    listener.listen(128)
    listener.setblocking(False)
    parent = int(os.environ.get("ECHO_PARENT_PID", "0"))
    async def parent_watch():
        import psutil
        parent_start = psutil.Process(parent).create_time() if parent and psutil.pid_exists(parent) else None
        while not server.should_exit:
            await asyncio.sleep(1)
            if parent:
                try:
                    exists = psutil.Process(parent).create_time() == parent_start
                except psutil.Error:
                    exists = False
                if not exists:
                    app.state.service.unload()
                    server.should_exit = True
                    return
    watch = asyncio.create_task(parent_watch())
    print(json.dumps({"port": listener.getsockname()[1], "protocol": "echo.v1"}), flush=True)
    try:
        await server.serve(sockets=[listener])
    finally:
        watch.cancel()
        await app.state.service.close()
        listener.close()


def main():
    parser = argparse.ArgumentParser(prog="echo_service")
    commands = parser.add_subparsers(dest="command", required=True)
    start = commands.add_parser("serve")
    start.add_argument("--port", type=int, default=0)
    setup = commands.add_parser("setup")
    setup.add_argument("--data-root", required=True, type=Path)
    from .models import MANIFEST
    choices = tuple(k for k,v in MANIFEST["models"].items() if v.get("role") in ("speech", "notes", "speakers"))
    setup.add_argument("--models", choices=choices + ("all",), required=True)
    setup.add_argument("--stage-only", action="store_true")
    activate = commands.add_parser("activate-model")
    activate.add_argument("--data-root", required=True, type=Path)
    activate.add_argument("--model", choices=choices, required=True)
    remove = commands.add_parser("remove-model")
    remove.add_argument("--data-root", required=True, type=Path)
    remove.add_argument("--model", choices=choices + ("vision",), required=True)
    args = parser.parse_args()
    if args.command == "setup" and args.stage_only and args.models == "all":
        parser.error("--stage-only requires a single model selection")
    logging.disable(logging.CRITICAL)
    try:
        if args.command == "activate-model":
            from .installer import activate_models
            activate_models(args.data_root.absolute(), args.model)
        elif args.command == "remove-model":
            from .model_lifecycle import remove_model
            removed = remove_model(args.data_root.absolute(), args.model)
            print(json.dumps({"stage":"complete","status":"removed","models":removed}), flush=True)
        elif args.command == "setup":
            from .installer import install_models
            config = stdin_config()
            token = config.pop("token", config.pop("hf_token", None))
            if args.stage_only:
                from .installer import stage_models
                stage_models(args.data_root.absolute(), args.models, token)
            else:
                install_models(args.data_root.absolute(), args.models, token)
        else:
            root_string = os.environ.get("ECHO_DATA_ROOT")
            if not root_string or not 0 <= args.port <= 65535:
                raise ValueError("invalid service configuration")
            root = Path(root_string).absolute()
            configure(root)
            config = stdin_config(required=True)
            token = config.pop("token")
            if not isinstance(token, str):
                raise ValueError("invalid token")
            asyncio.run(serve(root, args.port, token))
        return 0
    except ServiceError as error:
        print(json.dumps(error.payload()), file=sys.stderr if args.command == "serve" else sys.stdout, flush=True)
        return 1
    except KeyboardInterrupt:
        # Uvicorn completes shutdown, then re-raises the intentional SIGINT.
        return 0 if args.command == "serve" else 130
    except Exception:
        print(json.dumps({"error": {"code": "startup_failed", "message": "The local helper could not complete the operation.", "retryable": True}}), file=sys.stderr if args.command == "serve" else sys.stdout, flush=True)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
