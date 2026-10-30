#!/usr/bin/env python3
"""Prepare and exercise the applications present in this checkout."""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]


def applications():
    profile = json.loads((ROOT / "scripts/branch_profile.json").read_text())
    result = []
    if profile.get("coremark"):
        result.append("coremark")
    if "yolo" in profile.get("accelerators", []):
        result.append("yolo")
    if "minimind" in profile.get("accelerators", []):
        result.append("minimind")
    if profile.get("rt_thread"):
        result.append("rt-thread")
    return result


def run(command, env):
    print("+ " + " ".join(map(str, command)), flush=True)
    subprocess.run(list(map(str, command)), cwd=ROOT, env=env, check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("list", "doctor", "prepare", "build", "test"))
    parser.add_argument("--app", default="all")
    parser.add_argument("--xlen", choices=("32", "64", "both"), default="32")
    args = parser.parse_args()
    available = applications()
    if args.app != "all" and args.app not in available:
        parser.error(f"{args.app} is absent in this branch; choose {', '.join(available)}")
    selected = available if args.app == "all" else [args.app]
    if args.action == "list":
        print("Applications: " + ", ".join(available))
        return
    env = os.environ.copy()
    env.setdefault("SOFTWARE_OPT", "O3")
    env.setdefault("JOBS", "1")
    env.setdefault("MM3_DEMO_ASSETS", str(ROOT / "software/minimind3/c_runtime/assets"))
    env.setdefault("MM3_DEMO_OUT", str(ROOT / "build/minimind-demo"))
    env.setdefault("YOLO_NETWORK_OUT", str(ROOT / "build/yolo/network-native"))
    if args.action == "doctor":
        missing = []
        for tool in ("git", "make", "cc", "verilator"):
            value = shutil.which(tool)
            print(f"{tool}: {value or 'MISSING'}")
            if not value:
                missing.append(tool)
        prefix = env.get("CROSS_COMPILE") or str(Path(env.get("RISCV_TOOL_ROOT", "")) / "riscv64-unknown-elf-")
        compiler = shutil.which(prefix + "gcc")
        print(f"RISC-V compiler: {compiler or 'MISSING; set RISCV_TOOL_ROOT'}")
        if not compiler:
            missing.append("RISC-V compiler")
        print(f"Python: {sys.version.split()[0]}; applications: {', '.join(selected)}")
        if sys.version_info < (3, 10):
            missing.append("Python >=3.10")
        if missing:
            parser.exit(1, "Missing: " + ", ".join(missing) + "\n")
        return
    widths = ("32", "64") if args.xlen == "both" else (args.xlen,)
    for app in selected:
        if args.action == "prepare":
            if app == "yolo":
                run([sys.executable, "scripts/yolo/prepare_assets.py"], env)
            elif app == "minimind":
                run([sys.executable, "scripts/minimind/prepare_assets.py"], env)
            elif app == "rt-thread":
                run(["bash", "scripts/rt-thread/fetch.sh"], env)
            else:
                for name in ("core_main.c", "core_list_join.c", "core_matrix.c", "core_state.c", "core_util.c"):
                    if not (ROOT / "benchmark/coremark/vendor/coremark" / name).is_file():
                        raise FileNotFoundError(name)
                print("PASS CoreMark: official sources are included; no download")
        elif args.action == "build":
            if app == "yolo":
                run(["bash", "scripts/demo/build_yolo_network.sh"], env)
            elif app == "minimind":
                run(["make", "minimind-demo-native"], env)
            for width in widths:
                target = {"coremark": "coremark-board", "yolo": "yolo-demo-build",
                          "minimind": "minimind-demo-build", "rt-thread": "rt-thread-demo"}[app]
                run(["make", target, f"XLEN={width}"], env)
        else:
            target = {"coremark": "coremark-board-test", "yolo": "yolo-demo-test",
                      "minimind": "minimind-demo-test", "rt-thread": "rt-thread-demo-test"}[app]
            run(["make", target], env)
    print(f"PASS software {args.action}: {', '.join(selected)}")


if __name__ == "__main__":
    try:
        main()
    except (OSError, subprocess.CalledProcessError) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        sys.exit(1)
