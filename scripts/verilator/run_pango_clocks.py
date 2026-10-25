#!/usr/bin/env python3
"""Run reset and vendor-model PLL simulation only; never invoke PDS."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess

REPO = Path(__file__).resolve().parents[2]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True, help="new log directory below logs/")
    parser.add_argument("--build", type=Path, required=True, help="new build directory below build/")
    args = parser.parse_args()
    output, build = args.output.resolve(), args.build.resolve()
    for path, parent in ((output, REPO / "logs"), (build, REPO / "build")):
        if parent not in path.parents or (path.exists() and any(path.iterdir())):
            parser.error(f"use an empty directory below {parent.name}/")
    pds = os.environ.get("PDS_HOME")
    if not pds:
        parser.error("PDS_HOME must identify the local vendor library (no PDS process is started)")
    vendor = Path(pds) / "arch/vendor/pango/verilog/simulation"
    libraries = [vendor / "GTP_GPLL.v", vendor / "GTP_CLKBUFG.v"]
    if not all(path.is_file() for path in libraries):
        parser.error("missing GPLL/clock-buffer simulation models under PDS_HOME")
    output.mkdir(parents=True, exist_ok=True)
    build.mkdir(parents=True, exist_ok=True)
    env = os.environ.copy()
    env.update(CCACHE_TEMPDIR=str(REPO / "build/ccache-tmp"), CCACHE_DIR=str(REPO / "build/ccache"))
    sources = ["vsrc/cpu/pango_soc_reset.sv", "vsrc/soc/common/soc_reset_controller.sv",
               "vsrc/soc/common/async_fifo.sv", "tb/fpga/tb_pango_soc_reset.sv"]
    jobs = [("reset", "tb_pango_soc_reset", sources, [])]
    for profile in (1, 4):
        jobs.append((f"pll-c{profile}", "tb_pango_soc_pll",
                     [str(path) for path in libraries] + ["vsrc/cpu/pango_soc_pll.sv", "tb/fpga/tb_pango_soc_pll.sv"],
                     [f"-GCLOCK_PROFILE={profile}"]))
    hashes = {str(path): hashlib.sha256(path.read_bytes()).hexdigest()
              for path in set((REPO / name).resolve() for _, _, paths, _ in jobs for name in paths)}
    receipt = {"evidence": "RTL and unmodified vendor simulation models; no placement, STA, DDR PHY or board test",
               "source_sha256": hashes, "jobs": [], "passed": False}
    for name, top, paths, flags in jobs:
        command = ["verilator", "--binary", "--timing", "--assert", "-Wno-fatal", "-j", "2",
                   "--top-module", top, "--Mdir", str(build / name)] + flags + paths
        record = {"name": name, "compile": command, "run": [str(build / name / ("V" + top))]}
        receipt["jobs"].append(record)
        for stage in ("compile", "run"):
            log = output / f"{name}-{stage}.log"
            with log.open("w") as stream:
                result = subprocess.run(record[stage], cwd=REPO, env=env, stdout=stream, stderr=subprocess.STDOUT)
            record[stage + "_exit"] = result.returncode
            record[stage + "_log_sha256"] = hashlib.sha256(log.read_bytes()).hexdigest()
            (output / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
            if result.returncode:
                raise RuntimeError(f"{name} {stage} failed; see {log}")
            text = log.read_text()
            if stage == "run" and (not re.search(r"^PASS ", text, re.M) or re.search(r"error|illegal|fatal", text, re.I)):
                raise RuntimeError(f"{name} missing PASS or vendor error; see {log}")
        print(f"PASS {name}", flush=True)
    if hashes != {name: hashlib.sha256(Path(name).read_bytes()).hexdigest() for name in hashes}:
        raise RuntimeError("clock sources changed during simulation")
    receipt["passed"] = True
    (output / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")


if __name__ == "__main__":
    main()
