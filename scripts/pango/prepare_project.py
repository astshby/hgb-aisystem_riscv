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


GENERATED_SCRIPTS = ("compile.tcl", "synthesize.tcl", "implement.tcl")
MEMORY_SCRIPTS = ("memory_guard.ps1", "memory_gate.ps1")
SYNTHESIZE_COMMANDS = "source compile.tcl\nsynthesize -ads -selected_syn_tool_opt 2\n"
SCOREBOARD_CONFIGURATION = {
    "core_backend": "scoreboard", "core_issue_width": 2, "core_retire_entries": 16,
    "core_issue_queue_entries": 8, "core_load_queue_entries": 4,
    "core_store_queue_entries": 4, "core_branch_checkpoints": 4,
    "core_predictor_mode": 0, "core_ras_enable": 0,
    "fetch_data_bits": 64, "data_ports": 2, "tcm_banks_per_region": 2,
    "dcache_banks": 2, "dcache_bytes": 4096, "icache_bytes": 4096,
}


def compile_command(xlen, profile_id, local_tcm, dma_wide=1,
                    cache_block=None, dma_block=None, core_issue_width=None, scoreboard=False,
                    scoreboard_config=None):
    dma_parameter = "" if dma_wide is None else f" DMA_WIDE_ENABLE {dma_wide}"
    block_parameters = ""
    if cache_block is not None:
        block_parameters += f" CACHE_BLOCK_ENABLE {cache_block}"
    if dma_block is not None:
        block_parameters += f" DMA_BLOCK_ENABLE {dma_block}"
    issue_directive = "" if core_issue_width is None else f" CORE_ISSUE_WIDTH={core_issue_width}"
    if scoreboard:
        if core_issue_width != 2:
            raise ValueError("scoreboard P0 requires issue width 2")
        issue_directive += (" CORE_SCOREBOARD=1 CORE_RETIRE_ENTRIES=16 CORE_ISSUE_QUEUE_ENTRIES=8"
                            " CORE_LOAD_QUEUE_ENTRIES=4 CORE_STORE_QUEUE_ENTRIES=4 CORE_BRANCH_CHECKPOINTS=4"
                            " CORE_PREDICTOR_MODE=0 CORE_RAS_ENABLE=0")
        if scoreboard_config is not None:
            for key in ("core_retire_entries", "core_issue_queue_entries", "core_predictor_mode", "core_ras_enable"):
                macro = key.upper()
                issue_directive = re.sub(rf"{macro}=\d+", f"{macro}={scoreboard_config[key]}", issue_directive)
            issue_directive += (f" CORE_SPLIT_ISSUE_QUEUE={scoreboard_config['core_split_issue_queue']}"
                                f" CORE_MEMORY_QUEUE_ENTRIES={scoreboard_config['core_memory_queue_entries']}")
            if "core_limited_integer_ooo" in scoreboard_config:
                issue_directive += f" CORE_LIMITED_INTEGER_OOO={scoreboard_config['core_limited_integer_ooo']}"
            if "core_scheduler_forward_mode" in scoreboard_config:
                issue_directive += f" CORE_SCHEDULER_FORWARD_MODE={scoreboard_config['core_scheduler_forward_mode']}"
    return ("compile -top_module pango_200hp_top -verilog_standard SystemVerilog "
            f"-compiler_directives {{CORE_XLEN={xlen} CORE_MUL_IMPL=0 CORE_DIV_IMPL=1{issue_directive}}} "
            '-defined_parameters {ITCM_INIT_FILE "firmware/imem.hex" '
            'DTCM_INIT_FILE "firmware/dmem.hex" '
            f'SOC_PROFILE {profile_id} LOCAL_TCM_ENABLE {local_tcm}{dma_parameter}{block_parameters}}} -loop_limit 65536')


def verify_staged_manifest(root, manifest):
    """Verify staged inputs; this function does not read or certify PDS results."""
    root = root.resolve()
    for name, expected in manifest["files"].items():
        path = (root / name).resolve()
        path.relative_to(root)
        if hashlib.sha256(path.read_bytes()).hexdigest() != expected:
            raise ValueError(f"staged byte hash mismatch: {name}")
    configuration = {key: manifest[key] for key in ("xlen", "mul", "div", "soc_clock_hz")}
    if "schema_version" not in manifest:
        # 旧清单没有覆盖生成 Tcl，不能由历史默认值推断已证实的外设或 TCM 配置。
        return dict(configuration, soc_profile="unknown", soc_profile_id="unknown",
                    local_tcm_enable="unknown", soc_presence="unknown",
                    slow_presence="unknown", dma_wide_enable="unknown", ddr_data_bits="unknown",
                    cache_block_enable="unknown", dma_block_enable="unknown", core_issue_width="unknown",
                    evidence="legacy: generated Tcl/configuration unverified")
    if type(manifest["schema_version"]) is not int or manifest["schema_version"] not in (1, 2, 3, 4, 5, 6, 7):
        raise ValueError("unsupported staging manifest schema")
    schema = manifest["schema_version"]
    if schema >= 2 and (type(manifest.get("dma_wide_enable")) is not int or
                        manifest.get("dma_wide_enable") != 1 or manifest.get("ddr_data_bits") != 256):
        raise ValueError("invalid staged native DMA configuration")
    # 新候选固定采用当前板级入口；旧清单只读兼容，不能追认后来新增的默认功能。
    if schema == 3:
        for key in ("cache_block_enable", "dma_block_enable", "core_issue_width"):
            if type(manifest.get(key)) is not int or manifest.get(key) != 1:
                raise ValueError(f"invalid staged block/issue configuration: {key}")
    scoreboard_config = dict(SCOREBOARD_CONFIGURATION)
    if schema >= 5:
        choices = {"core_retire_entries": (16, 32), "core_issue_queue_entries": (2, 4, 8, 16),
                   "core_split_issue_queue": (0, 1), "core_memory_queue_entries": (2, 4, 8),
                   "core_predictor_mode": (0, 1), "core_ras_enable": (0, 1)}
        if schema >= 6:
            choices["core_limited_integer_ooo"] = (0, 1)
        if schema >= 7:
            choices["core_scheduler_forward_mode"] = (0, 1, 2, 3)
        for key, allowed in choices.items():
            if type(manifest.get(key)) is not int or manifest[key] not in allowed:
                raise ValueError(f"invalid staged scheduler configuration: {key}")
            scoreboard_config[key] = manifest[key]
        if schema >= 6 and manifest["core_limited_integer_ooo"] and not manifest["core_split_issue_queue"]:
            raise ValueError("limited integer issue requires split queues")
    if schema >= 4:
        for key, expected in dict(scoreboard_config, cache_block_enable=1, dma_block_enable=1).items():
            if type(manifest.get(key)) is not type(expected) or manifest[key] != expected:
                raise ValueError(f"invalid staged scoreboard configuration: {key}")
        for name in ("imem.hex", "dmem.hex"):
            original = (root / "firmware" / name).read_text().split()
            for bank in range(2):
                bank_name = f"firmware/{name}.bank{bank}"
                if bank_name not in manifest["files"]:
                    raise ValueError(f"TCM bank image not covered by manifest: {bank_name}")
                if (root / bank_name).read_text().split() != original[bank::2]:
                    raise ValueError(f"incorrect TCM interleaving: {bank_name}")
    profile = manifest.get("soc_profile")
    local_tcm = manifest.get("local_tcm_enable")
    if profile not in ("full", "lite") or type(local_tcm) is not int or local_tcm not in (0, 1):
        raise ValueError("invalid staged SoC profile/local-TCM configuration")
    profile_id = int(profile == "lite")
    present = 0x727f if profile_id else 0x7fff
    slow_present = present & (0x7ff3 if local_tcm or schema >= 4 else 0x7fff)
    if (manifest.get("soc_profile_id") != profile_id or
            manifest.get("soc_presence") != f"0x{present:04x}" or
            manifest.get("slow_presence") != f"0x{slow_present:04x}"):
        raise ValueError("inconsistent staged SoC presence/profile configuration")
    if (type(manifest["xlen"]) is not int or manifest["xlen"] not in (32, 64) or
            (manifest["mul"], manifest["div"], manifest["soc_clock_hz"]) != (0, 1, 125000000) or
            manifest.get("top") != "pango_200hp_top"):
        raise ValueError("unexpected board wrapper configuration")
    for name in GENERATED_SCRIPTS:
        if name not in manifest["files"]:
            raise ValueError(f"generated script not covered by manifest: {name}")
    if manifest.get("memory_guard_version") == 1:
        for name in MEMORY_SCRIPTS:
            if name not in manifest["files"]:
                raise ValueError(f"memory guard not covered by manifest: {name}")
    commands = [line.strip() for line in (root / "compile.tcl").read_text(encoding="utf-8").splitlines()
                if line.strip().startswith("compile")]
    if commands != [compile_command(manifest["xlen"], profile_id, local_tcm,
                                    1 if schema >= 2 else None,
                                    1 if schema >= 3 else None, 1 if schema >= 3 else None,
                                    2 if schema >= 4 else (1 if schema == 3 else None),
                                    scoreboard=schema >= 4,
                                    scoreboard_config=scoreboard_config if schema >= 5 else None)]:
        raise ValueError("compile Tcl parameters differ from staging manifest")
    if (root / "synthesize.tcl").read_text(encoding="utf-8") != SYNTHESIZE_COMMANDS:
        raise ValueError("unexpected generated synthesis commands")
    configuration.update({key: manifest[key] for key in
                          ("soc_profile", "soc_profile_id", "local_tcm_enable",
                           "soc_presence", "slow_presence")})
    configuration["dma_wide_enable"] = 1 if schema >= 2 else "unknown"
    configuration["ddr_data_bits"] = 256 if schema >= 2 else "unknown"
    for key in ("cache_block_enable", "dma_block_enable", "core_issue_width"):
        configuration[key] = manifest[key] if schema >= 3 else "unknown"
    if schema >= 4:
        configuration.update({key: manifest[key] for key in scoreboard_config})
    configuration["evidence"] = (f"schema {schema}: staged hashes and compile parameters verified "
                                 "(input evidence only)" +
                                 ("; legacy DMA configuration unknown" if schema == 1 else "") +
                                 ("; legacy block/issue configuration unknown" if schema < 3 else ""))
    return configuration


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
    parser.add_argument("--soc-profile", choices=("full", "lite"), default="full")
    parser.add_argument("--local-tcm", type=int, choices=(0, 1), default=0)
    parser.add_argument("--core-backend", choices=("legacy", "scoreboard"), default="legacy",
                        help="scoreboard selects explicit dual-issue scheduler parameters")
    parser.add_argument("--retire-entries", type=int, choices=(16, 32), default=32)
    parser.add_argument("--split-issue-queue", type=int, choices=(0, 1), default=1)
    parser.add_argument("--limited-integer-ooo", type=int, choices=(0, 1), default=0)
    parser.add_argument("--scheduler-forward-mode", type=int, choices=(0, 1, 2, 3), default=0)
    parser.add_argument("--integer-queue-entries", type=int, choices=(2, 4, 8, 16), default=8)
    parser.add_argument("--memory-queue-entries", type=int, choices=(2, 4, 8), default=4)
    parser.add_argument("--predictor-mode", type=int, choices=(0, 1), default=0)
    parser.add_argument("--ras-enable", type=int, choices=(0, 1), default=0)
    args = parser.parse_args()
    if args.limited_integer_ooo and (args.core_backend != "scoreboard" or not args.split_issue_queue):
        parser.error("limited integer issue requires scoreboard and split queues")
    if args.scheduler_forward_mode and args.core_backend != "scoreboard":
        parser.error("scheduler forward mode requires scoreboard")
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
    if (len(elf) < (52 if args.xlen == 32 else 64) or elf[:4] != b"\x7fELF" or
            elf[4] != (1 if args.xlen == 32 else 2) or elf[18:20] != b"\xf3\x00"):
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
    profile_id = 0 if args.soc_profile == "full" else 1
    present = 0x7fff if profile_id == 0 else 0x727f
    scoreboard = args.core_backend == "scoreboard"
    manifest = {"schema_version": 7 if scoreboard else 3, "xlen": args.xlen, "mul": 0, "div": 1,
                "dma_wide_enable": 1, "ddr_data_bits": 256,
                "cache_block_enable": 1, "dma_block_enable": 1, "core_issue_width": 1,
                "soc_profile": args.soc_profile, "soc_profile_id": profile_id,
                "local_tcm_enable": args.local_tcm, "soc_presence": f"0x{present:04x}",
                "slow_presence": f"0x{present & (0x7ff3 if args.local_tcm or scoreboard else 0x7fff):04x}",
                "soc_clock_hz": int(user_mhz * 1000000),
                "ddr_actual_rate_mbps": float(params["ACTUAL_RATE"]),
                "device": "PG2L200H-6IFBB676", "top": "pango_200hp_top",
                "status": "candidate; no timing closure or board compatibility claim", "files": {}}
    if scoreboard:
        manifest.update(SCOREBOARD_CONFIGURATION)
        manifest.update(core_retire_entries=args.retire_entries,
                        core_split_issue_queue=args.split_issue_queue,
                        core_limited_integer_ooo=args.limited_integer_ooo,
                        core_scheduler_forward_mode=args.scheduler_forward_mode,
                        core_issue_queue_entries=args.integer_queue_entries,
                        core_memory_queue_entries=args.memory_queue_entries,
                        core_predictor_mode=args.predictor_mode, core_ras_enable=args.ras_enable)
    try:
        manifest["source_commit"] = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=repo, text=True,
                                                            stderr=subprocess.DEVNULL).strip()
        manifest["source_branch"] = subprocess.check_output(["git", "branch", "--show-current"], cwd=repo,
                                                            text=True, stderr=subprocess.DEVNULL).strip()
        manifest["source_status"] = subprocess.check_output(["git", "status", "--porcelain"], cwd=repo,
                                                            text=True, stderr=subprocess.DEVNULL).splitlines()
    except subprocess.CalledProcessError:
        manifest["source_commit"] = "unavailable"
    for source, relative in staged:
        dest = root / relative
        dest.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source, dest)
        manifest["files"][relative.as_posix()] = hashlib.sha256(dest.read_bytes()).hexdigest()
    if scoreboard:
        for name in ("imem.hex", "dmem.hex"):
            words = (root / "firmware" / name).read_text().split()
            for bank in range(2):
                relative = f"firmware/{name}.bank{bank}"
                (root / relative).write_text("\n".join(words[bank::2]) + "\n", encoding="ascii")
                manifest["files"][relative] = hashlib.sha256((root / relative).read_bytes()).hexdigest()
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
                 compile_command(args.xlen, profile_id, args.local_tcm,
                                 dma_wide=1, cache_block=1, dma_block=1,
                                 core_issue_width=2 if scoreboard else 1, scoreboard=scoreboard,
                                 scoreboard_config=manifest if scoreboard else None)]
    (root / "compile.tcl").write_text("\n".join(commands) + "\n", encoding="utf-8")
    (root / "synthesize.tcl").write_text(SYNTHESIZE_COMMANDS, encoding="utf-8")
    shutil.copyfile(repo / "scripts/pango/implement.tcl", root / "implement.tcl")
    for name in MEMORY_SCRIPTS:
        shutil.copyfile(repo / "scripts/pango" / name, root / name)
    manifest["memory_guard_version"] = 1
    for name in GENERATED_SCRIPTS + MEMORY_SCRIPTS:
        manifest["files"][name] = hashlib.sha256((root / name).read_bytes()).hexdigest()
    verify_staged_manifest(root, manifest)
    (root / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    print(f"PASS staged RV{args.xlen} m0d1 profile={args.soc_profile} "
          f"local_tcm={args.local_tcm} dma_wide=1 ddr_data=256 cache_block=1 dma_block=1 "
          f"core_backend={args.core_backend} core_issue_width={2 if scoreboard else 1} "
          f"candidate: {len(rtl)} HDL files, {root}")
    print("Run pds_shell -work_dir <output> -project_name soc_rvN -file <output>/compile.tcl first.")


if __name__ == "__main__":
    main()
