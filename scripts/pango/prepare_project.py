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
import struct
from fractions import Fraction
import xml.etree.ElementTree as ET


GENERATED_SCRIPTS = ("compile.tcl", "synthesize.tcl", "implement.tcl")
CDC_IMPLEMENTATION_SCRIPTS = ("implement_cdc.tcl",)
MEMORY_SCRIPTS = ("memory_guard.ps1", "memory_gate.ps1")
SYNTHESIZE_COMMANDS = "source compile.tcl\nsynthesize -ads -selected_syn_tool_opt 2\n"
TIMING_V3_SYNTHESIS = ("synthesize -ads -selected_syn_tool_opt 2 -resource_sharing false "
                       "-fanout_guide 128 -retiming -max_path 100 -nworst 3 "
                       "-report_logic_level_distribution -report_exception TRUE")
COREMARK_INPUTS = tuple("""
software/coremark-board/startup.S software/coremark-board/main.c
software/coremark-board/platform.c software/coremark-board/port.c
software/common/baremetal/runtime.c software/common/baremetal/softarith.c
benchmark/coremark/port/ee_printf.c benchmark/coremark/vendor/coremark/core_main.c
benchmark/coremark/vendor/coremark/core_list_join.c benchmark/coremark/vendor/coremark/core_matrix.c
benchmark/coremark/vendor/coremark/core_state.c benchmark/coremark/vendor/coremark/core_util.c
software/coremark-board/board.h software/common/soc_clocks.h software/common/soc_capabilities.h
software/common/baremetal/benchmark_runtime.h software/common/baremetal/link_soc.ld
benchmark/coremark/port/core_portme.h benchmark/coremark/vendor/coremark/coremark.h
scripts/coremark/build_board.sh
""".split())


def synthesis_commands(strategy="standard"):
    if strategy == "standard":
        return SYNTHESIZE_COMMANDS
    if strategy not in ("timing-v2", "timing-v3"):
        raise ValueError("unsupported synthesis strategy")
    synthesis = TIMING_V3_SYNTHESIS.replace('-fanout_guide 128', '-fanout_guide 64') if strategy == 'timing-v2' else TIMING_V3_SYNTHESIS
    return ('set hgb_root [file dirname [info script]]\n'
            'puts [exec powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass '
            '-File [file join $hgb_root memory_gate.ps1] -LogDirectory [file join $hgb_root memory] -Phase synthesis]\n'
            'set_option max_threads 8\nsource [file join $hgb_root compile.tcl]\n' +
            synthesis + '\nputs "HGB_SYNTHESIS_DONE"\n')


def implementation_commands(template, strategy="standard"):
    """Only newly staged timing-v2 projects use the measured 64/80 policy."""
    if strategy == 'timing-v2':
        if template.count('-slack_weight 90') != 1:
            raise ValueError('timing-v2 requires the reviewed normal/90 implementation template')
        return template.replace('-slack_weight 90', '-slack_weight 80')
    if strategy not in ('standard', 'timing-v3'):
        raise ValueError('unsupported implementation strategy')
    return template


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def inspect_firmware(directory, xlen, role="loader", source_root=None):
    """Validate actual initialized TCM bytes; interactive images keep program.elf."""
    directory = Path(directory)
    if role not in ("loader", "coremark-interactive"):
        raise ValueError("unsupported firmware role")
    elf_name = "program.elf" if role == "coremark-interactive" else "loader.elf"
    elf = (directory / elf_name).read_bytes()
    if (len(elf) < (52 if xlen == 32 else 64) or elf[:4] != b"\x7fELF" or
            elf[4:6] != bytes((1 if xlen == 32 else 2, 1)) or elf[18:20] != b"\xf3\x00"):
        raise ValueError("loader ELF width mismatch" if role == "loader" else
                         "firmware ELF width/machine/endianness mismatch")
    raw = {}
    for name in ("imem.hex", "dmem.hex"):
        words = (directory / name).read_text().split()
        if len(words) != 65536 // (xlen // 8) or any(len(w) != xlen // 4 for w in words):
            raise ValueError("invalid production TCM HEX: " + name)
        raw[name] = b"".join(int(w, 16).to_bytes(xlen // 8, "little") for w in words)
    identity = dict(role=role, elf=elf_name,
                    image_sha256={n: sha(directory / n) for n in (elf_name, "imem.hex", "dmem.hex")})
    if role == "loader":
        return identity
    receipt = json.loads((directory / "manifest.json").read_text())
    config = receipt["config"]
    if (config.get("xlen") != xlen or config.get("memory") != "tcm" or
            config.get("test_iterations") != 0 or config.get("optimization") not in ("O2", "O3", "Ofast") or
            type(config.get("baud")) is not int or config["baud"] <= 0 or
            config.get("formal_minimum_seconds", 0) < 10 or config.get("target_seconds", 0) < 10):
        raise ValueError("production interactive firmware requires matching XLEN, TCM and test_iterations=0")
    sources = receipt["source_sha256"]
    if set(sources) != set(COREMARK_INPUTS):
        raise ValueError("interactive firmware requires its complete 20-source build receipt")
    if source_root is None:
        raise ValueError("interactive firmware source snapshot is required")
    source_root = Path(source_root).resolve()
    for name, digest in sources.items():
        path = (source_root / name).resolve()
        path.relative_to(source_root)
        if sha(path) != digest:
            raise ValueError("firmware source hash differs: " + name)
    build_id = hashlib.sha256(json.dumps(dict(config=config, sources=sources), sort_keys=True).encode()).hexdigest()[:16]
    if receipt.get("firmware_id") != build_id or receipt.get("image_sha256") != identity["image_sha256"]:
        raise ValueError("interactive firmware build/image identity mismatch")
    if xlen == 32:
        entry, phoff, shoff, flags = struct.unpack_from("<4I", elf, 24)
        phsize, phcount, shsize, shcount, names_index = struct.unpack_from("<5H", elf, 42)
    else:
        entry, phoff, shoff = struct.unpack_from("<3Q", elf, 24)
        flags = struct.unpack_from("<I", elf, 48)[0]
        phsize, phcount, shsize, shcount, names_index = struct.unpack_from("<5H", elf, 54)
    if entry != 0x01000000 or flags != 0:
        raise ValueError("interactive ELF entry/ISA ABI flags differ from supported initialized TCM")
    segments = []
    for index in range(phcount):
        values = struct.unpack_from("<8I" if xlen == 32 else "<2I6Q", elf, phoff + index * phsize)
        if xlen == 32:
            kind, offset, address, physical, filesz, memsz, permissions, _ = values
        else:
            kind, permissions, offset, address, physical, filesz, memsz, _ = values
        if kind != 1:
            continue
        region = next(((name, base) for name, base in (("imem.hex", 0x01000000), ("dmem.hex", 0x01100000))
                       if base <= address < base + 65536), None)
        if (region is None or address != physical or filesz > memsz or offset + filesz > len(elf) or
                address + memsz > region[1] + 65536):
            raise ValueError("interactive ELF LOAD segment outside TCM")
        name, base = region
        if raw[name][address-base:address-base+filesz] != elf[offset:offset+filesz]:
            raise ValueError("interactive ELF/HEX bytes differ: " + name)
        segments.append(dict(address=address, file_bytes=filesz, memory_bytes=memsz,
                             flags=permissions, region=name))
    if {s["region"] for s in segments} != {"imem.hex", "dmem.hex"}:
        raise ValueError("interactive ELF must initialize both TCM regions")
    def section(index):
        values = struct.unpack_from("<10I" if xlen == 32 else "<2I4Q2I2Q", elf, shoff + index * shsize)
        return values[0], values[4], values[5]
    _, names_offset, names_size = section(names_index)
    names = elf[names_offset:names_offset+names_size]
    attributes = []
    for index in range(shcount):
        name, offset, size = section(index)
        if names[name:].split(b"\0", 1)[0] == b".riscv.attributes":
            attributes += re.findall(rb"rv(?:32|64)i[0-9]+p[0-9]+(?:_[a-z0-9]+)*", elf[offset:offset+size])
    if len(attributes) != 1:
        raise ValueError("interactive ELF is missing unambiguous RISC-V ISA attributes")
    arch = attributes[0].decode()
    tokens = arch.split("_")
    if not tokens[0].startswith("rv" + str(xlen) + "i") or any(
            not re.fullmatch(r"(?:m|zicsr|zifencei|zmmul)[0-9]+p[0-9]+", token) for token in tokens[1:]):
        raise ValueError("interactive ELF requires unsupported ISA extensions: " + arch)
    if build_id.encode() not in raw["dmem.hex"]:
        raise ValueError("interactive firmware ID is absent from initialized DTCM")
    return dict(identity, firmware_id=build_id, build_config=config, source_sha256=sources,
                build_commit=receipt.get("source_commit"), build_source_status=receipt.get("source_status"),
                build_manifest_sha256=sha(directory / "manifest.json"),
                entry=entry, elf_arch=arch, elf_flags=flags, load_segments=segments,
                boot="reset ROM0 trampoline -> initialized ITCM0x01000000", clocks="runtime discovery")
SCOREBOARD_CONFIGURATION = {
    "core_backend": "scoreboard", "core_issue_width": 2, "core_retire_entries": 16,
    "core_issue_queue_entries": 8, "core_load_queue_entries": 4,
    "core_store_queue_entries": 4, "core_branch_checkpoints": 4,
    "core_predictor_mode": 0, "core_ras_enable": 0,
    "fetch_data_bits": 64, "data_ports": 2, "tcm_banks_per_region": 2,
    "dcache_banks": 2, "dcache_bytes": 4096, "icache_bytes": 4096,
}

# P1 已合入配置；P0 常量继续服务历史 schema，不覆盖旧工程的参数证据。
P1_SCOREBOARD_CONFIGURATION = dict(
    SCOREBOARD_CONFIGURATION, core_retire_entries=32, core_split_issue_queue=1,
    core_memory_queue_entries=4, core_limited_integer_ooo=1,
    core_scheduler_forward_mode=3, core_predictor_mode=1, core_ras_enable=1)
# 保留旧 P1 参数用于核验历史工程；当前正式配置裁掉 RAS，并按同一固定镜像
# 比较关闭有限整数乱序（H0 81.7327 MHz、M0 3.150157，见 OPTIMIZATION_PLAN B25）。
DEFAULT_SCOREBOARD_CONFIGURATION = dict(P1_SCOREBOARD_CONFIGURATION,
                                        core_ras_enable=0, core_limited_integer_ooo=0,
                                        core_retire_entries=16)
BOARD_CLOCK_DOMAINS = dict.fromkeys(("core", "sys", "ddr", "periph"), 125000000)
# C1/C4 的时钟来自 800 MHz VCO 的 GPLL；C5 改用 900 MHz VCO 以整数分频得到
# 90/100/25 MHz 与 100 MHz NPU（YOLO 性能策略综合估计 92.9282/113.9212/114.8633 MHz
# 向下取 5 的倍数）。DDR 用户钟仍由 DDR IP 的 125 MHz 输出提供，不随该表变化。
BOARD_CLOCK_PROFILES = {
    0: {"name": "common", "core": 125000000, "sys": 125000000,
        "ddr": 125000000, "periph": 125000000},
    1: {"name": "C1", "core": 100000000, "sys": 80000000,
        "ddr": 125000000, "periph": 25000000},
    4: {"name": "C4", "core": 100000000, "sys": 100000000,
        "ddr": 125000000, "periph": 25000000},
    5: {"name": "C5", "core": 90000000, "sys": 100000000,
        "ddr": 125000000, "periph": 25000000},
    6: {"name": "C6", "core": 100000000, "sys": 100000000,
        "ddr": 125000000, "periph": 60000000},
    7: {"name": "C7", "core": 90000000, "sys": 100000000,
        "ddr": 125000000, "periph": 60000000},
    8: {"name": "C8", "core": 81818182, "sys": 100000000,
        "ddr": 125000000, "periph": 60000000},
    9: {"name": "C9", "core": 88750000, "sys": 98611111,
        "ddr": 125000000, "periph": 68269231},
    10: {"name": "C10", "core": 83806818, "sys": 102430556,
         "ddr": 125000000, "periph": 65848214},
}
# 相对 125 MHz ref_clk 的 GTP_GPLL 输出比；与 pango_soc_pll 的 STATIC_RATIO* 对齐。
# C5 的 GPLL 分频是 900/10、900/9、900/36，折算到 ref_clk 即 18/25、4/5、1/5。
BOARD_CLOCK_RATIOS = {
    1: {"core": (4, 5), "sys": (16, 25), "periph": (1, 5)},
    4: {"core": (4, 5), "sys": (4, 5), "periph": (1, 5)},
    5: {"core": (18, 25), "sys": (4, 5), "periph": (1, 5)},
    6: {"core": (4, 5), "sys": (4, 5), "periph": (12, 25)},
    7: {"core": (18, 25), "sys": (4, 5), "periph": (12, 25)},
    8: {"core": (36, 55), "sys": (4, 5), "periph": (12, 25)},
    9: {"core": (71, 100), "sys": (71, 90), "periph": (71, 130), "npu": (71, 90)},
    10: {"core": (59, 88), "sys": (59, 72), "periph": (59, 112), "npu": (59, 80)},
}
BOARD_PLL_PARAMETERS = {
    9: dict(reference_hz=125000000, input_div=10, multiply=1, feedback_div=71,
            output_div=dict(core=10, sys=9, periph=13, npu=9)),
    10: dict(reference_hz=125000000, input_div=8, multiply=1, feedback_div=59,
             output_div=dict(core=11, sys=9, periph=14, npu=10)),
}


def board_clock_hz(profile, domain):
    if domain == 'ddr':
        return 125000000
    ratio = BOARD_CLOCK_RATIOS[profile].get(domain, (4, 5))
    return round(Fraction(125000000 * ratio[0], ratio[1]))


def board_clock_periods(profile, clocks):
    # 旧档继续按历史整数Hz生成；C9/C10直接由PLL比率生成分数周期。
    if profile < 9:
        return {domain: 10**12 / hz for domain, hz in clocks.items()}
    result = {}
    for domain in clocks:
        multiply, divide = (1, 1) if domain == 'ddr' else BOARD_CLOCK_RATIOS[profile][domain]
        result[domain] = float(Fraction(8000 * divide, multiply))
    return result


def board_clock_relationship(profile):
    vco = 887.5 if profile == 9 else (921.875 if profile == 10 else (900 if profile >= 5 else 800))
    return f'independent_gpll_{vco}mhz_vco'


def verify_default_board_clocks(wrapper):
    """Schema 8 still stages profile 0; new domain profiles need their own physical constraints."""
    wrapper = re.sub(r"//[^\n]*|/\*.*?\*/", "", wrapper, flags=re.S)
    match = re.search(r"`ifdef\s+CORE_SCOREBOARD\b(.*?)`else", wrapper, re.S)
    if match is None:
        raise ValueError("missing scoreboard wrapper")
    branch = match[1]
    independent = "BOARD_CLOCK_PROFILE" in wrapper
    mapping = dict(core="hot_clk", sys="sys_clk", ddr="core_clk", periph="periph_clk")
    if independent:
        if not re.search(r"parameter\s+int\s+unsigned\s+BOARD_CLOCK_PROFILE\s*=\s*0\s*,", wrapper):
            raise ValueError("staged wrapper must default to BOARD_CLOCK_PROFILE 0")
        common = re.search(r"if\s*\(BOARD_CLOCK_PROFILE\s*==\s*0\)\s*begin\s*:\s*g_common_clock(.*?)end\s+else", wrapper, re.S)
        if common is None:
            raise ValueError("missing wrapper common-clock branch")
        for net in ("hot_clk", "sys_clk", "periph_clk"):
            if not re.search(rf"assign\s+{net}\s*=\s*core_clk\s*;", common[1]):
                raise ValueError(f"wrapper profile 0 changed {net}")
        for name in ("HOT_HZ", "SYS_HZ", "PERIPH_HZ"):
            if not re.search(rf"{name}\s*=\s*BOARD_CLOCK_PROFILE\s*==\s*0\s*\?\s*125000000\s*:", wrapper):
                raise ValueError(f"wrapper profile 0 changed {name}")
    else:
        mapping = dict.fromkeys(BOARD_CLOCK_DOMAINS, "core_clk")
    for domain, net in mapping.items():
        if not re.search(rf"\.clk_{domain}\s*\(\s*{net}\s*\)", branch):
            raise ValueError(f"wrapper board clk_{domain} wiring changed")
    if not re.search(r"\.CLOCK_HZ\s*\(\s*125000000\s*\)", branch):
        raise ValueError("soc_system wrapper CLOCK_HZ does not match 125 MHz")


def verify_independent_board_clocks(wrapper, profile):
    """默认仍为 profile 0，独立应用档由 compile 参数覆盖。"""
    if profile not in BOARD_CLOCK_RATIOS:
        raise ValueError("unsupported independent board clock profile")
    text = re.sub(r"//[^\n]*|/\*.*?\*/", "", wrapper, flags=re.S)
    if not re.search(r"parameter\s+int\s+unsigned\s+BOARD_CLOCK_PROFILE\s*=\s*0\s*,", text):
        raise ValueError("staged wrapper must default to BOARD_CLOCK_PROFILE 0")
    branch = re.search(r"`ifdef\s+CORE_SCOREBOARD\b(.*?)`else", text, re.S)
    if branch is None:
        raise ValueError("missing scoreboard wrapper")
    body = branch[1]
    for domain, net in (("core", "hot_clk"), ("sys", "sys_clk"),
                        ("ddr", "core_clk"), ("periph", "periph_clk")):
        if not re.search(rf"\.clk_{domain}\s*\(\s*{net}\s*\)", body):
            raise ValueError(f"wrapper board clk_{domain} wiring changed")
    if not re.search(r"pango_soc_pll\s*#\(\.CLOCK_PROFILE\(BOARD_CLOCK_PROFILE\)(?:,\s*\.NPU_ENABLE\(NPU_ENABLE(?:\s*\|\|\s*MM3_ENABLE)?\))?\)\s+u_soc_pll", text):
        raise ValueError("missing independent GPLL instance")
    if not re.search(r"pango_soc_reset\s+u_reset", text):
        raise ValueError("missing independent boot reset supervisor")
    if not re.search(r"CLOCK_INFO_ENABLE\(BOARD_CLOCK_PROFILE\s*!=\s*0\)", body):
        raise ValueError("clock discovery is not enabled for independent profiles")
    # 兼容历史工程的旧公式；新档必须有对应的全部频率分支，避免只改元数据。
    compact = re.sub(r"\s+", "", text)
    formulas = {
        "HOT_HZ": ("(BOARD_CLOCK_PROFILE==5?90000000:100000000)",
                   "(BOARD_CLOCK_PROFILE==8?81818182:((BOARD_CLOCK_PROFILE==5||BOARD_CLOCK_PROFILE==7)?90000000:100000000))"),
        "SYS_HZ": ("(BOARD_CLOCK_PROFILE==5?100000000:(BOARD_CLOCK_PROFILE==4?100000000:80000000))",
                   "(BOARD_CLOCK_PROFILE>=4?100000000:80000000)"),
        "PERIPH_HZ": ("25000000", "(BOARD_CLOCK_PROFILE>=6?60000000:25000000)"),
    }
    formulas['HOT_HZ'] += ('(BOARD_CLOCK_PROFILE==9?88750000:(BOARD_CLOCK_PROFILE==10?83806818:'
                           '(BOARD_CLOCK_PROFILE==8?81818182:((BOARD_CLOCK_PROFILE==5||BOARD_CLOCK_PROFILE==7)?90000000:100000000))))',)
    formulas['SYS_HZ'] += ('(BOARD_CLOCK_PROFILE==9?98611111:(BOARD_CLOCK_PROFILE==10?102430556:'
                           '(BOARD_CLOCK_PROFILE>=4?100000000:80000000)))',)
    formulas['PERIPH_HZ'] += ('(BOARD_CLOCK_PROFILE==9?68269231:(BOARD_CLOCK_PROFILE==10?65848214:'
                              '(BOARD_CLOCK_PROFILE>=6?60000000:25000000)))',)
    for name, choices in formulas.items():
        allowed = choices[-1:] if profile >= 9 else (choices[1:] if profile >= 6 else choices)
        if not any(f"{name}=BOARD_CLOCK_PROFILE==0?125000000:{formula};" in compact for formula in allowed):
            raise ValueError(f"unexpected {name} profile formula")


def board_clock_constraints(profile, npu_enable=False):
    """生成精确分数 generated clock 与时钟不确定性，不加载 CDC 例外。"""
    if profile not in BOARD_CLOCK_RATIOS:
        raise ValueError("unsupported board clock constraints profile")
    lines = [
        "# Board clocks from the 125 MHz ref_clk through GTP_GPLL.",
        "# board_ddr.fdc defines ref_clk; PLL/DDR site coexistence is left to PDS placement.",
        "# All cross-domain paths remain timed; no clock group, false path or max_delay is loaded.",
    ]
    for domain, pin, clock in (("core", "CLKOUT0", "clk_core"),
                               ("sys", "CLKOUT1", "clk_sys"),
                               ("periph", "CLKOUT2", "clk_periph"),
                               *(([("npu", "CLKOUT3", "clk_npu")]) if npu_enable else [])):
        multiply, divide = BOARD_CLOCK_RATIOS[profile].get(domain, (4, 5))
        lines.append(
            f"create_generated_clock -name {{{clock}}} -source [get_ports {{ref_clk_p}}] "
            f"[get_pins {{g_domain_clocks.u_soc_pll.u_pll/{pin}}}] "
            f"-master_clock [get_clocks {{ref_clk}}] "
            f"-multiply_by {{{multiply}}} -divide_by {{{divide}}}")
        lines.append(f"set_clock_uncertainty -setup 0.2 [get_clocks {{{clock}}}]")
        lines.append(f"set_clock_uncertainty -hold 0.05 [get_clocks {{{clock}}}]")
    lines += [
        "# I/O delay constraints remain an explicit board gap; DDR pins stay in board_ddr.fdc.",
        "# CDC FIFO exceptions require a native binding audit before they may be loaded.",
    ]
    return "\n".join(lines) + "\n"


def verify_npu_board_clocks(root):
    """Bind the optional domain to its actual GPLL output and NPU wrapper."""
    wrapper = (root / 'vsrc/cpu/pango_200hp_top.sv').read_text()
    pll = (root / 'vsrc/cpu/pango_soc_pll.sv').read_text()
    checks = ((wrapper, r'\.NPU_ENABLE\(NPU_ENABLE(?:\s*\|\|\s*MM3_ENABLE)?\)'),
              (wrapper, r'\.clk_npu\(npu_clk\)'),
              (wrapper, r'\.NPU_BYTES\((?:NPU_ENABLE|\(NPU_ENABLE\s*\|\|\s*MM3_ENABLE\))\s*\?\s*65536\s*:\s*0\)'),
              (pll, r'\.STATIC_RATIO3\(NPU_DIV\)'),
              (pll, r'HIGH_VCO\s*=\s*CLOCK_PROFILE\s*>=\s*5'),
              (pll, r'NPU_DIV\s*=\s*(?:CLOCK_PROFILE\s*==\s*10\s*\?\s*10\s*:\s*\()?HIGH_VCO\s*\?\s*9\s*:\s*8'),
              (pll, r'\.CLKOUT3\(pll_npu\)'),
              (pll, r'if\s*\(NPU_ENABLE\).*?\.CLKIN\(pll_npu\),\s*\.CLKOUT\(clk_npu\)'))
    if any(not re.search(pattern, text, re.S) for text, pattern in checks):
        raise ValueError('NPU clock or target wiring differs from the paired PLL profile')


def staged_soc_system(root, manifest):
    """Identify the hashed scoreboard wrapper branch, without claiming elaboration."""
    wrapper = "vsrc/cpu/pango_200hp_top.sv"
    system = "vsrc/soc/soc_system.sv"
    if wrapper not in manifest["files"] or system not in manifest["files"]:
        return False
    text = (root / wrapper).read_text(encoding="utf-8")
    branch = re.search(r"`ifdef\s+CORE_SCOREBOARD\b(.*?)`else", text, re.S)
    return bool(branch and re.search(r"\bsoc_system\s*#", branch[1]))


def core_profile(configuration):
    return ("p1" if all(configuration.get(key) == value
                        for key, value in P1_SCOREBOARD_CONFIGURATION.items()) else "custom")


def project_configuration(manifest):
    """Normalize a verified native SoC manifest for the existing timing/CDC readers."""
    if manifest.get("soc_topology") != "soc_system" or manifest.get("schema_version") != 9:
        raise ValueError("native timing/CDC requires independent soc_system clocks")
    profile = manifest["board_clock_profile"]
    clocks = dict(manifest["board_clock_domains_hz"])
    names = {1: "target", 4: "sys100", 5: "yolo", 6: "main60", 7: "yolo60", 8: "yolo60_core81",
             9: "main_margin2", 10: "yolo_sys"}
    keys = dict(CORE_ISSUE_WIDTH="core_issue_width", CORE_RETIRE_ENTRIES="core_retire_entries",
                CORE_SPLIT_ISSUE_QUEUE="core_split_issue_queue", CORE_ISSUE_QUEUE_ENTRIES="core_issue_queue_entries",
                CORE_MEMORY_QUEUE_ENTRIES="core_memory_queue_entries", CORE_LOAD_QUEUE_ENTRIES="core_load_queue_entries",
                CORE_STORE_QUEUE_ENTRIES="core_store_queue_entries", CORE_BRANCH_CHECKPOINTS="core_branch_checkpoints",
                CORE_LIMITED_INTEGER_OOO="core_limited_integer_ooo", CORE_SCHEDULER_FORWARD_MODE="core_scheduler_forward_mode",
                CORE_PREDICTOR_MODE="core_predictor_mode", CORE_RAS_ENABLE="core_ras_enable")
    macros = dict(CORE_SCOREBOARD=1, CORE_XLEN=manifest["xlen"], CORE_MUL_IMPL=0, CORE_DIV_IMPL=1,
                  SOC_ICACHE_FILL_BYTES=4, **{macro: manifest[key] for macro, key in keys.items()})
    mask = manifest.get("dcache_bank_xor_mask", 0)
    if mask:
        macros["SOC_DCACHE_BANK_XOR_MASK"] = mask
    memory = dict(itcm_bytes=65536, dtcm_bytes=65536, icache_bytes=manifest["icache_bytes"],
                  dcache_bytes=manifest["dcache_bytes"], cache_line_bytes=32,
                  ddr_sim_backing_bytes=262144, dcache_bank_xor_mask=mask)
    config = dict(platform="soc_ddr", clock=names[profile], xlen=manifest["xlen"],
                  domains=list(clocks), ddr_bytes=536870912, cache_enable=1,
                  pds_top=manifest["top"], native_board_profile=profile, macros=macros,
                  memory=memory, frequencies_hz=clocks,
                  periods_ps=board_clock_periods(profile, clocks),
                  timing_status="unvalidated_target")
    config["config_sha256"] = hashlib.sha256(json.dumps(config, sort_keys=True).encode()).hexdigest()
    return config


def timing_input(project):
    """Read native interactive or historical benchmark/application identity without relabeling firmware."""
    project = Path(project)
    for name in ("application.json", "benchmark.json", "manifest.json"):
        path = project / name
        if not path.exists():
            continue
        manifest = json.loads(path.read_text())
        if name == "manifest.json":
            verify_staged_manifest(project, manifest)
            if manifest.get("firmware_role") != "coremark-interactive":
                raise ValueError("native timing input requires an explicit interactive firmware role")
            return path, manifest, project_configuration(manifest)
        return path, manifest, manifest["config"]
    raise FileNotFoundError("missing staged input manifest")


def compile_command(xlen, profile_id, local_tcm, dma_wide=1,
                    cache_block=None, dma_block=None, core_issue_width=None, scoreboard=False,
                    scoreboard_config=None, soc_system=False, board_clock_profile=0, npu_enable=False, mm3_enable=False,
                    icache_bytes=4096, dcache_bytes=4096, dcache_bank_xor_mask=0):
    if soc_system and not scoreboard:
        raise ValueError("soc_system requires scoreboard")
    # schema 1--7 保持历史 Tcl；schema 8 的 AXI 系统没有这些 legacy 开关。
    legacy_parameters = ""
    if not soc_system:
        dma_parameter = "" if dma_wide is None else f" DMA_WIDE_ENABLE {dma_wide}"
        block_parameters = ""
        if cache_block is not None:
            block_parameters += f" CACHE_BLOCK_ENABLE {cache_block}"
        if dma_block is not None:
            block_parameters += f" DMA_BLOCK_ENABLE {dma_block}"
        legacy_parameters = f" LOCAL_TCM_ENABLE {local_tcm}{dma_parameter}{block_parameters}"
    issue_directive = "" if core_issue_width is None else f" CORE_ISSUE_WIDTH={core_issue_width}"
    if scoreboard:
        if core_issue_width != 2:
            raise ValueError("scoreboard requires issue width 2")
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
    if dcache_bank_xor_mask:
        if not soc_system or dcache_bank_xor_mask not in (1, 2, 3):
            raise ValueError('bank XOR override requires supported soc_system mapping')
        issue_directive += f" SOC_DCACHE_BANK_XOR_MASK={dcache_bank_xor_mask}"
    # profile 0 不写入 BOARD_CLOCK_PROFILE，保持既有 compile.tcl 逐字节兼容。
    board_directive = "" if board_clock_profile == 0 else f" BOARD_CLOCK_PROFILE {board_clock_profile}"
    if (icache_bytes, dcache_bytes) != (4096, 4096):
        if not soc_system:
            raise ValueError('cache capacity overrides require soc_system')
        board_directive += f" ICACHE_BYTES {icache_bytes} DCACHE_BYTES {dcache_bytes}"
    if npu_enable and mm3_enable:
        raise ValueError("select one accelerator")
    if npu_enable or mm3_enable:
        if not soc_system or not board_clock_profile:
            raise ValueError("NPU requires independent scoreboard SoC clocks")
        board_directive += " MM3_ENABLE 1" if mm3_enable else " NPU_ENABLE 1"
    return ("compile -top_module pango_200hp_top -verilog_standard SystemVerilog "
            f"-compiler_directives {{CORE_XLEN={xlen} CORE_MUL_IMPL=0 CORE_DIV_IMPL=1{issue_directive}}} "
            '-defined_parameters {ITCM_INIT_FILE "firmware/imem.hex" '
            'DTCM_INIT_FILE "firmware/dmem.hex" '
            f'SOC_PROFILE {profile_id}{legacy_parameters}{board_directive}}} -loop_limit 65536')


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
    if type(manifest["schema_version"]) is not int or manifest["schema_version"] not in (1, 2, 3, 4, 5, 6, 7, 8, 9):
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
    if type(manifest.get('dcache_bank_xor_mask', 0)) is not int or manifest.get('dcache_bank_xor_mask', 0) not in (0,1,2,3):
        raise ValueError('invalid staged D-cache bank mapping')
    scoreboard_config = dict(SCOREBOARD_CONFIGURATION)
    if schema in (8, 9):
        for key in ('icache_bytes', 'dcache_bytes'):
            size = manifest.get(key)
            if type(size) is not int or size < 4096 or size > 65536 or size & (size - 1):
                raise ValueError('invalid staged cache capacity: ' + key)
            scoreboard_config[key] = size
        if (manifest['icache_bytes'], manifest['dcache_bytes']) != (4096, 4096):
            wrapper = (root / 'vsrc/cpu/pango_200hp_top.sv').read_text()
            for name in ('ICACHE_BYTES', 'DCACHE_BYTES'):
                if not re.search(rf'parameter\s+int\s+unsigned\s+{name}\s*=', wrapper) or not re.search(rf'\.{name}\({name}\)', wrapper):
                    raise ValueError('cache capacity is not forwarded by the board wrapper: ' + name)
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
    if schema in (8, 9):
        if manifest.get("soc_topology") != "soc_system" or not staged_soc_system(root, manifest):
            raise ValueError(f"schema {schema} requires a hashed soc_system scoreboard wrapper")
        wrapper = (root / "vsrc/cpu/pango_200hp_top.sv").read_text(encoding="utf-8")
        if schema == 8:
            verify_default_board_clocks(wrapper)
            if (manifest.get("board_clock_profile", 0) != 0 or
                    manifest.get("board_clock_domains_hz") != BOARD_CLOCK_DOMAINS or
                    manifest.get("clock_relationship") != "common_ddr_user_clock" or
                    manifest.get("mtime_clock_domain") != "periph"):
                raise ValueError("unexpected soc_system board clock configuration")
        else:
            profile = manifest.get("board_clock_profile")
            if type(profile) is not int or profile not in BOARD_CLOCK_RATIOS:
                raise ValueError("schema 9 requires a C1/C4 board clock profile")
            verify_independent_board_clocks(wrapper, profile)
            expected_domains = {domain: BOARD_CLOCK_PROFILES[profile][domain]
                                for domain in ("core", "sys", "ddr", "periph")}
            if manifest.get("npu_enable") or manifest.get("mm3_enable"):
                verify_npu_board_clocks(root)
                expected_domains["npu"] = board_clock_hz(profile, 'npu')
            if (manifest.get("clock_profile") != BOARD_CLOCK_PROFILES[profile]["name"] or
                    manifest.get("board_clock_domains_hz") != expected_domains or
                    manifest.get("clock_relationship") != board_clock_relationship(profile) or
                    manifest.get("mtime_clock_domain") != "periph"):
                raise ValueError("unexpected independent board clock configuration")
            if "board_clocks.fdc" not in manifest["files"]:
                raise ValueError("independent clock constraints not covered by manifest")
            if (root / "board_clocks.fdc").read_text(encoding="utf-8") != board_clock_constraints(profile, manifest.get("npu_enable", False) or manifest.get("mm3_enable", False)):
                raise ValueError("independent clock constraints differ from staging configuration")
        if manifest.get("local_tcm_enable") != 1:
            raise ValueError("soc_system always uses local TCM")
        if manifest.get("core_profile") != core_profile(scoreboard_config):
            raise ValueError("core profile differs from staged scheduler configuration")
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
    if manifest.get("cdc_implementation_version") == 1:
        for name in CDC_IMPLEMENTATION_SCRIPTS:
            if name not in manifest["files"]:
                raise ValueError(f"CDC implementation entry not covered by manifest: {name}")
    if manifest.get("memory_guard_version") == 1:
        for name in MEMORY_SCRIPTS:
            if name not in manifest["files"]:
                raise ValueError(f"memory guard not covered by manifest: {name}")
    commands = [line.strip() for line in (root / "compile.tcl").read_text(encoding="utf-8").splitlines()
                if line.strip().startswith("compile")]
    expected_compile = compile_command(manifest["xlen"], profile_id, local_tcm,
                                       1 if schema >= 2 else None,
                                       1 if schema >= 3 else None, 1 if schema >= 3 else None,
                                       2 if schema >= 4 else (1 if schema == 3 else None),
                                       scoreboard=schema >= 4,
                                       scoreboard_config=scoreboard_config if schema >= 5 else None,
                                       soc_system=schema in (8, 9),
                                       board_clock_profile=manifest.get("board_clock_profile", 0),
                                       npu_enable=manifest.get("npu_enable", False),
                                       mm3_enable=manifest.get("mm3_enable", False),
                                       icache_bytes=manifest.get('icache_bytes', 4096),
                                       dcache_bytes=manifest.get('dcache_bytes', 4096),
                                       dcache_bank_xor_mask=manifest.get('dcache_bank_xor_mask', 0))
    accepted_commands = [[expected_compile]]
    # P2 在合入 P1 前使用 schema 4。仅其已覆盖哈希的 AXI wrapper 可省略旧参数。
    if schema == 4 and staged_soc_system(root, manifest):
        accepted_commands.append([compile_command(manifest["xlen"], profile_id, local_tcm,
                                                  1, 1, 1, 2, scoreboard=True, soc_system=True)])
    if commands not in accepted_commands:
        raise ValueError("compile Tcl parameters differ from staging manifest")
    if (root / "synthesize.tcl").read_text(encoding="utf-8") != synthesis_commands(manifest.get("synthesis_strategy", "standard")):
        raise ValueError("unexpected generated synthesis commands")
    if manifest.get('synthesis_strategy') == 'timing-v2':
        for name in ('implement.tcl', *CDC_IMPLEMENTATION_SCRIPTS):
            lines = (root / name).read_text().splitlines()
            if (lines.count('place -mode normal -optimize_gp_recovery TRUE -logic_optimize_lut6d FALSE') != 1 or
                    lines.count('route -route_mode normal -slack_weight 80 -optimize_routing_recovery TRUE') != 1 or
                    lines.count('route_optimize') != 1):
                raise ValueError('timing-v2 implementation must preserve normal/LUT-off/80/recovery/route_optimize')
    if manifest.get("firmware_manifest_version") == 1:
        if manifest.get("firmware_role") != "coremark-interactive":
            raise ValueError("unsupported versioned firmware role")
        actual = inspect_firmware(root / "firmware", manifest["xlen"], "coremark-interactive",
                                  root / "firmware/source")
        if actual != manifest.get("firmware") or manifest.get("config") != project_configuration(manifest):
            raise ValueError("interactive firmware or hardware binding differs from staged inputs")
    configuration.update({key: manifest[key] for key in
                          ("soc_profile", "soc_profile_id", "local_tcm_enable",
                           "soc_presence", "slow_presence")})
    configuration["dma_wide_enable"] = 1 if schema >= 2 else "unknown"
    configuration["ddr_data_bits"] = 256 if schema >= 2 else "unknown"
    for key in ("cache_block_enable", "dma_block_enable", "core_issue_width"):
        configuration[key] = manifest[key] if schema >= 3 else "unknown"
    if schema >= 4:
        configuration.update({key: manifest[key] for key in scoreboard_config})
    if schema in (8, 9):
        configuration.update({key: manifest[key] for key in
                              ("soc_topology", "core_profile", "board_clock_domains_hz",
                               "clock_relationship", "mtime_clock_domain")})
    if schema == 9:
        configuration.update({key: manifest[key] for key in
                              ("board_clock_profile", "clock_profile")})
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
    parser.add_argument("--firmware-dir", type=Path, help="existing initialized TCM image directory; never rebuilt")
    parser.add_argument("--firmware-role", choices=("loader", "coremark-interactive"), default="loader")
    parser.add_argument("--synthesis-strategy", choices=("standard", "timing-v2", "timing-v3"), default="standard")
    parser.add_argument('--icache-bytes', type=int, choices=(4096, 8192, 16384, 32768, 65536), default=4096)
    parser.add_argument('--dcache-bank-xor-mask', type=int, choices=(0,1,2,3), default=0)
    parser.add_argument('--dcache-bytes', type=int, choices=(4096, 8192, 16384, 32768, 65536), default=4096)
    parser.add_argument("--soc-profile", choices=("full", "lite"), default="full")
    parser.add_argument("--local-tcm", type=int, choices=(0, 1), default=None,
                        help="legacy switch; soc_system requires 1 (automatic for scoreboard)")
    parser.add_argument("--core-backend", choices=("legacy", "scoreboard"), default="scoreboard",
                        help="default scoreboard selects the measured ROB16 soc_system; explicit overrides are recorded")
    parser.add_argument("--retire-entries", type=int, choices=(16, 32), default=None)
    parser.add_argument("--split-issue-queue", type=int, choices=(0, 1), default=None)
    parser.add_argument("--limited-integer-ooo", type=int, choices=(0, 1), default=None)
    parser.add_argument("--scheduler-forward-mode", type=int, choices=(0, 1, 2, 3), default=None)
    parser.add_argument("--integer-queue-entries", type=int, choices=(2, 4, 8, 16), default=None)
    parser.add_argument("--memory-queue-entries", type=int, choices=(2, 4, 8), default=None)
    parser.add_argument("--predictor-mode", type=int, choices=(0, 1), default=None)
    parser.add_argument("--ras-enable", type=int, choices=(0, 1), default=None)
    parser.add_argument("--board-clock-profile", type=int, choices=tuple(BOARD_CLOCK_PROFILES), default=None,
                        help="0=common; C1-C8 historical; C9=main_margin2, C10=yolo_sys; DDR125 remains IP-owned")
    parser.add_argument("--npu-enable", action="store_true", help="attach pinned 128-MAC NPU on dedicated 100 MHz clock")
    parser.add_argument("--mm3-enable", action="store_true", help="attach MiniMind on dedicated 100 MHz clock")
    args = parser.parse_args()
    if args.npu_enable and args.mm3_enable:
        parser.error("select one accelerator")
    branch_path = Path(__file__).resolve().parents[1] / "branch_profile.json"
    branch = json.loads(branch_path.read_text()) if branch_path.exists() else {"default_accelerator":"none", "accelerators":["yolo","minimind"]}
    if not args.npu_enable and not args.mm3_enable:
        args.npu_enable = branch["default_accelerator"] == "yolo"
        args.mm3_enable = branch["default_accelerator"] == "minimind"
    selected = "yolo" if args.npu_enable else "minimind" if args.mm3_enable else "none"
    if selected != "none" and selected not in branch["accelerators"]:
        parser.error("accelerator source is absent from this branch: " + selected)
    scoreboard = args.core_backend == "scoreboard"
    if not scoreboard and (args.icache_bytes, args.dcache_bytes) != (4096, 4096):
        parser.error('cache capacity overrides require scoreboard soc_system')
    if args.board_clock_profile is None:
        args.board_clock_profile = 1 if scoreboard else 0
    if (args.npu_enable or args.mm3_enable) and (not scoreboard or not args.board_clock_profile):
        parser.error("NPU requires scoreboard C1/C4/C5")
    if args.board_clock_profile and not scoreboard:
        parser.error("C1/C4/C5 board clock profiles require --core-backend scoreboard")
    if args.local_tcm is None:
        args.local_tcm = int(scoreboard)
    if scoreboard and args.local_tcm != 1:
        parser.error("soc_system always uses local TCM; --local-tcm 0 is legacy-only")
    defaults = DEFAULT_SCOREBOARD_CONFIGURATION if scoreboard else dict(
        P1_SCOREBOARD_CONFIGURATION, core_limited_integer_ooo=0, core_scheduler_forward_mode=0)
    for attribute, key in (("retire_entries", "core_retire_entries"),
                           ("split_issue_queue", "core_split_issue_queue"),
                           ("limited_integer_ooo", "core_limited_integer_ooo"),
                           ("scheduler_forward_mode", "core_scheduler_forward_mode"),
                           ("integer_queue_entries", "core_issue_queue_entries"),
                           ("memory_queue_entries", "core_memory_queue_entries"),
                           ("predictor_mode", "core_predictor_mode"), ("ras_enable", "core_ras_enable")):
        if getattr(args, attribute) is None:
            setattr(args, attribute, defaults[key])
    if args.limited_integer_ooo and (args.core_backend != "scoreboard" or not args.split_issue_queue):
        parser.error("limited integer issue requires scoreboard and split queues")
    if args.scheduler_forward_mode and args.core_backend != "scoreboard":
        parser.error("scheduler forward mode requires scoreboard")
    if args.firmware_role == "coremark-interactive" and (
            args.firmware_dir is None or not scoreboard or not args.board_clock_profile or args.npu_enable or args.mm3_enable):
        parser.error("interactive firmware requires --firmware-dir and an independent no-NPU scoreboard SoC")
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
    firmware = args.firmware_dir.resolve() if args.firmware_dir else repo / f"build/loader/rv{args.xlen}"
    try:
        firmware_identity = inspect_firmware(firmware, args.xlen, args.firmware_role, repo)
    except FileNotFoundError as error:
        parser.error("missing generated IP or production loader; generate IP and make loader first"
                     if args.firmware_role == "loader" else str(error))
    except (OSError, ValueError, KeyError, TypeError, struct.error) as error:
        parser.error(str(error))
    staged = [(source, source.relative_to(repo)) for source in sources(repo, "scripts/pango_files.f")]
    for name in ("ddr3_test.v", "ddr3_test_ddrphy_top.v", "ddr3_test.idf"):
        staged.append((ip / name, Path("ip") / name))
    for source in sorted((ip / "rtl").rglob("*")):
        if source.is_file():
            staged.append((source, Path("ip") / source.relative_to(ip)))
    for name in ("imem.hex", "dmem.hex", firmware_identity["elf"]):
        staged.append((firmware / name, Path("firmware") / name))
    if args.firmware_role == "coremark-interactive":
        staged.append((firmware / "manifest.json", Path("firmware/manifest.json")))
        for name in firmware_identity["source_sha256"]:
            staged.append((repo / name, Path("firmware/source") / name))
    if any(not source.is_file() for source, _ in staged):
        parser.error("missing generated IP or production loader; generate IP and make loader first")
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
    schema = 9 if args.board_clock_profile else (8 if scoreboard else 3)
    manifest = {"schema_version": schema, "xlen": args.xlen, "mul": 0, "div": 1,
                "dma_wide_enable": 1, "ddr_data_bits": 256,
                "cache_block_enable": 1, "dma_block_enable": 1, "core_issue_width": 1,
                "soc_profile": args.soc_profile, "soc_profile_id": profile_id,
                "local_tcm_enable": args.local_tcm, "soc_presence": f"0x{present:04x}",
                "slow_presence": f"0x{present & (0x7ff3 if args.local_tcm or scoreboard else 0x7fff):04x}",
                "soc_clock_hz": int(user_mhz * 1000000),
                "ddr_actual_rate_mbps": float(params["ACTUAL_RATE"]),
                "device": "PG2L200H-6IFBB676", "top": "pango_200hp_top",
                "status": "candidate; no timing closure or board compatibility claim", "files": {}}
    if args.synthesis_strategy != "standard":
        manifest["synthesis_strategy"] = args.synthesis_strategy
    if scoreboard:
        manifest.update(SCOREBOARD_CONFIGURATION)
        manifest.update(icache_bytes=args.icache_bytes, dcache_bytes=args.dcache_bytes, dcache_bank_xor_mask=args.dcache_bank_xor_mask)
        manifest.update(core_retire_entries=args.retire_entries,
                        core_split_issue_queue=args.split_issue_queue,
                        core_limited_integer_ooo=args.limited_integer_ooo,
                        core_scheduler_forward_mode=args.scheduler_forward_mode,
                        core_issue_queue_entries=args.integer_queue_entries,
                        core_memory_queue_entries=args.memory_queue_entries,
                        core_predictor_mode=args.predictor_mode, core_ras_enable=args.ras_enable)
        if args.board_clock_profile:
            profile = BOARD_CLOCK_PROFILES[args.board_clock_profile]
            manifest.update(soc_topology="soc_system", core_profile=core_profile(manifest),
                            board_clock_profile=args.board_clock_profile,
                            clock_profile=profile["name"],
                            board_clock_domains_hz={domain: profile[domain]
                                                    for domain in ("core", "sys", "ddr", "periph")},
                            clock_relationship=board_clock_relationship(args.board_clock_profile),
                            mtime_clock_domain="periph")
        else:
            manifest.update(soc_topology="soc_system", core_profile=core_profile(manifest),
                            board_clock_domains_hz=dict(BOARD_CLOCK_DOMAINS),
                            clock_relationship="common_ddr_user_clock", mtime_clock_domain="periph")
    if args.npu_enable or args.mm3_enable:
        manifest["mm3_enable" if args.mm3_enable else "npu_enable"] = True
        manifest["board_clock_domains_hz"]["npu"] = board_clock_hz(args.board_clock_profile, 'npu')
    if args.firmware_role == "coremark-interactive":
        manifest.update(firmware_manifest_version=1, firmware_role=args.firmware_role,
                        firmware=firmware_identity, config=project_configuration(manifest))
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
    if args.board_clock_profile:
        (root / "board_clocks.fdc").write_text(
            board_clock_constraints(args.board_clock_profile, args.npu_enable or args.mm3_enable), encoding="utf-8")
        manifest["files"]["board_clocks.fdc"] = hashlib.sha256(
            (root / "board_clocks.fdc").read_bytes()).hexdigest()
    rtl = [relative for _, relative in staged if relative.suffix in (".sv", ".v", ".vp")]
    commands = ["# Offline ADS candidate flow; no JTAG/configuration commands.",
                "set_arch -family Logos2 -device PG2L200H -package FBB676 -speedgrade -6"]
    commands += [f"add_design {{{path.as_posix()}}}" for path in rtl]
    commands += ["add_constraint {board_ddr.fdc}"]
    if args.board_clock_profile:
        commands += ["add_constraint {board_clocks.fdc}"]
    commands += [compile_command(args.xlen, profile_id, args.local_tcm,
                                 dma_wide=1, cache_block=1, dma_block=1,
                                 core_issue_width=2 if scoreboard else 1, scoreboard=scoreboard,
                                 scoreboard_config=manifest if scoreboard else None,
                                 soc_system=scoreboard,
                                 board_clock_profile=args.board_clock_profile,npu_enable=args.npu_enable,mm3_enable=args.mm3_enable,
                                 icache_bytes=args.icache_bytes,dcache_bytes=args.dcache_bytes, dcache_bank_xor_mask=args.dcache_bank_xor_mask)]
    (root / "compile.tcl").write_text("\n".join(commands) + "\n", encoding="utf-8")
    (root / "synthesize.tcl").write_text(synthesis_commands(args.synthesis_strategy), encoding="utf-8")
    for name in ('implement.tcl', *CDC_IMPLEMENTATION_SCRIPTS):
        template = (repo / 'scripts/pango' / name).read_text()
        (root / name).write_text(implementation_commands(template, args.synthesis_strategy))
    for name in MEMORY_SCRIPTS:
        shutil.copyfile(repo / "scripts/pango" / name, root / name)
    manifest["memory_guard_version"] = 1
    manifest["cdc_implementation_version"] = 1
    for name in GENERATED_SCRIPTS + MEMORY_SCRIPTS + CDC_IMPLEMENTATION_SCRIPTS:
        manifest["files"][name] = hashlib.sha256((root / name).read_bytes()).hexdigest()
    verify_staged_manifest(root, manifest)
    (root / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    print(f"PASS staged RV{args.xlen} m0d1 profile={args.soc_profile} "
          f"local_tcm={args.local_tcm} dma_wide=1 ddr_data=256 cache_block=1 dma_block=1 "
          f"core_backend={args.core_backend} core_issue_width={2 if scoreboard else 1} "
          f"board_clock_profile={args.board_clock_profile} candidate: {len(rtl)} HDL files, {root}")
    print("Run pds_shell -work_dir <output> -project_name soc_rvN -file <output>/compile.tcl first.")


if __name__ == "__main__":
    main()
