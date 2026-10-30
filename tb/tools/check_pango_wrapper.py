#!/usr/bin/env python3
"""Elaborate all board-wrapper profiles with metadata-only vendor stubs; no PDS/IP/DDR simulation."""
import argparse
from collections import Counter
import json
from pathlib import Path
import re
import subprocess
import sys
import xml.etree.ElementTree as ET

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO))
from scripts.verilator.check_soc_profile_structure import instantiated_modules, parameter, walk
from scripts.pango.prepare_project import DEFAULT_SCOREBOARD_CONFIGURATION, BOARD_CLOCK_PROFILES


def write_vendor_stub(path):
    # 端口宽度取自保存的 IDF；只建立 elaboration 黑盒，不模拟 PHY、校准或时钟倍频。
    pins = [pin for pin in ET.parse(REPO / "ip/pango/mes2l676_200hp_ddr3.idf").findall(".//pin")
            if pin.findtext("visible") != "0" or pin.findtext("name") == "ref_clk"]
    # IDF 还列出未启用的 DFI/训练选项引脚；当前板级接口只取可见引脚和参考时钟。
    assert pins and len({pin.findtext("name") for pin in pins}) == len(pins)
    declarations, assignments = [], []
    for pin in pins:
        direction, name = pin.findtext("dir"), pin.findtext("name")
        assert direction in ("input", "output", "inout") and re.fullmatch(r"[A-Za-z_]\w*", name)
        msb, lsb = pin.findtext("msb"), pin.findtext("lsb")
        width = "" if msb is None else f"[{int(msb)}:{int(lsb)}] "
        declarations.append(f"    {direction} wire {width}{name}")
        if direction == "output":
            assignments.append(f"    assign {name} = " + ("ref_clk;" if name == "core_clk" else "'0;"))
    pll_parameters = ["parameter real CLKIN_FREQ=125.0", 'parameter INTERNAL_FB="CLKOUTF"',
                      'parameter EXTERNAL_FB="DISABLE"', 'parameter BANDWIDTH="OPTIMIZED"']
    pll_parameters += [f"parameter integer STATIC_RATIO{suffix}=8" for suffix in ("I", "M", "F", "0", "1", "2", "3", "4", "5", "6")]
    pll_parameters += [f"parameter integer STATIC_DUTY{suffix}=8" for suffix in ("F", "0", "1", "2", "3", "4", "5", "6")]
    pll_outputs = ["CLKOUT0", "CLKOUT0N", "CLKOUT1", "CLKOUT1N", "CLKOUT2", "CLKOUT2N", "CLKOUT3", "CLKOUT3N",
                   "CLKOUT4", "CLKOUT5", "CLKOUT6", "CLKOUTF", "CLKOUTFN", "LOCK", "DPS_DONE", "APB_READY"]
    pll_inputs = ["CLKIN1", "CLKIN2", "CLKIN_SEL", "CLKFB", "RST", "PLL_PWD", "DPS_CLK", "DPS_EN", "DPS_DIR",
                  "CLKOUT0_SYN", "CLKOUT1_SYN", "CLKOUT2_SYN", "CLKOUT3_SYN", "CLKOUT4_SYN", "CLKOUT5_SYN",
                  "CLKOUT6_SYN", "CLKOUTF_SYN", "APB_CLK", "APB_RST_N", "APB_SEL", "APB_EN", "APB_WRITE"]
    pll_stub = ("// Module: GTP_GPLL\n// Description: Elaboration stub only; outputs are not generated clocks.\n"
                "module GTP_GPLL #(\n" + ",\n".join(pll_parameters) + ")(\n" +
                ",\n".join(["output wire " + name for name in pll_outputs] +
                             ["input wire " + name for name in pll_inputs] +
                             ["input wire [4:0] APB_ADDR", "input wire [15:0] APB_WDATA", "output wire [15:0] APB_RDATA"]) + ");\n" +
                "\n".join("assign " + name + " = '0;" for name in pll_outputs + ["APB_RDATA"]) + "\nendmodule\n"
                "// Module: GTP_CLKBUFG\n// Description: Elaboration stub only.\n"
                "module GTP_CLKBUFG(input wire CLKIN, output wire CLKOUT); assign CLKOUT=CLKIN; endmodule\n")
    ppll_parameters = ["parameter real CLKIN_FREQ=27.0", "parameter LOCK_MODE=1'b0",
                       'parameter INTERNAL_FB="CLKOUTF"', 'parameter EXTERNAL_FB="DISABLE"',
                       'parameter BANDWIDTH="LOW"']
    ppll_parameters += [f"parameter integer STATIC_RATIO{suffix}=1" for suffix in ("I","M","F","0","1","2","3","4","PHY")]
    ppll_parameters += [f"parameter integer STATIC_DUTY{suffix}=2" for suffix in ("F","0","1","2","3","4","PHY")]
    ppll_outputs = ["CLKOUT0","CLKOUT0N","CLKOUT1","CLKOUT1N","CLKOUT2","CLKOUT2N","CLKOUT3","CLKOUT3N",
                    "CLKOUT4","CLKOUTPHY","CLKOUTPHYN","CLKOUTF","CLKOUTFN","LOCK","APB_READY"]
    ppll_inputs = ["CLKIN1","CLKIN2","CLKIN_SEL","CLKFB","RST","PLL_PWD","CLKOUT0_SYN","CLKOUT1_SYN",
                   "CLKOUT2_SYN","CLKOUT3_SYN","CLKOUT4_SYN","CLKOUTPHY_SYN","CLKOUTF_SYN",
                   "APB_CLK","APB_RST_N","APB_SEL","APB_EN","APB_WRITE"]
    ppll_stub = ("// Module: GTP_PPLL\n// Description: Elaboration stub only; frequency is verified separately with the vendor model.\n"
                 "module GTP_PPLL #(\n"+",\n".join(ppll_parameters)+")(\n"+
                 ",\n".join(["output wire "+name for name in ppll_outputs]+
                              ["input wire "+name for name in ppll_inputs]+
                              ["input wire [4:0] APB_ADDR","input wire [15:0] APB_WDATA","output wire [15:0] APB_RDATA"])+");\n"+
                 "\n".join("assign "+name+" = '0;" for name in ppll_outputs+["APB_RDATA"])+"\nendmodule\n")
    path.write_text(pll_stub + ppll_stub +
        "// Module: GTP_INBUFDS\n// Description: Offline elaboration stub, not vendor primitive behavior.\n"
        "module GTP_INBUFDS(input wire I, IB, output wire O);\n    assign O = I;\nendmodule\n"
        "// Module: ddr3_test\n// Description: IDF-port elaboration stub, not a DDR model or generated IP.\n"
        "module ddr3_test (\n" + ",\n".join(declarations) + "\n);\n" +
        "\n".join(assignments) + "\nendmodule\n")


def check_tree(path, xlen, profile, local):
    tree = json.loads(path.read_text())
    config = next(node for node in tree["modulesp"] if node.get("origName") == "core_config_pkg")
    assert parameter(config, "XLEN") == xlen, "incorrect elaborated XLEN"
    modules = {node["addr"]: node for node in tree["modulesp"] if node["type"] == "MODULE"}
    wrapper = next(node for node in modules.values() if node.get("origName") == "pango_200hp_top")
    wrapper_cells = {node["name"]: modules[node["modp"]] for node in walk(wrapper) if node["type"] == "CELL"}
    soc = wrapper_cells["u_soc"]
    assert soc["origName"] == "soc_top"
    profile_id = int(profile == "lite")
    for module in (wrapper, soc):
        assert parameter(module, "SOC_PROFILE") == profile_id, "SOC_PROFILE did not reach u_soc"
        assert parameter(module, "LOCAL_TCM_ENABLE") == local, "LOCAL_TCM_ENABLE did not reach u_soc"
        assert parameter(module, "DMA_WIDE_ENABLE") == 1, "DMA_WIDE_ENABLE did not reach u_soc"
        assert parameter(module, "DMA_BLOCK_ENABLE") == 1, "DMA_BLOCK_ENABLE did not reach u_soc"
    assert parameter(soc, "DDR_BYTES") == 512 * 1024 * 1024
    assert parameter(soc, "CLOCK_HZ") == 125000000
    assert parameter(soc, "UART_DIVISOR") == 1085
    counts = Counter(node["origName"] for node in instantiated_modules(wrapper, modules))
    assert counts["ddr_port_arbiter"] == 1 and counts["pango_block_bridge"] == 1
    assert counts["ddr_block_fabric"] == counts["block_arbiter"] == 1
    assert parameter(soc, "CACHE_BLOCK_ENABLE") == 1
    engine = next(node for node in instantiated_modules(wrapper, modules) if node["origName"] == "dma_engine")
    assert parameter(engine, "WIDE_ENABLE") == 1, "native width did not reach DMA engine"
    assert parameter(engine, "BLOCK_ENABLE") == 1, "block DMA did not reach DMA engine"
    assert counts["dma_block_engine"] == 1 and counts["dma_legacy_engine"] == 0
    bus_pkg = next(node for node in tree["modulesp"] if node.get("origName") == "bus_types_pkg")
    assert parameter(bus_pkg, "DDR_DATA_W") == 256
    assert counts["tcm_controller"] == 2, f"physical TCM count {counts['tcm_controller']}"
    assert counts["tcm_local_fabric"] == local, f"local fabric count {counts['tcm_local_fabric']}"
    soc_cells = {node["name"]: modules[node["modp"]] for node in walk(soc) if node["type"] == "CELL"}
    assert soc_cells["u_itcm"]["origName"] == soc_cells["u_dtcm"]["origName"] == "tcm_controller"
    present = 0x727f if profile_id else 0x7fff
    slow = present & (0x7ff3 if local else 0x7fff)
    assert parameter(soc, "DEVICE_PRESENT") == present
    assert parameter(soc, "SLOW_PRESENT") == parameter(soc_cells["u_fabric"], "PRESENT") == slow
    peripherals = soc_cells["u_peripherals"]
    assert parameter(peripherals, "SOC_PROFILE") == profile_id
    assert parameter(peripherals, "PRESENT") == present
    info = next(node for node in instantiated_modules(peripherals, modules) if node["origName"] == "soc_info")
    assert parameter(info, "PRESENT") == present and parameter(info, "SOC_PROFILE") == profile_id
    assert counts["uart"] == (1 if profile_id else 2)
    assert counts["gpio"] == (1 if profile_id else 3)
    assert counts["general_timer"] == (0 if profile_id else 1)
    return {"xlen": xlen, "profile": profile, "local_tcm": local, "dma_wide": 1, "ddr_data_bits": 256,
            "presence": f"0x{present:04x}", "slow_presence": f"0x{slow:04x}",
            "tcm_instances": counts["tcm_controller"], "local_fabric_instances": counts["tcm_local_fabric"]}


def check_scoreboard_tree(path, xlen, profile, clock_profile=0, npu=False, video=False):
    tree = json.loads(path.read_text())
    modules = {node["addr"]: node for node in tree["modulesp"] if node["type"] == "MODULE"}
    wrapper = next(node for node in modules.values() if node.get("origName") == "pango_200hp_top")
    children = list(instantiated_modules(wrapper, modules))
    counts = Counter(node["origName"] for node in children)
    soc = next(node for node in children if node["origName"] == "soc_system")
    assert parameter(soc, "SOC_PROFILE") == int(profile == "lite")
    assert parameter(soc, "DDR_BYTES") == 512 * 1024 * 1024
    assert parameter(soc, "CLOCK_HZ") == 125000000
    assert parameter(wrapper, "BOARD_CLOCK_PROFILE") == clock_profile
    expected_clocks = {d:BOARD_CLOCK_PROFILES[clock_profile][d] for d in ('core','sys','ddr','periph')}
    assert parameter(soc, "CLOCK_INFO_ENABLE") == int(clock_profile != 0)
    for domain, frequency in expected_clocks.items():
        assert parameter(soc, f"{domain.upper()}_CLOCK_HZ") == frequency
    assert parameter(soc, "UART_DIVISOR") == (expected_clocks["periph"] + 57600) // 115200
    assert counts["pango_soc_pll"] == counts["GTP_GPLL"] == counts["pango_soc_reset"] == int(clock_profile != 0)
    assert counts["GTP_CLKBUFG"] == (3+int(npu)+int(video) if clock_profile else 0)
    assert parameter(wrapper,"NPU_ENABLE") == int(npu)
    assert parameter(wrapper,"VIDEO_ENABLE") == parameter(soc,"VIDEO_ENABLE") == int(video)
    for name in ("pango_video_pll","GTP_PPLL","yolo_video","video_pair_fifo","video_frame_reader",
                 "video_timing","ms7210_init","video_i2c_master","axil_video_split"):
        assert counts[name] == int(video), (name,counts[name],video)
    assert counts["npu_axi_target"] == int(npu)
    if video:
        ppll = next(node for node in children if node.get("origName") == "GTP_PPLL")
        for name,value in (("STATIC_RATIOI",1),("STATIC_RATIOM",2),("STATIC_RATIOF",33),("STATIC_RATIO0",12)):
            assert parameter(ppll,name) == value, (name,parameter(ppll,name))
    assert parameter(soc, "FLASH_BYTES") == 0
    for name in ("scoreboard_core", "cpu_memory_adapter", "axi_system_fabric",
                 "axi_availability_gate", "ddr_axi_target", "pango_block_bridge",
                 "dma_axi_master", "dma_block_engine", "mmio_bus"):
        assert counts[name] == 1, (name, counts[name])
    assert counts["tcm_bram"] == 2
    for name in ("scoreboard_soc_memory", "ddr_port_arbiter", "ddr_block_fabric", "dma_legacy_engine"):
        assert counts[name] == 0, (name, counts[name])
    config = next(node for node in tree["modulesp"] if node.get("origName") == "core_config_pkg")
    assert parameter(config, "XLEN") == xlen
    actual_core = {}
    for key, expected in DEFAULT_SCOREBOARD_CONFIGURATION.items():
        if key.startswith("core_") and type(expected) is int:
            actual_core[key] = parameter(config, key.removeprefix("core_").upper())
            assert actual_core[key] == expected, f"baseline parameter did not reach core_config_pkg: {key}"
    assert parameter(config, "RETIRE_IDX_W") == 4
    assert parameter(config, "SCHEDULER_ENTRIES") == 12
    assert counts["uart"] == (1 if profile == "lite" else 2)
    assert counts["gpio"] == (1 if profile == "lite" else 3)
    return {"xlen": xlen, "profile": profile, "backend": "scoreboard",
            "system": "AXI4", "physical_tcm": 2, "board_clock_profile": clock_profile, "board_clock_domains_hz": expected_clocks,
            "npu_enable":npu,"video_enable":video,"video_pixel_hz":148500000 if video else 0,
            "flash_pins_connected": False, "core_profile": "custom", "core_configuration": actual_core}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=REPO / "build/pango-handoff-wrapper")
    parser.add_argument("--backend", choices=("legacy", "scoreboard"), default="legacy")
    parser.add_argument("--clock-profile", type=int, choices=tuple(BOARD_CLOCK_PROFILES), default=0)
    parser.add_argument("--npu-enable", action="store_true")
    parser.add_argument("--video-enable", type=int, choices=(0,1), default=None,
                        help="default follows NPU_ENABLE; this remains elaboration only")
    args = parser.parse_args()
    if args.backend == "legacy" and args.clock_profile:
        parser.error("independent domains require scoreboard")
    video = bool(args.npu_enable) if args.video_enable is None else bool(args.video_enable)
    if (args.npu_enable or video) and (args.backend != 'scoreboard' or not args.clock_profile):
        parser.error("NPU/video requires independent scoreboard clocks")
    output = args.output.resolve()
    if output.exists() and any(output.iterdir()):
        parser.error("output must be empty; retain earlier elaboration evidence")
    output.mkdir(parents=True, exist_ok=True)
    stub = output / "vendor_stubs.sv"
    write_vendor_stub(stub)
    results = []
    for xlen in (32, 64):
        for profile in ("full", "lite"):
            for local in ((1,) if args.backend == "scoreboard" else (0, 1)):
                destination = output / f"rv{xlen}-p{profile}-ltcm{local}"
                destination.mkdir()
                tree = destination / "rtl.tree.json"
                command = ["verilator", "-Wall", "-Wno-fatal", "--timing", "--json-only",
                           "--json-only-output", str(tree), "--json-only-meta-output", str(destination / "rtl.meta.json"),
                           f"-DCORE_XLEN={xlen}", "-DCORE_MUL_IMPL=0", "-DCORE_DIV_IMPL=1",
                           "-f", "scripts/pango_files.f", str(stub), "--top-module", "pango_200hp_top",
                           f"-GSOC_PROFILE={int(profile == 'lite')}", f"-GBOARD_CLOCK_PROFILE={args.clock_profile}"]
                if args.npu_enable:
                    command += ['-GNPU_ENABLE=1']
                if args.video_enable is not None:
                    command += [f'-GVIDEO_ENABLE={args.video_enable}']
                if args.backend == "scoreboard":
                    command += ["-DCORE_SCOREBOARD"]
                    command += [f"-D{key.upper()}={value}" for key, value in DEFAULT_SCOREBOARD_CONFIGURATION.items()
                                if key.startswith("core_") and type(value) is int]
                else:
                    command += [f"-GLOCAL_TCM_ENABLE={local}"]
                (destination / "command.json").write_text(json.dumps(command, indent=2) + "\n")
                completed = subprocess.run(command, cwd=REPO, text=True, stdout=subprocess.PIPE,
                                           stderr=subprocess.STDOUT)
                (destination / "elaborate.log").write_text(completed.stdout)
                if completed.returncode:
                    raise RuntimeError(f"wrapper elaboration failed: {destination}\n{completed.stdout[-8000:]}")
                warnings = [line for line in completed.stdout.splitlines() if
                            re.search(r"%(?:Error|Warning-(?:PINMISSING|PINNOTFOUND|LATCH|UNOPTFLAT|MULTIDRIVEN|ALWCOMBORDER)):", line) or
                            (re.search(r"%Warning-WIDTH[A-Z]*:", line) and
                             ("vsrc/cpu/pango_200hp_top.sv:" in line or "vendor_stubs.sv:" in line))]
                if warnings:
                    raise RuntimeError(f"wrapper critical warnings: {warnings}")
                # core 内既有位宽提示保留在日志，不把本次参数接线检查说成全仓 lint 干净。
                result = (check_scoreboard_tree(tree, xlen, profile, args.clock_profile,args.npu_enable,video) if args.backend == "scoreboard"
                          else check_tree(tree, xlen, profile, local))
                result["warning_count"] = len(re.findall(r"^%Warning-", completed.stdout, re.M))
                results.append(result)
                print("PASS wrapper elaboration " + json.dumps(result, sort_keys=True), flush=True)
    (output / "summary.json").write_text(json.dumps({"status": "offline elaboration only; no PDS/DDR/board evidence",
                                                    "configurations": results}, indent=2) + "\n")
    print(f"PASS {len(results)}/{len(results)} wrapper configurations; PDS, DDR behavior, timing and board checks NOT RUN")


if __name__ == "__main__":
    main()
