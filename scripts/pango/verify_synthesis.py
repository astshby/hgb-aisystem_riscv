#!/usr/bin/env python3
"""Verify staged bytes and measured DSP/BRAM mappings; no timing claim."""
import argparse
import hashlib
import json
from pathlib import Path
import re

if __package__:
    from .prepare_project import verify_staged_manifest
else:
    from prepare_project import verify_staged_manifest


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("project", type=Path)
    parser.add_argument("--staging-only", action="store_true",
                        help="check input hashes/configuration only; do not read or certify synthesis")
    args = parser.parse_args()
    root = args.project.resolve()
    manifest = json.loads((root / "manifest.json").read_text(encoding="utf-8"))
    configuration = verify_staged_manifest(root, manifest)
    if args.staging_only:
        print(f"PASS staging only: {len(manifest['files'])} exact byte hashes; no synthesis evidence")
        print(json.dumps(configuration, sort_keys=True))
        return
    if (manifest["mul"], manifest["div"]) != (0, 1):
        raise ValueError("expected DSP/SRT candidate")
    backend = configuration.get("core_backend", "legacy")
    # 仅接受有实际综合网表依据的组合；RV64 旧核映射尚未在该交接入口验证。
    mappings = {(32, "legacy"): (34, 4), (32, "scoreboard"): (36, 4),
                (64, "scoreboard"): (38, 12)}
    key = (manifest["xlen"], backend)
    if key not in mappings:
        raise ValueError(f"unverified synthesis mapping: {key}")
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
    expected_drm, expected_apm = mappings[key]
    if (resources["latch"] != 0 or resources["drm36k"] != expected_drm or
            resources["apm"] != expected_apm):
        raise ValueError(f"unexpected latch/BRAM/DSP mapping: {resources}")
    result = {"status": "synthesis only; timing and board operation not certified",
              "configuration": configuration,
              "resources": resources, "staged_files_verified": len(manifest["files"]),
              "report_sha256": hashlib.sha256(report.read_bytes()).hexdigest()}
    (root / "synthesis-summary.json").write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    print(f"PASS staging manifest: {len(manifest['files'])} exact byte hashes")
    print(f"PASS RV{manifest['xlen']} synthesis mapping: {json.dumps(resources)}")
    print(f"Configuration: {json.dumps(configuration, sort_keys=True)}")


if __name__ == "__main__":
    main()
