#!/usr/bin/env python3
"""Run the two zero-stage Core candidates against immutable pre-change RTL."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import time


REFERENCE_COMMIT = "8e2e75e08a275116a7648cdda0ddb0e4d4080eba"
REFERENCE_SHA = {
    "vsrc/core/decode/d1_stage.sv": "1fb1e4c6213460abeb8e631d827b6464ab9c9f04d05f1d82b9d2c31639877c59",
    "vsrc/core/execute/branch_unit.sv": "3920c5bbba9f97b4ea03ebf9f6d9d53a013958f97a54e55c657823b531656f31",
    "vsrc/core/control/issue_queue.sv": "d8cf350a95fa13a11667b5c0ad0f06c30ba341f8ad661d557827f693d16a1c5c",
}


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--group", choices=("branch", "issue", "all"), default="all")
    parser.add_argument("--xlen", choices=(32, 64), type=int, required=True)
    parser.add_argument("--reference", type=Path, default=Path("build/closing-c6-20261030/branch-issue-reference"))
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--log", type=Path, required=True)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[2]
    os.chdir(root)
    out = args.out.resolve()
    logs = args.log.resolve()
    if out.exists() or logs.exists():
        parser.error("use fresh output and log directories")
    out.mkdir(parents=True)
    logs.mkdir(parents=True)
    refs = out / "reference"
    refs.mkdir()
    source_receipt = {}
    for name, expected_sha in REFERENCE_SHA.items():
        original = args.reference / Path(name).name
        if original.is_file():
            data = original.read_bytes()
            origin = str(original)
        else:
            data = subprocess.check_output(["git", "show", f"{REFERENCE_COMMIT}:{name}"])
            origin = f"git:{REFERENCE_COMMIT}:{name}"
        if hashlib.sha256(data).hexdigest() != expected_sha:
            raise RuntimeError(f"reference SHA mismatch: {name}")
        module = Path(name).stem
        renamed, count = re.subn(rf"\bmodule {module}\b", f"module {module}_reference", data.decode(), count=1)
        if count != 1:
            raise RuntimeError(f"reference module not found: {name}")
        (refs / f"{module}_reference.sv").write_text(renamed)
        source_receipt[name] = {"sha256": expected_sha, "origin": origin}
    flags = [f"-DCORE_XLEN={args.xlen}", "-DCORE_RETIRE_ENTRIES=16", "-DCORE_ISSUE_WIDTH=2",
             "-DCORE_ISSUE_QUEUE_ENTRIES=8", "-DCORE_MEMORY_QUEUE_ENTRIES=4",
             "-DCORE_SPLIT_ISSUE_QUEUE=1", "-DCORE_LIMITED_INTEGER_OOO=0",
             "-DCORE_SCHEDULER_FORWARD_MODE=3", "-DCORE_PREDICTOR_MODE=1", "-DCORE_RAS_ENABLE=0"]
    cases = []
    if args.group in ("branch", "all"):
        cases.extend([
            ("tb_d1_stage", root / "tb/unit/tb_d1_stage.sv", []),
            ("tb_branch_unit", root / "tb/unit/tb_branch_unit.sv", []),
            ("tb_pc_target_miter", root / "tb/unit/scoreboard/tb_pc_target_miter.sv",
             [refs / "d1_stage_reference.sv", refs / "branch_unit_reference.sv"]),
        ])
    if args.group in ("issue", "all"):
        old_test = root / "tb/unit/scoreboard/tb_scoreboard_issue.sv"
        static_test = out / "tb_scoreboard_issue_static.sv"
        static_test.write_text(old_test.read_text().replace("module tb_scoreboard_issue;", "module tb_scoreboard_issue_static;")
                               .replace("issue_queue dut", "issue_queue #(.STATIC_SELECT(1'b1)) dut")
                               .replace("PASS tb_scoreboard_issue RV", "PASS tb_scoreboard_issue_static RV"))
        cases.extend([
            ("tb_scoreboard_issue", old_test, []),
            ("tb_scoreboard_issue_static", static_test, []),
            ("tb_issue_static_miter", root / "tb/unit/scoreboard/tb_issue_static_miter.sv",
             [refs / "issue_queue_reference.sv"]),
        ])
    env = os.environ.copy()
    env["CCACHE_DIR"] = str(root / "build/ccache")
    env["CCACHE_TEMPDIR"] = str(root / "build/ccache-tmp")
    Path(env["CCACHE_DIR"]).mkdir(exist_ok=True, parents=True)
    Path(env["CCACHE_TEMPDIR"]).mkdir(exist_ok=True, parents=True)
    receipt = {"reference_commit": REFERENCE_COMMIT, "reference": source_receipt,
               "group": args.group, "xlen": args.xlen, "flags": flags, "cases": [],
               "source_commit": subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip(),
               "source_sha256": {}, "status": "RUNNING"}
    for name in (*REFERENCE_SHA, "vsrc/core/scoreboard_core.sv", "scripts/verilator/run_closing_core_units.py"):
        receipt["source_sha256"][name] = digest(root / name)
    for _, tb, _ in cases:
        receipt["source_sha256"][str(tb.relative_to(root)) if tb.is_relative_to(root) else str(tb)] = digest(tb)
    receipt_path = logs / "receipt.json"
    receipt_path.write_text(json.dumps(receipt, indent=2) + "\n")
    for top, tb, extra in cases:
        model = out / top
        build_log = logs / f"{top}.build.log"
        run_log = logs / f"{top}.run.log"
        command = ["verilator", "-Wall", "-Wno-fatal", "--assert", "--timing", "--binary", "-j", "1",
                   "-CFLAGS", "-O1", *flags, "--Mdir", str(model), "-f", "scripts/rtl_files.f",
                   "tb/common/rv_asm_pkg.sv", *(str(p) for p in extra), str(tb), "--top-module", top]
        entry = {"top": top, "build_command": command, "build_log": str(build_log.relative_to(root)),
                 "run_log": str(run_log.relative_to(root))}
        started = time.monotonic()
        with build_log.open("w") as stream:
            result = subprocess.run(["/usr/bin/time", "-v", *command], stdout=stream, stderr=subprocess.STDOUT, env=env)
        entry["build_seconds"] = time.monotonic() - started
        build_text = build_log.read_text()
        if result.returncode or re.search(r"%(?:Error|Warning-(?:LATCH|UNOPTFLAT|MULTIDRIVEN|ALWCOMBORDER))", build_text):
            entry["status"] = "FAIL_BUILD"
            receipt["cases"].append(entry)
            receipt["status"] = "FAIL"
            receipt_path.write_text(json.dumps(receipt, indent=2) + "\n")
            print(build_text[-6000:], flush=True)
            return 1
        started = time.monotonic()
        with run_log.open("w") as stream:
            result = subprocess.run(["/usr/bin/time", "-v", str(model / f"V{top}")], stdout=stream, stderr=subprocess.STDOUT, env=env)
        entry["run_seconds"] = time.monotonic() - started
        run_text = run_log.read_text()
        lines = [line for line in run_text.splitlines() if line.startswith(f"PASS {top}")]
        entry["pass_lines"] = lines
        entry["status"] = "PASS" if not result.returncode and lines and not re.search(r"%(?:Fatal|Error)|Assertion failed", run_text) else "FAIL_RUN"
        receipt["cases"].append(entry)
        receipt["status"] = "RUNNING" if entry["status"] == "PASS" else "FAIL"
        receipt_path.write_text(json.dumps(receipt, indent=2) + "\n")
        print(lines[-1] if entry["status"] == "PASS" else run_text[-4000:], flush=True)
        if entry["status"] != "PASS":
            return 1
    receipt["status"] = "PASS"
    receipt["pass_count"] = len(cases)
    receipt["skip_count"] = 0
    receipt_path.write_text(json.dumps(receipt, indent=2) + "\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
