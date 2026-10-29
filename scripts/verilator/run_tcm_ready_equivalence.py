#!/usr/bin/env python3
"""Compare the TCM ready-path candidate against frozen protocol implementations."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--xlen", type=int, choices=(32, 64), required=True)
    args = parser.parse_args()
    repo = Path(__file__).resolve().parents[2]
    os.chdir(repo)
    run = f"rv{args.xlen}"
    build = Path("build/closing-c6-20261030/tcm-ready") / run
    logs = Path("logs/closing-c6-20261030/tcm-ready") / run
    logs.mkdir(parents=True, exist_ok=True)
    if (logs / "result.json").exists():
        raise SystemExit(f"completed evidence already exists: {logs}")
    env = dict(os.environ, CCACHE_TEMPDIR=str(repo / "build/ccache-tmp"),
               CCACHE_DIR=str(repo / "build/ccache"))
    Path(env["CCACHE_TEMPDIR"]).mkdir(parents=True, exist_ok=True)
    Path(env["CCACHE_DIR"]).mkdir(parents=True, exist_ok=True)
    cases = []
    for local_bytes in sorted({4, args.xlen // 8}):
        for read_only in (0, 1):
            cases.append((f"cursor-ro{read_only}-local{local_bytes}", "tb_axi_bus_target",
                          [f"-GREAD_ONLY={read_only}", f"-GLOCAL_BYTES={local_bytes}", "-GREGISTER_LOCAL_ADDR=1"],
                          ["tb/soc/axi_bus_target_reference.sv"], [[]]))
    cases.append(("system", "tb_tcm_system_target", ["-GCOMPARE_REFERENCE=1"],
                  ["vsrc/soc/memory/tcm_address_decode.sv", "vsrc/soc/memory/tcm_system_target.sv",
                   "tb/soc/tcm_system_target_reference.sv"], [[]]))
    for region in (0, 1, 2):
        cases.append((f"narrow-{region}", "tb_axi_narrow_burst", [f"-GTCM_REGION={region}"],
                      ["vsrc/soc/memory/tcm_address_decode.sv", "vsrc/soc/memory/tcm_system_target.sv"], [[]]))
    for instruction in (0, 1):
        image = build / f"bram-if{instruction}/init.hex"
        image.parent.mkdir(parents=True, exist_ok=True)
        word_bytes = args.xlen // 8
        image.write_text("".join(
            f"{int.from_bytes(bytes(((i+j)^0x97)&255 for j in range(word_bytes)), 'little'):0{args.xlen//4}x}\n"
            for i in range(0, 1024, word_bytes)))
        cases.append((f"bram-if{instruction}", "tb_tcm_bram",
                      [f"-GINSTRUCTION={instruction}", "-GCOMPARE_REFERENCE=1"],
                      ["tb/soc/tcm_bram_reference.sv"],
                      [[f"+IMAGE={image}", f"+SEED={seed}"] for seed in (430097725, 19349663, 83492791)]))
    receipt = dict(xlen=args.xlen, status="RUNNING", commands=[], tests=[],
                   source_commit=subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip(),
                   source_status=subprocess.check_output(["git", "status", "--porcelain"], text=True))
    source_paths = [*Path("vsrc").rglob("*.sv"), *Path("tb/soc").glob("*.sv"), Path(__file__).relative_to(repo)]
    receipt["source_sha256"] = {str(p): hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(source_paths)}
    started = time.monotonic()
    try:
        for name, top, options, extra, runs in cases:
            out = build / name
            out.mkdir(parents=True, exist_ok=True)
            file_list = "scripts/soc_files.f" if top == "tb_tcm_bram" else "scripts/axi_files.f"
            command = ["verilator", "--binary", "--assert", "--timing", "-Wall", "-Wno-fatal", "-j", "1",
                       "-CFLAGS", "-O1", f"-DCORE_XLEN={args.xlen}", "-f", "scripts/rtl_files.f",
                       "-f", file_list, *extra, f"tb/soc/{top}.sv", "--top-module", top, *options, "-Mdir", str(out)]
            receipt["commands"].append(command)
            build_log = logs / f"{name}.build.log"
            with build_log.open("w") as log:
                subprocess.run(command, env=env, stdout=log, stderr=subprocess.STDOUT, check=True)
            if re.search(r"%(Error|Warning-(LATCH|UNOPTFLAT|MULTIDRIVEN|ALWCOMBORDER))", build_log.read_text()):
                raise RuntimeError(f"structural warning: {build_log}")
            for index, plusargs in enumerate(runs):
                command = [str(out / f"V{top}"), *plusargs]
                receipt["commands"].append(command)
                run_log = logs / f"{name}-{index}.run.log"
                with run_log.open("w") as log:
                    subprocess.run(command, env=env, stdout=log, stderr=subprocess.STDOUT, check=True)
                output = run_log.read_text()
                passes = [line for line in output.splitlines() if line.startswith("PASS ")]
                if not passes or re.search(r"%(Fatal|Error)|Assertion failed", output):
                    raise RuntimeError(f"simulation failed: {run_log}")
                receipt["tests"].append(dict(name=name, run=index, log=str(run_log), passes=passes))
                print("\n".join(passes), flush=True)
        receipt.update(status="PASS", pass_count=len(receipt["tests"]), skip_count=0)
    except Exception as error:
        receipt.update(status="FAIL", error=repr(error))
        raise
    finally:
        receipt["elapsed_seconds"] = time.monotonic() - started
        receipt["source_stable"] = all(hashlib.sha256(Path(p).read_bytes()).hexdigest() == digest
                                       for p, digest in receipt["source_sha256"].items())
        (logs / "result.json").write_text(json.dumps(receipt, indent=2) + "\n")


if __name__ == "__main__":
    main()
