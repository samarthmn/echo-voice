import hashlib
import json
import pytest
from echo_service import models
from echo_service.installer import install_models
from echo_service.errors import ServiceError

@pytest.fixture
def tiny_manifest(monkeypatch):
    content = b'actual-weight-data'
    manifest = {"models": {"asr": {"repo": "example/weights", "revision": "a" * 40, "gated": False,
                    "files": [{"path": "weights.safetensors", "size": len(content), "sha256": hashlib.sha256(content).hexdigest(), "git_blob_sha1": None}]}}}
    monkeypatch.setattr(models, "MANIFEST", manifest)
    return content

def test_readiness_requires_actual_verified_weights(data_root, tiny_manifest):
    assets = models.ModelAssets(data_root)
    destination = assets.path("asr")
    destination.mkdir(parents=True)
    (destination / ".verified.json").write_text(json.dumps({"revision": "a" * 40}))
    assert not assets.ready("asr")
    (destination / "weights.safetensors").write_bytes(tiny_manifest)
    assert assets.ready("asr")
    (destination / "weights.safetensors").write_bytes(b'x' * len(tiny_manifest))
    assert not assets.ready("asr")

def test_installer_rejects_bad_checksum_without_readiness(data_root, tiny_manifest):
    source = data_root / "download"
    source.write_bytes(b'x' * len(tiny_manifest))
    def download(**kwargs):
        assert kwargs["revision"] == "a" * 40
        return str(source)
    with pytest.raises(ServiceError, match="checksum"):
        install_models(data_root, "asr", None, downloader=download)
    assert not models.ModelAssets(data_root).ready("asr")

def test_installer_records_receipt_after_verification(data_root, tiny_manifest):
    source = data_root / "download"
    source.write_bytes(tiny_manifest)
    install_models(data_root, "asr", None, downloader=lambda **kwargs: str(source))
    assert models.ModelAssets(data_root).ready("asr")


def test_model_notices_are_required_and_checksum_verified(data_root, tiny_manifest):
    notice = b'Pinned model license and attribution notice.'
    models.MANIFEST["models"]["asr"]["files"].append({"path": "README.md", "size": len(notice), "sha256": hashlib.sha256(notice).hexdigest(), "git_blob_sha1": None})
    sources = {}
    for name, content in (("weights.safetensors", tiny_manifest), ("README.md", notice)):
        path = data_root / name
        path.write_bytes(content)
        sources[name] = str(path)
    install_models(data_root, "asr", None, downloader=lambda **kwargs: sources[kwargs["filename"]])
    assets = models.ModelAssets(data_root)
    assert assets.ready("asr")
    local_notice = assets.path("asr") / "README.md"
    assert local_notice.read_bytes() == notice
    local_notice.write_bytes(b'x' * len(notice))
    assert not assets.ready("asr")
    local_notice.unlink()
    assert not assets.ready("asr")


@pytest.mark.parametrize("extra", ["extra.safetensors", "nested/extra.bin", "linked-file", "linked-directory"])
def test_snapshot_rejects_unlisted_files_and_links_and_repair_quarantines_them(data_root, tiny_manifest, extra):
    source = data_root / "download"
    source.write_bytes(tiny_manifest)
    download = lambda **kwargs: str(source)
    install_models(data_root, "asr", None, downloader=download)
    assets = models.ModelAssets(data_root)
    snapshot = assets.path("asr")
    assert assets.ready("asr")
    outside = data_root / "outside"
    outside.mkdir()
    (outside / "kept.txt").write_text("do not modify")
    extra_path = snapshot / extra
    extra_path.parent.mkdir(parents=True, exist_ok=True)
    if extra == "linked-file":
        extra_path.symlink_to(source)
    elif extra == "linked-directory":
        extra_path.symlink_to(outside, target_is_directory=True)
    else:
        extra_path.write_bytes(b"untrusted extra model data")
    assert not assets.ready("asr")
    def no_download(**kwargs):
        pytest.fail("Repair should reuse the already verified regular weight file")
    install_models(data_root, "asr", None, downloader=no_download)
    assert models.ModelAssets(data_root).ready("asr")
    assert not extra_path.exists() and not extra_path.is_symlink()
    quarantines = list(snapshot.parent.glob(".quarantine-*"))
    assert len(quarantines) == 1
    preserved = quarantines[0] / extra
    assert preserved.exists() or preserved.is_symlink()
    assert (outside / "kept.txt").read_text() == "do not modify"


@pytest.mark.parametrize("link_target", ["weight", "receipt", "snapshot"])
def test_repair_never_follows_links_in_expected_snapshot_paths(data_root, tiny_manifest, link_target):
    source = data_root / "download"
    source.write_bytes(tiny_manifest)
    install_models(data_root, "asr", None, downloader=lambda **kwargs: str(source))
    assets = models.ModelAssets(data_root)
    snapshot = assets.path("asr")
    if link_target == "snapshot":
        external = data_root / "external-snapshot"
        snapshot.rename(external)
        snapshot.symlink_to(external, target_is_directory=True)
        preserved = (external / "weights.safetensors").read_bytes()
    else:
        entry = snapshot / ("weights.safetensors" if link_target == "weight" else ".verified.json")
        external = data_root / "external-file"
        external.write_bytes(entry.read_bytes())
        preserved = external.read_bytes()
        entry.unlink()
        entry.symlink_to(external)
    assert not assets.ready("asr")
    install_models(data_root, "asr", None, downloader=lambda **kwargs: str(source))
    assert models.ModelAssets(data_root).ready("asr")
    assert not snapshot.is_symlink()
    assert ((external / "weights.safetensors").read_bytes() if external.is_dir() else external.read_bytes()) == preserved
