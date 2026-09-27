#!/usr/bin/env python3
"""Preserve licenses from the exact Swift package checkout graph in the app."""
import json
from pathlib import Path
import shutil
import sys

checkouts, destination = map(Path, sys.argv[1:])
destination.mkdir(parents=True, exist_ok=True)
root = Path(__file__).resolve().parent.parent
pins = json.loads((root / "Package.resolved").read_text())["pins"]
for pin in pins:
    identity = pin["identity"]
    checkout = next((item for item in checkouts.iterdir() if item.name.lower() == identity.lower()), None)
    if checkout is None:
        raise SystemExit(f"Missing locked dependency checkout: {identity}")
    output = destination / identity
    output.mkdir(exist_ok=True)
    (output / "SOURCE.txt").write_text(f"{pin['location']}\nRevision: {pin['state']['revision']}\nVersion: {pin['state'].get('version', 'revision pin')}\n")
    found = []
    for path in checkout.rglob("*"):
        if path.is_file() and not any(part in (".git", ".build") for part in path.parts):
            name = path.name.lower()
            if name.startswith(("license", "licence", "copying", "notice")) and path.stat().st_size < 1_000_000:
                relative = path.relative_to(checkout)
                target = output / relative
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(path, target)
                found.append(str(relative))
    if not found:
        raise SystemExit(f"No license notice found for {identity}")
shutil.copyfile(root / "docs" / "THIRD_PARTY.md", destination / "README.md")
print(f"Preserved notices for {len(pins)} locked Swift packages")
