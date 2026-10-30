#!/usr/bin/env python3
"""Verify the bundled RT-Thread subset or an explicitly selected upstream Git tree."""
import hashlib
import json
from pathlib import Path
import subprocess
import sys

REVISION = "ddf52e2cdd977f14fc04035c88672ac204aec713"


def verify(root):
    root = Path(root)
    manifest = root / "UPSTREAM.json"
    if manifest.is_file():
        data = json.loads(manifest.read_text())
        if data["revision"] != REVISION:
            raise ValueError("RT-Thread revision mismatch")
        for name, digest in data["files"].items():
            if hashlib.sha256((root / name).read_bytes()).hexdigest() != digest:
                raise ValueError("RT-Thread source differs from upstream: " + name)
        print(f"PASS bundled RT-Thread v5.2.2: {len(data['files'])} source/license files")
    else:
        actual = subprocess.check_output(["git", "-C", str(root), "rev-parse", "HEAD"], text=True).strip()
        if actual != REVISION:
            raise ValueError("RT-Thread revision mismatch")
        if subprocess.check_output(["git", "-C", str(root), "status", "--porcelain", "--untracked-files=no"], text=True):
            raise ValueError("RT-Thread source tree is modified")
        print("PASS external RT-Thread v5.2.2 " + actual)


if __name__ == "__main__":
    verify(sys.argv[1] if len(sys.argv) > 1 else "third_party/rt-thread")
