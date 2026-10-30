#!/usr/bin/env python3
"""Verify bundled YOLO assets; --rebuild downloads the pinned official checkpoint."""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import shutil
import sys

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
from asset_fetch import fetch, sha256


def prepare(rebuild=False):
    base = ROOT / "software/yolo"
    manifest = json.loads((base / "assets/manifest.json").read_text())
    if rebuild:
        lock = json.loads((base / "model.lock.json").read_text())
        staging = base / ".cache/export-root"
        (staging / "config").mkdir(parents=True, exist_ok=True)
        (staging / "build").mkdir(exist_ok=True)
        shutil.copy2(base / "model.lock.json", staging / "config/yolox-tiny.lock.json")
        shutil.copy2(base / "model-audit.json", staging / "build/yolox-tiny-audit.json")
        upstream = staging / "build/upstream/YOLOX"
        for name, expected in lock["source_sha256"].items():
            source = base / "vendor/YOLOX" / name
            if sha256(source) != expected:
                raise ValueError(f"upstream source SHA256 mismatch: {name}")
            target = upstream / name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source, target)
        local = os.environ.get("YOLO_CHECKPOINT")
        url = Path(local).resolve().as_uri() if local else lock["weights_url"]
        fetch(url, staging / "build/models/yolox_tiny.pth", lock["weights_sha256"])
        spec = importlib.util.spec_from_file_location("hgb_yolo_export", ROOT / "scripts/yolo/export_network.py")
        exporter = importlib.util.module_from_spec(spec)
        sys.modules[spec.name] = exporter
        spec.loader.exec_module(exporter)
        for size in (320, 416):
            output = staging / f"build/exported/yolox-tiny-{size}.bin"
            exporter.export(staging.relative_to(ROOT), output.relative_to(ROOT), size)
            if sha256(output) != manifest["files"][output.name]["sha256"]:
                raise ValueError(f"export differs from the published {size} bundle")
    for name, entry in manifest["files"].items():
        path = base / "assets" / name
        if path.stat().st_size != entry["bytes"] or sha256(path) != entry["sha256"]:
            raise ValueError(f"bundled asset differs from manifest: {name}")
    tests = ROOT / "tb/assets/yolo"
    fixtures = json.loads((tests / "manifest.json").read_text())
    for name, entry in fixtures["files"].items():
        if sha256(tests / name) != entry["sha256"]:
            raise ValueError(f"test fixture differs from manifest: {name}")
    print("PASS YOLO: both 83-convolution bundles and tracked test images match SHA256")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--rebuild", action="store_true", help="re-export both models from official weights")
    prepare(parser.parse_args().rebuild)
