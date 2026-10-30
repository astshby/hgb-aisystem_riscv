#!/usr/bin/env python3
"""Compile/run the independent 1080p AXI/AXI-Lite/MS7210 video RTL check.

The test includes real display, I2C and AXI-Lite routing RTL. It contains no RISC-V
core and does not establish that the complete CPU YOLO application has run.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shlex
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT / 'scripts'))
from hardware_config import hardware_configuration
COMMON = ["vsrc/pkg/core_config_pkg.sv", "vsrc/pkg/core_types_pkg.sv",
          "vsrc/pkg/bus_types_pkg.sv", "vsrc/pkg/axi_types_pkg.sv",
          "vsrc/soc/common/rv_fifo.sv", "vsrc/soc/common/async_fifo.sv",
          "vsrc/soc/bus/axil_to_bus.sv", "vsrc/soc/common/mmio_endpoint.sv"]
BENCH = ["tb/yolo/ms7210_i2c_model.sv", "tb/yolo/tb_video.sv"]


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def run(command, log, cwd, env=None):
    with log.open("w") as stream:
        stream.write(shlex.join(map(str, command)) + "\n"); stream.flush()
        subprocess.run(command, cwd=cwd, env=env, stdout=stream, stderr=subprocess.STDOUT, check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--xlen", type=int, choices=(32, 64), default=32,
                        help="exercise the shared Lite64 endpoint's two CPU-width lane adapters")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--log-root", type=Path)
    parser.add_argument("--jobs", type=int, default=1)
    parser.add_argument("--lint-only", action="store_true")
    args = parser.parse_args()
    if args.jobs < 1: parser.error("--jobs must be positive")
    output = args.output.resolve(); output.mkdir(parents=True, exist_ok=True)
    logs = args.log_root.resolve() if args.log_root else output
    logs.mkdir(parents=True, exist_ok=True)
    config = hardware_configuration('yolo',args.xlen)
    video = [line.strip() for line in (ROOT / "scripts/video_files.f").read_text().splitlines() if line.strip()]
    files = COMMON + video + BENCH
    identities = {name: sha(ROOT / name) for name in files +
                  ["scripts/video_files.f", "scripts/yolo/run_video.py", "tb/yolo/ms7210_registers.hex",
                   "scripts/hardware_config.py", "scripts/hardware_profile.json"]}
    digest = hashlib.sha256(json.dumps([args.xlen, identities], sort_keys=True).encode()).hexdigest()[:16]
    model = output / (f"model-rv{args.xlen}-" + digest)
    snapshot = model / "source"; snapshot.mkdir(parents=True, exist_ok=True)
    for name, expected in identities.items():
        target = snapshot / name; target.parent.mkdir(parents=True, exist_ok=True)
        if target.exists() and sha(target) != expected:
            raise ValueError("frozen video source differs: " + name)
        if not target.exists(): target.write_bytes((ROOT / name).read_bytes())
    command = ["verilator", "--lint-only" if args.lint_only else "--binary",
               "--timing", "--assert", "-Wall", "-Wno-fatal", f"-DCORE_XLEN={args.xlen}",
               f'-GSYS_PERIOD_NS={config["periods_ps"]["sys"]/1000}',
               f'-GPERIPH_PERIOD_NS={config["periods_ps"]["periph"]/1000}',
               f'-GPERIPH_HZ={config["frequencies_hz"]["periph"]}', *files, "--top-module", "tb_video"]
    binary = model / "Vtb_video"
    if not args.lint_only:
        command += ["-j", str(args.jobs), "--threads", "1", "--output-split", "5000",
                    "--output-split-cfuncs", "100", "-CFLAGS", "-O2 -g0", "-Mdir", str(model)]
    receipt = dict(status="PREPARED", xlen=args.xlen, source_sha256=identities, command=command,
                   commit=subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip(),
                   branch=subprocess.check_output(["git", "branch", "--show-current"], cwd=ROOT, text=True).strip(),
                   clocks_hz=dict(sys=config["frequencies_hz"]["sys"], periph=config["frequencies_hz"]["periph"], pixel=148500000),
                   geometry=[1920, 1080], total_raster=[2200, 1125], contains_riscv_core=False,
                   not_run=["FPGA board", "PDS video implementation", "complete RV32 YOLO firmware"])
    (logs / "prepared.json").write_text(json.dumps(receipt, indent=2) + "\n")
    if args.lint_only or not binary.exists():
        env = dict(os.environ, MAKEFLAGS=f"-j{args.jobs}",CCACHE_DIR=str(output/"ccache"),
                   CCACHE_TEMPDIR=str(output/"ccache-tmp"))
        Path(env["CCACHE_DIR"]).mkdir(parents=True,exist_ok=True)
        Path(env["CCACHE_TEMPDIR"]).mkdir(parents=True,exist_ok=True)
        run(command, logs / "lint.log" if args.lint_only else logs / "build.log", snapshot, env)
    if args.lint_only:
        receipt["status"] = "LINT_PASS"
    else:
        run([str(binary)], logs / "simulation.log", snapshot)
        text = (logs / "simulation.log").read_text()
        marker = f"PASS video 1920x1080 AXIL{args.xlen} "
        if marker not in text or "%Error" in text or "%Fatal" in text:
            raise ValueError("video RTL did not complete all checks")
        receipt.update(status="PASS", binary_sha256=sha(binary),
                       simulation_log_sha256=sha(logs / "simulation.log"),
                       pass_lines=[line for line in text.splitlines() if line.startswith("PASS ") or line.startswith("VIDEO_FRAME ")])
    (logs / "result.json").write_text(json.dumps(receipt, indent=2) + "\n")
    print(receipt["status"], "independent 1080p video RTL AXIL", args.xlen, "evidence:", logs / "result.json")


if __name__ == "__main__": main()
