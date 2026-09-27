"""Explicit, resumable downloads of immutable, checksum-verified model files."""
import json
import os
from pathlib import Path
import shutil
import uuid
import threading
from . import models
from .environment import configure
from .errors import ServiceError
from .paths import atomic_json, no_symlinks


def progress(**fields):
    print(json.dumps(fields, separators=(",", ":")), flush=True)


def install_models(root: Path, selection: str, token: str | None, *, downloader=None):
    configure(root, offline=False)
    if downloader is None:
        from huggingface_hub import hf_hub_download
        downloader = hf_hub_download
    from .model_lifecycle import selected_assets, recover_removals
    recover_removals(root)
    if selection == "all":
        # Explicit CLI selection only; the app never invokes all-model setup.
        names = list(dict.fromkeys(asset for key,value in models.MANIFEST["models"].items() if value.get("role") in ("speech","notes","speakers") for asset in selected_assets(key)))
    else:
        names = selected_assets(selection)
    assets = models.ModelAssets(root)
    for name in names:
        item = models.MANIFEST["models"][name]
        destination = assets.path(name)
        no_symlinks(destination.parent)
        destination.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        receipt = []
        total_bytes = sum(entry['size'] for entry in item['files'])
        completed_bytes = 0
        progress(stage="model", model=name, status="checking", revision=item["revision"])
        if assets.ready(name):
            progress(stage="model", model=name, status="ready")
            continue
        if (destination.exists() or destination.is_symlink()) and not assets.clean_layout(name):
            quarantine = destination.with_name(".quarantine-" + item["revision"] + "-" + uuid.uuid4().hex)
            # Rename the directory entry itself; never traverse a snapshot link.
            destination.rename(quarantine)
            progress(stage="model", model=name, status="repairing", quarantine=str(quarantine.relative_to(root)))
        destination.mkdir(parents=True, exist_ok=True, mode=0o700)
        quarantines = list(destination.parent.glob(".quarantine-" + item["revision"] + "-*"))
        for index, file in enumerate(item["files"]):
            output = destination / file["path"]
            no_symlinks(output)
            output.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
            expected = file["sha256"] or file["git_blob_sha1"]
            valid = output.is_file() and output.stat().st_size == file["size"] and models.digest(output, git_blob=file["sha256"] is None) == expected
            if not valid:
                # Reuse only individually verified regular files, including on
                # a retry after interrupted repair. Unknown files stay quarantined.
                for quarantine in quarantines:
                    candidate = quarantine / file["path"]
                    try:
                        no_symlinks(candidate)
                        if candidate.is_file() and candidate.stat().st_size == file["size"] and models.digest(candidate, git_blob=file["sha256"] is None) == expected:
                            os.replace(candidate, output)
                            valid = True
                            break
                    except (OSError, ServiceError):
                        continue
            if not valid:
                progress(stage="download", model=name, file=file["path"], index=index + 1, total=len(item["files"]), bytes=file["size"])
                free = shutil.disk_usage(root).free
                if free < file['size'] * 2 + 1024**3:
                    raise ServiceError('disk_space', 'Free space for the download, verified copy, and a 1 GB reserve before retrying.', 503, True)
                stopped = threading.Event()
                partial_file = root / 'models' / 'hub' / ('models--' + item['repo'].replace('/', '--')) / 'blobs' / (expected + '.incomplete')
                def report_bytes():
                    while not stopped.wait(0.5):
                        try: transferred = min(file['size'], partial_file.stat().st_size)
                        except OSError: transferred = 0
                        progress(stage='download', model=name, completed_bytes=completed_bytes+transferred, total_bytes=total_bytes, status=f"Downloading {item.get('display_name', name)}: {completed_bytes+transferred:,} / {total_bytes:,} bytes")
                monitor = threading.Thread(target=report_bytes, daemon=True); monitor.start()
                try:
                    downloaded = Path(downloader(repo_id=item["repo"], filename=file["path"], revision=item["revision"], token=token or False, cache_dir=str(root / "models" / "hub"), local_files_only=False))
                except Exception:
                    raise ServiceError("download_failed", "Model download failed. Check connectivity and, for gated models, accept terms and provide an authorized token.", 503, True) from None
                finally:
                    stopped.set(); monitor.join(timeout=1)
                if downloaded.stat().st_size != file["size"] or models.digest(downloaded, git_blob=file["sha256"] is None) != expected:
                    raise ServiceError("checksum_failed", "Downloaded model checksum did not match the pinned manifest.", 503)
                temporary = output.with_name(output.name + "." + uuid.uuid4().hex + ".partial")
                try:
                    # Copy into a real file: runtime model paths do not trust symlinks.
                    with downloaded.open("rb") as source, temporary.open("xb") as target:
                        os.chmod(temporary, 0o600)
                        shutil.copyfileobj(source, target, length=1024 * 1024)
                        target.flush()
                        os.fsync(target.fileno())
                    os.replace(temporary, output)
                finally:
                    temporary.unlink(missing_ok=True)
            completed_bytes += file["size"]
            progress(stage="verify", model=name, completed_bytes=completed_bytes, total_bytes=total_bytes, status=f"Verifying {completed_bytes:,} / {total_bytes:,} bytes")
            receipt.append({"path": file["path"], "sha256": models.digest(output)})
        atomic_json(destination / ".verified.json", {"revision": item["revision"], "files": receipt})
        if not assets.ready(name):
            raise ServiceError("model_unavailable", "The repaired model did not pass snapshot verification.", 503, True)
        # Pin the exact cached revision used by VoiceStudio's offline resolver.
        repo_cache = root / "models" / "hub" / ("models--" + item["repo"].replace("/", "--"))
        no_symlinks(repo_cache)
        repo_cache.mkdir(parents=True, exist_ok=True, mode=0o700)
        marker = repo_cache / "voicestudio-revision"
        no_symlinks(marker)
        marker.write_text(item["revision"] + "\n")
        progress(stage="model", model=name, status="ready")
    if "community1" in names:
        from .community_setup import install_runtime
        install_runtime(root, progress)
    progress(stage="complete", status="ready", models=names)
