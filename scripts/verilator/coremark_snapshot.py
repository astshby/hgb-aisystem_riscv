#!/usr/bin/env python3
"""Freeze validated CoreMark images, then replay identical bytes on a chosen RTL build.

Freeze example (source image/log artifacts are never modified):
  python3 scripts/verilator/coremark_snapshot.py freeze SOURCE DEST --xlen 32 \
      --log-dir logs --max-cycles 100000000 --source-revision COMMIT
Replay through the usual runner with COREMARK_REPLAY_DIR=DEST. Set
COREMARK_REPLAY_SIM and COREMARK_REPLAY_SIM_SOURCE to use an existing simulator;
otherwise the current checkout's RTL simulator is built. No replay builds software.
COREMARK_REPLAY_ALLOW_SHORT=1 permits only the known minimum-duration error, with
identical iterations and every CRC checked against the fully validated snapshot.
"""

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import struct
import subprocess
import sys
import tempfile


MODES = ("performance", "validation")
IMAGE_FILES = ("program.elf", "imem.hex", "dmem.hex")
CRC_FIELDS = ("seedcrc", "[0]crclist", "[0]crcmatrix", "[0]crcstate", "[0]crcfinal")
DURATION_ERROR = "ERROR! Must execute for at least 10 secs for a valid result!"


def require(condition, message):
    if not condition:
        raise ValueError(message)


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def positive(value):
    result = int(value)
    require(0 < result <= 2147483647, "value must be in 1..2147483647")
    return result


def configuration(xlen):
    require(xlen in (32, 64), "XLEN must be 32 or 64")
    cfg = {"xlen": xlen, "mul_impl": int(os.environ.get("MUL_IMPL", "0")),
           "div_impl": int(os.environ.get("DIV_IMPL", "0")),
           "soc": int(os.environ.get("SOC", "0")),
           "ddr_bytes": int(os.environ.get("SOC_DDR_BYTES", "0")),
           "dcache_enable": int(os.environ.get("SOC_DCACHE_ENABLE", "1"))}
    require(cfg["mul_impl"] in (0, 1, 2) and cfg["div_impl"] in (0, 1), "invalid MDU backend")
    require(cfg["soc"] in (0, 1) and cfg["dcache_enable"] in (0, 1), "invalid SoC/cache setting")
    require(0 <= cfg["ddr_bytes"] <= 2147483647, "invalid DDR size")
    require(cfg["soc"] or cfg["ddr_bytes"] == 0, "DDR requires SOC=1")
    cfg["layout"] = "soc-tcm" if cfg["soc"] else "core-harvard"
    cfg["software_isa"] = f"rv{xlen}im_zicsr"
    cfg["abi"] = "ilp32" if xlen == 32 else "lp64"
    return cfg


def config_name(cfg):
    name = f"m{cfg['mul_impl']}d{cfg['div_impl']}"
    if cfg["soc"]:
        name += "-soc"
        if cfg["ddr_bytes"]:
            name += f"-ddr{cfg['ddr_bytes']}"
        if cfg["dcache_enable"] != 1:
            name += f"-dcache{cfg['dcache_enable']}"
    return name


def runtime_configuration(cfg):
    local_tcm = os.environ.get("SOC_LOCAL_TCM_ENABLE", "0")
    profile = os.environ.get("SOC_PROFILE", "full")
    dma_wide = os.environ.get("SOC_DMA_WIDE_ENABLE", "0")
    cache_block = os.environ.get("SOC_CACHE_BLOCK_ENABLE", "0")
    dma_block = os.environ.get("SOC_DMA_BLOCK_ENABLE", "0")
    require(local_tcm in ("0", "1"), "SOC_LOCAL_TCM_ENABLE must be 0 or 1")
    require(profile in ("full", "lite"), "SOC_PROFILE must be full or lite")
    require(dma_wide in ("0", "1"), "SOC_DMA_WIDE_ENABLE must be 0 or 1")
    require(cache_block in ("0", "1"), "SOC_CACHE_BLOCK_ENABLE must be 0 or 1")
    require(dma_block in ("0", "1"), "SOC_DMA_BLOCK_ENABLE must be 0 or 1")
    require(cfg["soc"] or local_tcm == "0", "local TCM routing requires SOC=1")
    require(cfg["soc"] or profile == "full", "lite device profile requires SOC=1")
    require(cfg["soc"] or dma_wide == "0", "wide DMA requires SOC=1")
    require(cfg["soc"] or cache_block == "0", "cache block port requires SOC=1")
    require(cfg["soc"] or dma_block == "0", "block DMA requires SOC=1")
    name = config_name(cfg)
    supported = False
    profile_supported = False
    dma_wide_supported = False
    cache_block_supported = False
    dma_block_supported = False
    reported_backend = "unsupported"
    reported_model_bytes = "unsupported"
    reported_clock_hz = "unsupported"
    reported_uart_divisor = "unsupported"
    core_fields = ["unsupported"] * 4
    helper = Path("scripts/verilator/benchmark_platform.sh")
    if helper.is_file():
        # 名称由待测工作区的构建助手决定；旧基线没有 local-TCM 参数，仍可重放。
        command = ('config="$1"; source scripts/verilator/benchmark_platform.sh; '
                   'printf "%s\\n%s\\n%s\\n%s\\n%s\\n%s\\n%s\\n%s\\n%s\\n%s\\n%s\\n%s\\n%s\\n%s\\n%s\\n%s\\n%s\\n%s\\n%s\\n" "$config" '
                   '"${bench_local_tcm_enable-unsupported}" "${bench_soc_profile-unsupported}" '
                   '"${core_predictor_mode-unsupported}" "${core_ras_enable-unsupported}" '
                   '"${core_retire_entries-unsupported}" "${bench_dma_wide_enable-unsupported}" '
                   '"${core_issue_width-unsupported}" "${bench_cache_block_enable-unsupported}" '
                   '"${bench_dma_block_enable-unsupported}" "${core_backend-unsupported}" '
                   '"${bench_ddr_model_bytes-unsupported}" "${bench_clock_hz-unsupported}" '
                   '"${bench_uart_divisor-unsupported}" '
                   '"${core_split_issue_queue-unsupported}" "${core_integer_queue_entries-unsupported}" '
                   '"${core_memory_queue_entries-unsupported}" "${core_limited_integer_ooo-unsupported}" '
                   '"${core_scheduler_forward_mode-unsupported}"')
        output = subprocess.check_output(["bash", "-euc", command, "snapshot",
                                          f"m{cfg['mul_impl']}d{cfg['div_impl']}"], text=True)
        fields = output.splitlines()
        require(len(fields) == 19 and re.fullmatch(r"[a-zA-Z0-9_-]+", fields[0]),
                "invalid benchmark platform configuration output")
        name, reported_local_tcm, reported_profile = fields[:3]
        reported_backend, reported_model_bytes = fields[10:12]
        reported_clock_hz, reported_uart_divisor = fields[12:14]
        for variable, reported in (("SOC_CLOCK_HZ", reported_clock_hz), ("SOC_UART_DIVISOR", reported_uart_divisor)):
            require(reported == "unsupported" or (reported.isdecimal() and int(reported) > 0),
                    f"invalid reported {variable}")
            if variable in os.environ:
                require(reported == os.environ[variable], f"benchmark helper disagrees with {variable}")
        require(reported_backend in ("unsupported", "legacy", "scoreboard"), "invalid reported core backend")
        requested_backend = os.environ.get("CORE_BACKEND")
        require(requested_backend is None or requested_backend == reported_backend,
                "benchmark helper disagrees with requested core backend")
        require(reported_model_bytes == "unsupported" or reported_model_bytes.isdecimal(),
                "invalid reported simulated DDR size")
        if "SOC_DDR_MODEL_BYTES" in os.environ:
            require(reported_model_bytes == os.environ["SOC_DDR_MODEL_BYTES"],
                    "benchmark helper disagrees with simulated DDR size")
        core_fields = fields[3:6] + [fields[7]]
        reported_dma_wide = fields[6]
        require(reported_local_tcm in ("unsupported", "0", "1"), "invalid local TCM capability")
        require(reported_profile in ("unsupported", "full", "lite"), "invalid device profile capability")
        supported = reported_local_tcm != "unsupported"
        profile_supported = reported_profile != "unsupported"
        require(reported_dma_wide in ("unsupported", "0", "1"), "invalid wide DMA capability")
        dma_wide_supported = reported_dma_wide != "unsupported"
        reported_cache_block = fields[8]
        require(reported_cache_block in ("unsupported", "0", "1"), "invalid cache block capability")
        cache_block_supported = reported_cache_block != "unsupported"
        reported_dma_block = fields[9]
        require(reported_dma_block in ("unsupported", "0", "1"), "invalid block DMA capability")
        dma_block_supported = reported_dma_block != "unsupported"
        require(not supported or reported_local_tcm == local_tcm,
                "benchmark helper disagrees with requested local TCM setting")
        require(not profile_supported or reported_profile == profile,
                "benchmark helper disagrees with requested device profile")
        require(not dma_wide_supported or reported_dma_wide == dma_wide,
                "benchmark helper disagrees with requested wide DMA setting")
        require(not cache_block_supported or reported_cache_block == cache_block,
                "benchmark helper disagrees with requested cache block setting")
        require(not dma_block_supported or reported_dma_block == dma_block,
                "benchmark helper disagrees with requested block DMA setting")
    require(supported or local_tcm == "0", "current checkout does not support SOC_LOCAL_TCM_ENABLE=1")
    require(profile_supported or profile == "full", "current checkout does not support SOC_PROFILE=lite")
    require(dma_wide_supported or dma_wide == "0", "current checkout does not support SOC_DMA_WIDE_ENABLE=1")
    require(cache_block_supported or cache_block == "0", "current checkout does not support SOC_CACHE_BLOCK_ENABLE=1")
    require(dma_block_supported or dma_block == "0", "current checkout does not support SOC_DMA_BLOCK_ENABLE=1")
    # 微架构属于候选RTL，不改变冻结ELF的合同；旧助手没有报告的参数保持unknown。
    core_parameters = {}
    for field, variable, reported, allowed in (
        ("predictor_mode", "PREDICTOR_MODE", core_fields[0], ("0", "1")),
        ("ras_enable", "RAS_ENABLE", core_fields[1], ("0", "1")),
        ("retire_entries", "RETIRE_ENTRIES", core_fields[2], ("2", "4", "8", "16", "32")),
        ("issue_width", "ISSUE_WIDTH", core_fields[3], ("1", "2")),
    ):
        requested = os.environ.get(variable)
        require(requested is None or requested in allowed, f"invalid {variable}")
        require(reported == "unsupported" or reported in allowed,
                f"invalid benchmark helper {field}")
        if requested is not None:
            require(reported != "unsupported", f"current checkout does not report {variable}")
            require(reported == requested, f"benchmark helper disagrees with requested {variable}")
        core_parameters[field] = int(reported) if reported != "unsupported" else None
        core_parameters[f"{field}_parameter_supported"] = reported != "unsupported"
    for field, variable, reported, allowed in (
        ("split_issue_queue", "SPLIT_ISSUE_QUEUE", fields[14] if helper.is_file() else "unsupported", ("0", "1")),
        ("integer_queue_entries", "INTEGER_QUEUE_ENTRIES", fields[15] if helper.is_file() else "unsupported", ("2", "4", "8", "16")),
        ("memory_queue_entries", "MEMORY_QUEUE_ENTRIES", fields[16] if helper.is_file() else "unsupported", ("2", "4", "8")),
        ("limited_integer_ooo", "LIMITED_INTEGER_OOO", fields[17] if helper.is_file() else "unsupported", ("0", "1")),
        ("scheduler_forward_mode", "SCHEDULER_FORWARD_MODE", fields[18] if helper.is_file() else "unsupported", ("0", "1", "2", "3")),
    ):
        requested = os.environ.get(variable)
        require(requested is None or requested in allowed, f"invalid {variable}")
        require(reported == "unsupported" or reported in allowed, f"invalid benchmark helper {field}")
        require(requested is None or reported == requested, f"benchmark helper disagrees with {variable}")
        core_parameters[field] = int(reported) if reported != "unsupported" else None
        core_parameters[f"{field}_parameter_supported"] = reported != "unsupported"
    # 只给已选中的新 SoC 增加实际拓扑，旧快照和旧 helper 的字段契约保持。
    topology = ({"system_bus": "axi4", "actual_local_tcm": True,
                 "actual_cache_block": True, "actual_unified_dma": True}
                if cfg["soc"] and reported_backend == "scoreboard" else {})
    return name, {**topology, "local_tcm_enable": int(local_tcm) if cfg["soc"] else None,
                  "core_backend": reported_backend if reported_backend != "unsupported" else None,
                  "ddr_model_bytes": int(reported_model_bytes) if reported_model_bytes != "unsupported" else None,
                  "soc_clock_hz": int(reported_clock_hz) if cfg["soc"] and reported_clock_hz != "unsupported" else None,
                  "uart_divisor": int(reported_uart_divisor) if cfg["soc"] and reported_uart_divisor != "unsupported" else None,
                  "local_tcm_parameter_supported": supported and bool(cfg["soc"]),
                  "soc_profile": profile if cfg["soc"] else None,
                  "soc_profile_parameter_supported": profile_supported and bool(cfg["soc"]),
                  "dma_wide_enable": int(dma_wide) if cfg["soc"] else None,
                  "dma_wide_parameter_supported": dma_wide_supported and bool(cfg["soc"]),
                  "cache_block_enable": int(cache_block) if cfg["soc"] else None,
                  "cache_block_parameter_supported": cache_block_supported and bool(cfg["soc"]),
                  "dma_block_enable": int(dma_block) if cfg["soc"] else None,
                  "dma_block_parameter_supported": dma_block_supported and bool(cfg["soc"]),
                  **core_parameters}


def scoreboard_metrics(text, harness_cycles, counter_offset=1):
    records = re.findall(r"^SCOREBOARD_STATS (.+)$", text, re.M)
    if not records:
        return {}
    require(len(records) == 1, "duplicate scoreboard metrics")
    metrics = json.loads(records[0])
    names = {"cycles", "issue_0", "issue_1", "issue_2", "retire_0", "retire_1", "retire_2",
             "no_issue_redirect", "no_issue_empty", "no_issue_raw", "no_issue_lsq",
             "no_issue_mdu", "no_issue_serial", "no_issue_result", "no_issue_other",
             "dispatch_rob_full", "dispatch_iq_full", "dispatch_checkpoint",
             "completion_pressure", "memory_requests", "memory_responses", "forwarded_loads"}
    require(isinstance(metrics, dict) and set(metrics) == names | {"window"} and
            metrics["window"] == "whole_run", "invalid scoreboard metrics schema/window")
    require(all(type(metrics[key]) is int and metrics[key] >= 0 for key in names),
            "invalid scoreboard metrics counter")
    cycles = metrics["cycles"]
    require(cycles == harness_cycles + counter_offset, "scoreboard metrics/harness window mismatch")
    for group in ("issue", "retire"):
        require(sum(metrics[f"{group}_{index}"] for index in range(3)) == cycles,
                f"scoreboard {group} cycle partition mismatch")
    require(sum(value for key, value in metrics.items() if key.startswith("no_issue_")) ==
            metrics["issue_0"], "scoreboard no-issue partition mismatch")
    for key in ("dispatch_rob_full", "dispatch_iq_full", "dispatch_checkpoint", "completion_pressure"):
        require(metrics[key] <= cycles, f"scoreboard overlapping counter exceeds window: {key}")
    for key in ("memory_requests", "memory_responses", "forwarded_loads"):
        require(metrics[key] <= 2 * cycles, f"scoreboard dual-port counter exceeds window: {key}")
    return {"scoreboard_metrics": metrics}


def scheduler_metrics(text, harness_cycles, counter_offset=1):
    records = re.findall(r"^SCHEDULER_STATS (.+)$", text, re.M)
    if not records:
        return {}
    require(len(records) == 1, "duplicate scheduler metrics")
    metrics = json.loads(records[0])
    names = {"cycles", "occupied_cycles", "ready_cycles", "full_cycles", "raw_cycles",
             "raw_alu_cycles", "raw_mdu_cycles", "raw_load_cycles", "mdu_resource_cycles",
             "mdu_iq_idle_cycles", "accepted_cycles", "accepted_operations",
             "bypass_raw_cycles", "bypass_mdu_cycles"}
    require(isinstance(metrics, dict) and set(metrics) == names | {"window"} and
            metrics["window"] == "whole_run", "invalid scheduler metrics schema/window")
    require(all(type(metrics[key]) is int and metrics[key] >= 0 for key in names),
            "invalid scheduler metrics counter")
    require(metrics["cycles"] == harness_cycles + counter_offset, "scheduler metrics/harness window mismatch")
    require(all(metrics[key] <= metrics["cycles"] for key in names - {"accepted_operations"}),
            "scheduler cycle counter exceeds window")
    require(metrics["accepted_cycles"] <= metrics["accepted_operations"] <= 2 * metrics["accepted_cycles"],
            "scheduler accepted operation count exceeds dual-issue bounds")
    # RAW、MDU 和各类队列状态可重叠；不把这些周期相加当作停顿总数。
    return {"scheduler_metrics": metrics}


def result_fields(log, mode, xlen, allow_short=False):
    text = log.read_text()
    require(not re.search(r"%Fatal|%Error|Assertion failed", text), f"failure in {log}")
    require(f"2K {mode} run parameters for coremark." in text, f"wrong mode in {log}")
    clock_suffix = (r" clocks=C(?P<configuration>[0-4])"
                    r" core_half_ns=(?P<core>[0-9]+\.[0-9]+)"
                    r" sys_half_ns=(?P<sys>[0-9]+\.[0-9]+)"
                    r" ddr_half_ns=(?P<ddr>[0-9]+\.[0-9]+)"
                    r" periph_half_ns=(?P<periph>[0-9]+\.[0-9]+) SPI_reads=(?P<spi_reads>[0-9]+)")
    completion = list(re.finditer(rf"^PASS coremark-{mode} RV{xlen} cycles=(?P<cycles>\d+)"
                                 rf"(?:{clock_suffix})?$", text, re.M))
    require(len(completion) == 1, f"missing/duplicate exact benchmark PASS in {log}")
    harness_cycles = positive(completion[0]['cycles'])
    clock_fields = {}
    # M0/旧 SoC 的 for-loop 报零基退出索引，监测器多计一拍。
    # 四域 SoC 的未复位 TB cycles 含初始化首沿，Core 监测器经复位后少一拍。
    # 按明确的 TB 输出契约选择固定偏移；不接受任意 +/-1 容差。
    counter_offset = -1 if completion[0]['configuration'] is not None else 1
    if completion[0]['configuration'] is not None:
        periods = {domain: float(completion[0][domain]) for domain in ('core', 'sys', 'ddr', 'periph')}
        require(all(value > 0 for value in periods.values()), f"nonpositive clock half period in {log}")
        clock_fields = {"simulation_clocks": {"configuration": "C" + completion[0]['configuration'],
                                            "half_period_ns": periods,
                                            "spi_reads": int(completion[0]['spi_reads'])}}
    errors = [line for line in text.splitlines() if re.search(r"error|cannot validate", line, re.I)]
    duration_valid = "Correct operation validated" in text
    if duration_valid:
        require(not errors, f"error accompanies validation banner in {log}")
    else:
        require(allow_short and errors == [DURATION_ERROR, "Errors detected"],
                f"missing validation or unexpected error in {log}; short-duration replay requires explicit opt-in")

    def field(label, pattern):
        matches = re.findall(rf"^{re.escape(label)}\s*:\s*({pattern})\s*$", text, re.M)
        require(len(matches) == 1, f"expected one {label} in {log}")
        return matches[0]

    ticks = positive(field("Total ticks", r"\d+"))
    seconds = int(field("Total time (secs)", r"\d+"))
    require(seconds == ticks // 1000000, f"unexpected cycle/timing basis in {log}")
    require(duration_valid == (seconds >= 10), f"inconsistent duration result in {log}")
    return {"iterations": positive(field("Iterations", r"\d+")), "ticks": ticks,
            "harness_cycles": harness_cycles,
            "duration_valid": duration_valid,
            "crc": {key: field(key, r"0x[0-9a-fA-F]+").lower() for key in CRC_FIELDS},
            "compiler_version": field("Compiler version", r"[^\n]+"),
            "compiler_flags": field("Compiler flags", r"[^\n]+"),
            **scoreboard_metrics(text, harness_cycles, counter_offset),
            **scheduler_metrics(text, harness_cycles, counter_offset), **clock_fields}


def elf_metadata(elf, cfg):
    data = elf.read_bytes()
    require(len(data) >= 64 and data[:4] == b"\x7fELF", f"invalid ELF: {elf}")
    require(data[4] == (1 if cfg["xlen"] == 32 else 2) and data[5] == 1,
            f"ELF width/endianness mismatch: {elf}")
    require(struct.unpack_from("<H", data, 18)[0] == 243, f"not RISC-V ELF: {elf}")
    flags = struct.unpack_from("<I", data, 36 if cfg["xlen"] == 32 else 48)[0]
    require(flags & 15 == 0, "ELF requires C, floating-point ABI, or E; expected IM/Zicsr")
    tool_root = os.environ.get("RISCV_TOOL_ROOT")
    require(tool_root, "set RISCV_TOOL_ROOT to the RISC-V toolchain bin directory")
    tool = Path(tool_root) / "riscv64-unknown-elf-"
    nm = subprocess.check_output([str(tool) + "nm", "-n", str(elf)], text=True)
    symbols = {}
    for line in nm.splitlines():
        fields = line.split()
        if len(fields) == 3 and fields[2] in ("tohost", "sim_console"):
            require(fields[2] not in symbols, f"duplicate host symbol: {fields[2]}")
            symbols[fields[2]] = int(fields[0], 16)
    require(set(symbols) == {"tohost", "sim_console"}, f"missing host symbols: {elf}")
    attributes = subprocess.check_output([str(tool) + "readelf", "-A", str(elf)], text=True)
    arch = re.search(r'Tag_RISCV_arch:\s*"([^"]+)"', attributes)
    require(arch is not None, "ELF missing RISC-V ISA attributes")
    require(re.fullmatch(rf"rv{cfg['xlen']}i\d+p\d+_m\d+p\d+_zicsr\d+p\d+(?:_zmmul\d+p\d+)?",
                         arch[1]), f"unsupported frozen ISA: {arch[1]}")
    base, end = (0x01100000, 0x01110000) if cfg["soc"] else (0, 131072)
    require(all(base <= addr < end for addr in symbols.values()), "host symbols mismatch selected layout")
    return {"symbols": symbols, "elf_arch": arch[1]}


def checkout_info():
    def git(*args):
        result = subprocess.run(["git", *args], text=True, capture_output=True, check=False)
        return result.stdout.strip() if result.returncode == 0 else "unavailable"
    diff = git("diff", "HEAD", "--", "vsrc", "tb", "scripts")
    names = git("ls-files", "--cached", "--others", "--exclude-standard", "--", "vsrc", "tb", "scripts")
    sources = {name: digest(Path(name)) for name in sorted(set(names.splitlines())) if Path(name).is_file()}
    return {"revision": git("rev-parse", "HEAD"), "status": git("status", "--short"),
            "tracked_diff_sha256": hashlib.sha256(diff.encode()).hexdigest(),
            "source_files_sha256": sources}


def freeze(args):
    cfg = configuration(args.xlen)
    runtime_name, rtl_parameters = runtime_configuration(cfg)
    source = args.source.resolve()
    target = args.destination.absolute()
    require(source.is_dir(), "source image directory does not exist")
    require(not target.exists() and not target.is_symlink(), "destination already exists; refusing overwrite")
    records = {}
    inputs = {}
    for mode in MODES:
        mode_dir = source / mode
        log = args.log_dir / f"coremark-{mode}-rv{args.xlen}-{runtime_name}.log"
        fields = result_fields(log, mode, args.xlen)
        require(fields["harness_cycles"] < args.max_cycles, "timeout does not exceed complete harness run")
        records[mode] = {**fields, **elf_metadata(mode_dir / "program.elf", cfg),
                         "max_cycles": args.max_cycles, "files": {}}
        inputs[mode] = {name: mode_dir / name for name in IMAGE_FILES}
        inputs[mode]["baseline.log"] = log
        for name, path in inputs[mode].items():
            require(path.is_file(), f"missing snapshot input: {path}")
            records[mode]["files"][name] = digest(path)
    require(records["performance"]["iterations"] == records["validation"]["iterations"],
            "performance/validation iteration counts differ")
    manifest = {"schema": 1, "config": cfg, "source_revision": args.source_revision,
                "freeze_checkout": checkout_info(), "freeze_rtl_parameters": rtl_parameters,
                "source_directory": str(source), "modes": records}
    # 先验证全部输入，再以独占 mkdir 建立快照。已有目录或并发冻结不能被覆盖。
    target.mkdir(parents=False, exist_ok=False)
    for mode in MODES:
        (target / mode).mkdir()
        for name, path in inputs[mode].items():
            shutil.copyfile(path, target / mode / name)
            require(digest(target / mode / name) == records[mode]["files"][name],
                    f"snapshot input changed during copy: {path}")
    with (target / "manifest.json").open("x") as output:
        json.dump(manifest, output, indent=2, sort_keys=True)
        output.write("\n")
    print(f"PASS CoreMark freeze: {target} manifest_sha256={digest(target / 'manifest.json')}")


def validate_snapshot(root, cfg):
    manifest = json.loads((root / "manifest.json").read_text())
    require(manifest.get("schema") == 1 and manifest.get("config") == cfg,
            "snapshot schema/config mismatch (XLEN, MDU, SoC, DDR, cache, ISA or layout)")
    require(set(manifest["modes"]) == set(MODES), "snapshot must contain both modes")
    for mode in MODES:
        record = manifest["modes"][mode]
        require(type(record["iterations"]) is int and positive(record["iterations"]), "invalid iterations")
        require(type(record["max_cycles"]) is int and positive(record["max_cycles"]), "invalid timeout")
        require(set(record["files"]) == {*IMAGE_FILES, "baseline.log"}, "invalid snapshot file set")
        for name, expected in record["files"].items():
            path = root / mode / name
            require(path.is_file() and not path.is_symlink(), f"missing/non-regular snapshot file: {path}")
            require(re.fullmatch(r"[0-9a-f]{64}", expected) and digest(path) == expected,
                    f"snapshot SHA-256 mismatch: {path}")
        baseline = result_fields(root / mode / "baseline.log", mode, cfg["xlen"])
        require(all(record[key] == baseline[key] for key in baseline), "manifest/log metadata mismatch")
        require(set(record["symbols"]) == {"tohost", "sim_console"}, "invalid host symbol set")
        base, end = (0x01100000, 0x01110000) if cfg["soc"] else (0, 131072)
        require(all(type(addr) is int and base <= addr < end for addr in record["symbols"].values()),
                "invalid host addresses")
    require(manifest["modes"]["performance"]["iterations"] == manifest["modes"]["validation"]["iterations"],
            "snapshot iteration counts differ")
    return manifest


def replay(args):
    cfg = configuration(args.xlen)
    runtime_name, rtl_parameters = runtime_configuration(cfg)
    root = args.snapshot.resolve()
    manifest = validate_snapshot(root, cfg)
    iterations = manifest["modes"]["performance"]["iterations"]
    override = os.environ.get("COREMARK_ITERATIONS")
    require(override is None or positive(override) == iterations, "COREMARK_ITERATIONS differs from frozen image")
    allow_short = os.environ.get("COREMARK_REPLAY_ALLOW_SHORT", "0")
    require(allow_short in ("0", "1"), "COREMARK_REPLAY_ALLOW_SHORT must be 0 or 1")
    soc_metrics = os.environ.get("COREMARK_REPLAY_SOC_METRICS", "0")
    require(soc_metrics in ("0", "1"), "COREMARK_REPLAY_SOC_METRICS must be 0 or 1")
    require(soc_metrics == "0" or (cfg["soc"] and rtl_parameters["core_backend"] == "scoreboard"),
            "SoC memory observation requires the scoreboard SoC harness")
    observation_args = ["+P2_METRICS", "+P2_EXPECT_M1"] if soc_metrics == "1" else []
    snapshot_hash = digest(root / "manifest.json")
    sim_override = os.environ.get("COREMARK_REPLAY_SIM")
    if sim_override:
        simulator = Path(sim_override).resolve()
        sim_source = os.environ.get("COREMARK_REPLAY_SIM_SOURCE")
        require(bool(sim_source), "explicit simulator requires COREMARK_REPLAY_SIM_SOURCE")
    else:
        subprocess.run(["bash", "scripts/verilator/build_benchmark_sim.sh", str(args.xlen)], check=True)
        top = ("tb_soc_system" if os.environ.get("CORE_BACKEND") == "scoreboard" else "tb_soc_benchmark") if cfg["soc"] else "tb_benchmark"
        simulator = Path(f"build/verilator/benchmark-rv{args.xlen}-{runtime_name}/V{top}").resolve()
        sim_source = "built from current checkout"
    require(simulator.is_file() and os.access(simulator, os.X_OK), "simulator not executable")
    Path("logs").mkdir(exist_ok=True)
    log_dir = Path(tempfile.mkdtemp(prefix=f"coremark-replay-rv{args.xlen}-{runtime_name}-", dir="logs"))
    # RTL 路由参数用于结果溯源，不加入冻结软件的强相等条件，同一 ELF 才能比较两条路径。
    report = {"config": cfg, "rtl_parameters": rtl_parameters,
              "snapshot": str(root), "manifest_sha256": snapshot_hash,
              "source_revision": manifest["source_revision"], "rtl_checkout": checkout_info(),
              "simulator": str(simulator), "simulator_sha256": digest(simulator),
              "simulator_source": sim_source, "allow_short_duration": allow_short == "1",
              "soc_memory_observation": soc_metrics == "1",
              "timing_source": "cpu-cycle (port uses virtual 1000000 ticks/sec)", "modes": {}}
    (log_dir / "manifest.json").write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
    (log_dir / "provenance.json").write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
    print(f"INFO CoreMark replay: snapshot={root} logs={log_dir} simulator={simulator} source={sim_source}", flush=True)
    # 验证/运行都不执行 gcc、objcopy、镜像转换或自适应迭代校准。
    for mode in MODES:
        record = manifest["modes"][mode]
        require(digest(root / "manifest.json") == snapshot_hash, "manifest changed during replay")
        validate_snapshot(root, cfg)
        run_log = log_dir / f"{mode}.log"
        command = [str(simulator), f"+IMEM={root / mode / 'imem.hex'}",
                   f"+DMEM={root / mode / 'dmem.hex'}", f"+TOHOST={record['symbols']['tohost']:x}",
                   f"+CONSOLE={record['symbols']['sim_console']:x}", f"+TEST=coremark-{mode}",
                   f"+MAX_CYCLES={record['max_cycles']}", *observation_args]
        with run_log.open("x") as output:
            subprocess.run(command, stdout=output, stderr=subprocess.STDOUT, check=True)
        observed = result_fields(run_log, mode, args.xlen, allow_short=allow_short == "1")
        for key in ("iterations", "crc", "compiler_version", "compiler_flags"):
            require(observed[key] == record[key], f"replay {mode} {key} differs from frozen baseline; see {run_log}")
        report["modes"][mode] = {**observed, "log": str(run_log), "command": command,
                                  "core_statistics_counter_offset": -1 if "simulation_clocks" in observed else 1,
                                  "cycles_per_iteration": observed["ticks"] / iterations,
                                  "coremark_per_mhz": iterations * 1000000 / observed["ticks"]}
        print(f"PASS CoreMark replay {mode} RV{args.xlen}: iterations={iterations} ticks={observed['ticks']}")
        if not observed["duration_valid"]:
            print(f"SKIP CoreMark {mode} official-duration: fixed-image CRC/cycle comparison only, below 10 virtual seconds")
    require(digest(root / "manifest.json") == snapshot_hash, "manifest changed during replay")
    validate_snapshot(root, cfg)
    require(digest(simulator) == report["simulator_sha256"], "simulator changed during replay")
    (log_dir / "result.json").write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
    score = report["modes"]["performance"]["coremark_per_mhz"]
    print(f"PASS CoreMark fixed-image replay RV{args.xlen}: CoreMark/MHz={score:.6f} report={log_dir / 'result.json'}")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest="command", required=True)
    freeze_parser = commands.add_parser("freeze", help="copy validated images to a new, immutable-by-contract directory")
    freeze_parser.add_argument("source", type=Path)
    freeze_parser.add_argument("destination", type=Path)
    freeze_parser.add_argument("--log-dir", type=Path, default=Path("logs"))
    freeze_parser.add_argument("--max-cycles", type=positive, required=True)
    freeze_parser.add_argument("--source-revision", default="unverified historical artifacts")
    replay_parser = commands.add_parser("replay", help="validate frozen bytes and run both modes without software build")
    replay_parser.add_argument("snapshot", type=Path)
    for command in (freeze_parser, replay_parser):
        command.add_argument("--xlen", type=int, choices=(32, 64), required=True)
    args = parser.parse_args()
    try:
        (freeze if args.command == "freeze" else replay)(args)
    except (ValueError, OSError, KeyError, TypeError, subprocess.SubprocessError) as error:
        print(f"FAIL CoreMark snapshot: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
