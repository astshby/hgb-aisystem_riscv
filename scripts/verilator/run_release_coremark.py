#!/usr/bin/env python3
"""Compare release Core RTL with an existing frozen M0 image without rebuilding software."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import time
import coremark_snapshot as snapshot


def sha(p):
    return hashlib.sha256(p.read_bytes()).hexdigest()


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--baseline", type=Path, required=True, help="previous verified M0 result.json")
    p.add_argument("--out", type=Path, required=True)
    p.add_argument("--log", type=Path, required=True)
    p.add_argument("--store-hint", type=int, choices=(0, 1), default=1)
    p.add_argument("--wakeup", type=int, choices=(0, 1), default=1)
    a = p.parse_args()
    if not os.environ.get("RISCV_TOOL_ROOT"):
        p.error("set RISCV_TOOL_ROOT to the RISC-V toolchain bin directory")
    root = Path(__file__).resolve().parents[2]
    os.chdir(root)
    baseline = json.loads(a.baseline.read_text())
    cfg = baseline["config"]
    assert cfg["soc"] == 0
    width = cfg["xlen"]
    frozen = Path(baseline["snapshot"])
    manifest = snapshot.validate_snapshot(frozen, cfg)
    if a.out.exists() or a.log.exists():
        p.error("use fresh output/log directories")
    a.out.mkdir(parents=True)
    a.log.mkdir(parents=True)
    flags = [f"-DCORE_XLEN={width}", "-DCORE_RETIRE_ENTRIES=16", "-DCORE_ISSUE_WIDTH=2", "-DCORE_SCOREBOARD",
             "-DCORE_ISSUE_QUEUE_ENTRIES=8", "-DCORE_MEMORY_QUEUE_ENTRIES=4", "-DCORE_SPLIT_ISSUE_QUEUE=1",
             "-DCORE_LIMITED_INTEGER_OOO=0", "-DCORE_SCHEDULER_FORWARD_MODE=3", "-DCORE_PREDICTOR_MODE=1",
             "-DCORE_RAS_ENABLE=0", "-DCORE_MUL_IMPL=0", "-DCORE_DIV_IMPL=1",
             f"-DCORE_STORE_HINT_ENABLE={a.store_hint}", f"-DCORE_COMPLETION_WAKEUP_ENABLE={a.wakeup}"]
    model = a.out / "model"
    cmd = ["verilator", "-Wall", "-Wno-fatal", "--assert", "--timing", "--binary", "-j", "1", "-CFLAGS", "-O1",
           *flags, "--Mdir", str(model), "-f", "scripts/sim_files.f", "tb/common/store_result_monitor.sv",
           "tb/common/scoreboard_metrics.sv", "tb/benchmark/bind_scoreboard_metrics.sv",
           "tb/common/scoreboard_scheduler_metrics.sv", "tb/benchmark/bind_scheduler_metrics.sv",
           "tb/benchmark/tb_benchmark.sv", "--top-module", "tb_benchmark"]
    source_paths = [*Path("vsrc/core").rglob("*.sv"), *Path("vsrc/pkg").glob("*.sv"),
                    *Path("vsrc/sim_cpu").glob("*.sv"), Path("tb/benchmark/tb_benchmark.sv"),
                    Path("scripts/verilator/run_release_coremark.py")]
    source_sha = {str(p): sha(p) for p in source_paths}
    receipt = dict(status="RUNNING", source_commit=subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip(),
                   source_sha256=source_sha, flags=flags, baseline=str(a.baseline), baseline_sha256=sha(a.baseline),
                   snapshot=str(frozen), snapshot_manifest_sha256=sha(frozen/"manifest.json"), build_command=cmd,
                   xlen=width, store_hint=a.store_hint, wakeup=a.wakeup, modes={})
    output = a.log / "receipt.json"
    output.write_text(json.dumps(receipt, indent=2) + "\n")
    env = dict(os.environ, CCACHE_DIR=str(root/"build/ccache"),
               CCACHE_TEMPDIR=str(root/"build/ccache-tmp"))
    started = time.monotonic()
    with (a.log/"build.log").open("w") as f:
        result = subprocess.run(["/usr/bin/time", "-v", *cmd], stdout=f, stderr=subprocess.STDOUT, env=env)
    receipt["build_seconds"] = time.monotonic() - started
    build_text = (a.log/"build.log").read_text()
    if result.returncode or re.search(r"%(?:Error|Warning-(?:LATCH|UNOPTFLAT|MULTIDRIVEN|ALWCOMBORDER))", build_text):
        receipt["status"] = "FAIL_BUILD"
        output.write_text(json.dumps(receipt, indent=2) + "\n")
        print(build_text[-6000:], flush=True)
        return 1
    binary = model/"Vtb_benchmark"
    receipt["model_sha256"] = sha(binary)
    for mode in ("performance", "validation"):
        record = manifest["modes"][mode]
        command = [str(binary), f"+IMEM={frozen/mode/'imem.hex'}", f"+DMEM={frozen/mode/'dmem.hex'}",
                   f"+TOHOST={record['symbols']['tohost']:x}", f"+CONSOLE={record['symbols']['sim_console']:x}",
                   f"+TEST=coremark-{mode}", f"+MAX_CYCLES={record['max_cycles']}"]
        log = a.log/f"{mode}.log"
        started = time.monotonic()
        with log.open("w") as f:
            result = subprocess.run(command, stdout=f, stderr=subprocess.STDOUT, env=env)
        if result.returncode:
            receipt["status"] = "FAIL_RUN"
            receipt["failed_mode"] = mode
            output.write_text(json.dumps(receipt, indent=2) + "\n")
            print(log.read_text()[-4000:], flush=True)
            return 1
        observed = snapshot.result_fields(log, mode, width, allow_short=True)
        assert observed["crc"] == record["crc"]
        before = baseline["modes"][mode]["ticks"]
        cycles = observed["ticks"]
        receipt["modes"][mode] = dict(roi_cycles=cycles, baseline_roi_cycles=before,
            delta_cycles=cycles-before, coremark_per_mhz=record["iterations"]*1e6/cycles,
            iterations=record["iterations"], crc=observed["crc"], command=command,
            seconds=time.monotonic()-started, log=str(log), log_sha256=sha(log),
            images={n:sha(frozen/mode/n) for n in ("program.elf","imem.hex","dmem.hex")})
        output.write_text(json.dumps(receipt, indent=2) + "\n")
        print(f"PASS M0 RV{width} hint{a.store_hint} {mode}: cycles={cycles} delta={cycles-before} CM/MHz={record['iterations']*1e6/cycles:.6f}", flush=True)
    snapshot.validate_snapshot(frozen,cfg)
    receipt["source_unchanged"] = source_sha == {str(p):sha(p) for p in source_paths}
    receipt["status"] = "PASS" if receipt["source_unchanged"] else "FAIL_SOURCE_CHANGED"
    receipt["performance_nonregression"] = all(v["delta_cycles"] <= 0 for v in receipt["modes"].values())
    receipt["board_measurement"] = False
    output.write_text(json.dumps(receipt, indent=2) + "\n")
    return 0 if receipt["status"] == "PASS" else 1


if __name__ == "__main__":
    raise SystemExit(main())
