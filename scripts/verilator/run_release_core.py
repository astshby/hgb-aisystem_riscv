#!/usr/bin/env python3
"""Run focused release Core tests with frozen FIFO reference and sealed source hashes."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import time

REFERENCE = "18598a6bda6d383d7fd1f113901ec6c2c5d0f232"
CASES = {
    "cmp": ["tb_completion_payload_miter", "tb_scoreboard_completion_queue"],
    "wakeup": ["tb_completion_operand_preview", "tb_scoreboard_retirement", "tb_scoreboard_recovery",
               "tb_scoreboard_completion", "tb_scoreboard_completion_cancel"],
    "core": ["tb_scoreboard_core", "tb_scoreboard_events", "tb_scoreboard_forward_modes"],
}


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--xlen", type=int, choices=(32, 64), required=True)
    p.add_argument("--group", choices=(*CASES, "all"), default="all")
    p.add_argument("--out", type=Path, required=True)
    p.add_argument("--log", type=Path, required=True)
    p.add_argument("--store-hint", type=int, choices=(0, 1), default=1)
    p.add_argument("--wakeup", type=int, choices=(0, 1), default=1)
    a = p.parse_args()
    root = Path(__file__).resolve().parents[2]
    os.chdir(root)
    if a.out.exists() or a.log.exists():
        p.error("use fresh output/log directories")
    a.out.mkdir(parents=True)
    a.log.mkdir(parents=True)
    ref = a.out / "completion_queue_reference.sv"
    raw = subprocess.check_output(["git", "show", f"{REFERENCE}:vsrc/core/writeback/completion_queue.sv"])
    ref.write_text(raw.decode().replace("module completion_queue (", "module completion_queue_reference (", 1))
    flags = [f"-DCORE_XLEN={a.xlen}", "-DCORE_RETIRE_ENTRIES=16", "-DCORE_ISSUE_WIDTH=2",
             "-DCORE_ISSUE_QUEUE_ENTRIES=8", "-DCORE_MEMORY_QUEUE_ENTRIES=4", "-DCORE_SPLIT_ISSUE_QUEUE=1",
             "-DCORE_LIMITED_INTEGER_OOO=0", "-DCORE_SCHEDULER_FORWARD_MODE=3", "-DCORE_PREDICTOR_MODE=1",
             "-DCORE_RAS_ENABLE=0", "-DCORE_MUL_IMPL=0", "-DCORE_DIV_IMPL=1",
             f"-DCORE_STORE_HINT_ENABLE={a.store_hint}", f"-DCORE_COMPLETION_WAKEUP_ENABLE={a.wakeup}"]
    groups = CASES if a.group == "all" else {a.group: CASES[a.group]}
    names = [n for cases in groups.values() for n in cases]
    sources = list(Path("vsrc/core").rglob("*.sv")) + list(Path("vsrc/pkg").glob("*.sv"))
    sources += [Path(__file__).relative_to(root), *[Path("tb/unit/scoreboard") / f"{n}.sv" for n in names]]
    before = {str(s): sha(s) for s in sources}
    receipt = dict(status="RUNNING", source_commit=subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip(),
                   xlen=a.xlen, flags=flags, reference_commit=REFERENCE,
                   reference_sha256=hashlib.sha256(raw).hexdigest(), source_sha256=before, cases=[])
    output = a.log / "receipt.json"
    output.write_text(json.dumps(receipt, indent=2) + "\n")
    env = dict(os.environ, CCACHE_DIR=str(root / "build/ccache"), CCACHE_TEMPDIR=str(root / "build/ccache-tmp"))
    for name in names:
        tb = Path("tb/unit/scoreboard") / f"{name}.sv"
        cmd = ["verilator", "-Wall", "-Wno-fatal", "--assert", "--timing", "--binary", "-j", "1", "-CFLAGS", "-O1",
               *flags, "--Mdir", str(a.out / name), "-f", "scripts/rtl_files.f", "tb/common/rv_asm_pkg.sv"]
        if name == "tb_completion_payload_miter":
            cmd.append(str(ref))
        cmd += [str(tb), "--top-module", name]
        build = a.log / f"{name}.build.log"
        run = a.log / f"{name}.run.log"
        entry = dict(top=name, command=cmd, build_log=str(build), run_log=str(run))
        started = time.monotonic()
        with build.open("w") as f:
            result = subprocess.run(["/usr/bin/time", "-v", *cmd], stdout=f, stderr=subprocess.STDOUT, env=env)
        entry["build_seconds"] = time.monotonic() - started
        text = build.read_text()
        if result.returncode or re.search(r"%(?:Error|Warning-(?:LATCH|UNOPTFLAT|MULTIDRIVEN|ALWCOMBORDER))", text):
            entry["status"] = "FAIL_BUILD"
            print(text[-5000:], flush=True)
        else:
            with run.open("w") as f:
                result = subprocess.run([str(a.out / name / f"V{name}")], stdout=f, stderr=subprocess.STDOUT, env=env)
            lines = run.read_text().splitlines()
            entry["pass_lines"] = [line for line in lines if line.startswith(f"PASS {name} ")]
            entry["status"] = "PASS" if result.returncode == 0 and entry["pass_lines"] else "FAIL_RUN"
            print("\n".join(entry["pass_lines"]) if entry["status"] == "PASS" else "\n".join(lines[-30:]), flush=True)
        receipt["cases"].append(entry)
        output.write_text(json.dumps(receipt, indent=2) + "\n")
        if entry["status"] != "PASS":
            receipt["status"] = "FAIL"
            output.write_text(json.dumps(receipt, indent=2) + "\n")
            return 1
    after = {str(s): sha(s) for s in sources}
    receipt["source_unchanged"] = before == after
    receipt["status"] = "PASS" if before == after else "FAIL_SOURCE_CHANGED"
    receipt["pass_count"] = len(receipt["cases"])
    output.write_text(json.dumps(receipt, indent=2) + "\n")
    return 0 if receipt["status"] == "PASS" else 1


if __name__ == "__main__":
    raise SystemExit(main())
