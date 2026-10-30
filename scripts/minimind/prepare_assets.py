#!/usr/bin/env python3
"""Verify bundled MiniMind integer assets, or rebuild from SHA-locked model weights."""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import shutil
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
from asset_fetch import fetch, sha256


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


def prepare(rebuild=False):
    base = ROOT / "software/minimind3"
    assets = base / "c_runtime/assets"
    fp = json.loads((assets / "manifest.json").read_text())
    integer = json.loads((assets / "integer_manifest.json").read_text())
    expected = dict(fp["files"])
    expected["model_w8a16_int.bin"] = dict(bytes=integer["bytes"], sha256=integer["sha256"])
    if rebuild:
        lock = json.loads((base / "model_lock.json").read_text())
        source_hashes = json.loads((base / "model_sha256.json").read_text())
        source = base / "model"
        url_base = f'https://huggingface.co/{lock["repo"]}/resolve/{lock["revision"]}/'
        for name, digest in source_hashes.items():
            local = os.environ.get("MINIMIND_CHECKPOINT") if name == "model.safetensors" else None
            url = Path(local).resolve().as_uri() if local else url_base + name
            fetch(url, source / name, digest)
        cache = base / ".cache"
        cache.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(prefix="export-", dir=cache) as directory:
            export_root = Path(directory)
            fp_export = load("hgb_mm3_fp_export", base / "c_runtime/tools/export.py")
            fp_export.ROOT = export_root
            fp_export.export(source)
            int_export = load("hgb_mm3_int_export", base / "c_runtime/tools/export_integer.py")
            int_export.ROOT = export_root
            previous = sys.argv
            try:
                sys.argv = ["export_integer.py", "--capacity", str(integer["capacity"])]
                int_export.main()
            finally:
                sys.argv = previous
            for name, entry in expected.items():
                generated = export_root / "assets" / name
                if generated.stat().st_size != entry["bytes"] or sha256(generated) != entry["sha256"]:
                    raise ValueError(f"export differs from the author's original asset: {name}")
                target = assets / name
                if target.exists() and sha256(target) != entry["sha256"]:
                    raise ValueError(f"inspect locally modified asset before replacing it: {name}")
                if not target.exists():
                    shutil.copyfile(generated, target)
    for name in ("model_w8a16_int.bin", "tokenizer.bin"):
        path = assets / name
        if path.stat().st_size != expected[name]["bytes"] or sha256(path) != expected[name]["sha256"]:
            raise ValueError(f"MiniMind bundle differs from original manifest: {name}")
    print("PASS MiniMind: original integer model and tokenizer match SHA256")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--rebuild", action="store_true")
    prepare(parser.parse_args().rebuild)
