#!/usr/bin/env python3
"""Verify staged bytes and the RV32 DSP/BRAM synthesis gate; no timing claim."""
import argparse
import hashlib
import json
from pathlib import Path
import re


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("project", type=Path)
    args = parser.parse_args()
    root = args.project.resolve()
    manifest = json.loads((root / "manifest.json").read_text(encoding="utf-8"))
    if (manifest["xlen"], manifest["mul"], manifest["div"]) != (32, 0, 1):
        raise ValueError("expected RV32 DSP/SRT candidate")
    for name, expected in manifest["files"].items():
        path = (root / name).resolve()
        path.relative_to(root)
        if hashlib.sha256(path.read_bytes()).hexdigest() != expected:
            raise ValueError(f"staged byte hash mismatch: {name}")
    report = root / "prj_tasks/syn_1/synthesize/pango_200hp_top.snr"
    text = report.read_text(encoding="utf-8")
    patterns = {"lut": r"Total LUTs:\s*(\d+)", "ff": r"Total Registers:\s*(\d+)",
                "latch": r"Total Latches:\s*(\d+)", "drm36k": r"Total DRMs\s*=\s*([\d.]+)",
                "apm": r"Total APMs\s*=\s*([\d.]+)", "io": r"Total I/O ports\s*=\s*(\d+)"}
    resources = {}
    for name, pattern in patterns.items():
        match = re.search(pattern, text)
        if not match:
            raise ValueError(f"missing synthesis resource: {name}")
        resources[name] = int(float(match[1]))
    if resources["latch"] != 0 or resources["drm36k"] != 34 or resources["apm"] != 4:
        raise ValueError(f"unexpected latch/BRAM/DSP mapping: {resources}")
    result = {"status": "synthesis only; timing and board operation not certified",
              "resources": resources, "staged_files_verified": len(manifest["files"]),
              "report_sha256": hashlib.sha256(report.read_bytes()).hexdigest()}
    (root / "synthesis-summary.json").write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    print(f"PASS staging manifest: {len(manifest['files'])} exact byte hashes")
    print(f"PASS RV32 synthesis mapping: {json.dumps(resources)}")


if __name__ == "__main__":
    main()
