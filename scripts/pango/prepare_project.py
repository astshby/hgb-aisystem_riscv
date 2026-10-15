#!/usr/bin/env python3
"""Stage an isolated native-Windows PDS SoC project; never program a device."""
import argparse
import hashlib
import json
from pathlib import Path, PureWindowsPath
import shutil
import subprocess
import sys
import re
import xml.etree.ElementTree as ET


def sources(repo, file_list):
    for line in (repo / file_list).read_text(encoding="utf-8").splitlines():
        line = line.split("#", 1)[0].strip()
        if not line:
            continue
        if line.startswith("-f "):
            yield from sources(repo, line[3:].strip())
        elif line.startswith("-"):
            raise ValueError(f"unsupported source-list option: {line}")
        else:
            source = (repo / line).resolve()
            source.relative_to(repo)
            if not source.is_file():
                raise ValueError(f"missing source: {line}")
            yield source


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True, help="empty local ASCII Windows directory")
    parser.add_argument("--ip-dir", type=Path, required=True, help="generated ddr3_test candidate directory")
    parser.add_argument("--xlen", type=int, choices=(32, 64), default=32)
    args = parser.parse_args()
    repo = Path(__file__).resolve().parents[2]
    root = args.output.resolve()
    # WSL 负责固件与 Python，PDS 仍在 Windows 本地盘运行；只接受可映射的原生盘目录。
    if sys.platform == "win32":
        native_root = str(root)
    else:
        try:
            native_root = subprocess.check_output(["wslpath", "-w", str(root)], text=True).strip()
        except (OSError, subprocess.CalledProcessError):
            parser.error("non-Windows staging requires WSL and wslpath")
    native = PureWindowsPath(native_root)
    if native.drive.startswith("\\\\") or not native.drive or not native_root.isascii():
        parser.error("output must be a native Windows drive path with ASCII characters")
    if any(c in root.as_posix() for c in "{}"):
        parser.error("braces are not permitted in the output path")
    if root == repo or repo in root.parents or root in repo.parents:
        parser.error("output must be separate from the repository")
    if root.exists() and any(root.iterdir()):
        parser.error("output must be empty; use a new directory to preserve earlier results")
    ip = args.ip_dir.resolve()
    ip_tree = ET.parse(ip / "ddr3_test.idf")
    params = {node.findtext("name"): node.findtext("value")
              for node in ip_tree.findall(".//param")}
    if ip_tree.findtext("./header/version") != "1.10":
        parser.error("this board workflow requires HMIC_S 1.10")
    subprocess.run([sys.executable, str(repo / "scripts/pango/check_ip_dq.py"),
                    str(ip / "ddr3_test.idf"), "--fdc",
                    str(repo / "scripts/pango/mes2l676_200hp.fdc")], check=True)
    firmware = repo / f"build/loader/rv{args.xlen}"
    staged = [(source, source.relative_to(repo)) for source in sources(repo, "scripts/pango_files.f")]
    for name in ("ddr3_test.v", "ddr3_test_ddrphy_top.v", "ddr3_test.idf"):
        staged.append((ip / name, Path("ip") / name))
    for source in sorted((ip / "rtl").rglob("*")):
        if source.is_file():
            staged.append((source, Path("ip") / source.relative_to(ip)))
    for name in ("imem.hex", "dmem.hex", "loader.elf"):
        staged.append((firmware / name, Path("firmware") / name))
    if any(not source.is_file() for source, _ in staged):
        parser.error("missing generated IP or production loader; generate IP and make loader first")
    elf = (firmware / "loader.elf").read_bytes()
    if elf[:4] != b"\x7fELF" or elf[4] != (1 if args.xlen == 32 else 2) or elf[18:20] != b"\xf3\x00":
        parser.error("loader ELF width mismatch")
    for name in ("imem.hex", "dmem.hex"):
        words = (firmware / name).read_text().split()
        if len(words) != 65536 // (args.xlen // 8) or any(len(word) != args.xlen // 4 for word in words):
            parser.error(f"invalid production TCM HEX: {name}")
        for word in words:
            int(word, 16)
    fdc = (ip / "pnr/ddr_test.fdc").read_text(encoding="utf-8")
    ref = re.search(r"create_clock -name \{ref_clk\}.*?-period \{([\d.]+)\}", fdc)
    generated = next((line for line in fdc.splitlines()
                      if line.startswith("create_generated_clock -name {ddrphy_sysclk}")), "")
    multiply = re.search(r"-multiply_by \{([\d.]+)\}", generated)
    divide = re.search(r"-divide_by \{([\d.]+)\}", generated)
    if not ref or not multiply or not divide:
        parser.error("missing explicit DDR reference/user-clock ratio")
    user_mhz = 1000.0 / float(ref[1]) * float(multiply[1]) / float(divide[1])
    if (abs(user_mhz - 125.0) > 1e-8 or float(params.get("ACTUAL_RATE", "0")) != 1000.0
            or int(params.get("DFI_CLK_PERIOD", "0")) != 8000):
        parser.error("baseline wrapper requires actual 125 MHz user clock / 1000 Mbps DDR")
    free_lines = [line for line in fdc.splitlines() if "free_clk" in line]
    if len(free_lines) != 2 or not free_lines[0].startswith("create_clock ") or not free_lines[1].startswith("set_clock_groups "):
        parser.error("unexpected reference free_clk constraints; review candidate manually")
    root.mkdir(parents=True, exist_ok=True)
    manifest = {"xlen": args.xlen, "mul": 0, "div": 1,
                "soc_clock_hz": int(user_mhz * 1000000),
                "ddr_actual_rate_mbps": float(params["ACTUAL_RATE"]),
                "device": "PG2L200H-6IFBB676", "top": "pango_200hp_top",
                "status": "candidate; no timing closure or board compatibility claim", "files": {}}
    for source, relative in staged:
        dest = root / relative
        dest.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source, dest)
        manifest["files"][relative.as_posix()] = hashlib.sha256(dest.read_bytes()).hexdigest()
    # 保持同一顶层层次，只移除例程专属且当前不存在的 free_clk 两行。
    constraints = "\n".join(line for line in fdc.splitlines() if "free_clk" not in line) + "\n"
    (root / "board_ddr.fdc").write_bytes(constraints.encode("utf-8"))
    manifest["removed_reference_constraints"] = free_lines
    manifest["files"]["board_ddr.fdc"] = hashlib.sha256((root / "board_ddr.fdc").read_bytes()).hexdigest()
    rtl = [relative for _, relative in staged if relative.suffix in (".sv", ".v", ".vp")]
    commands = ["# Offline ADS candidate flow; no JTAG/configuration commands.",
                "set_arch -family Logos2 -device PG2L200H -package FBB676 -speedgrade -6"]
    commands += [f"add_design {{{path.as_posix()}}}" for path in rtl]
    commands += ["add_constraint {board_ddr.fdc}",
                 "compile -top_module pango_200hp_top -verilog_standard SystemVerilog "
                 f"-compiler_directives {{CORE_XLEN={args.xlen} CORE_MUL_IMPL=0 CORE_DIV_IMPL=1}} "
                 '-defined_parameters {ITCM_INIT_FILE "firmware/imem.hex" DTCM_INIT_FILE "firmware/dmem.hex"} '
                 "-loop_limit 65536"]
    (root / "compile.tcl").write_text("\n".join(commands) + "\n", encoding="utf-8")
    (root / "synthesize.tcl").write_text("source compile.tcl\nsynthesize -ads -selected_syn_tool_opt 2\n", encoding="utf-8")
    shutil.copyfile(repo / "scripts/pango/implement.tcl", root / "implement.tcl")
    (root / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    print(f"PASS staged RV{args.xlen} m0d1 candidate: {len(rtl)} HDL files, {root}")
    print("Run pds_shell -work_dir <output> -project_name soc_rvN -file <output>/compile.tcl first.")


if __name__ == "__main__":
    main()
