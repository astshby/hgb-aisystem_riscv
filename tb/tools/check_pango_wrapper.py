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
    path.write_text(
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


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=REPO / "build/pango-handoff-wrapper")
    args = parser.parse_args()
    output = args.output.resolve()
    if output.exists() and any(output.iterdir()):
        parser.error("output must be empty; retain earlier elaboration evidence")
    output.mkdir(parents=True, exist_ok=True)
    stub = output / "vendor_stubs.sv"
    write_vendor_stub(stub)
    results = []
    for xlen in (32, 64):
        for profile in ("full", "lite"):
            for local in (0, 1):
                destination = output / f"rv{xlen}-p{profile}-ltcm{local}"
                destination.mkdir()
                tree = destination / "rtl.tree.json"
                command = ["verilator", "-Wall", "-Wno-fatal", "--timing", "--json-only",
                           "--json-only-output", str(tree), "--json-only-meta-output", str(destination / "rtl.meta.json"),
                           f"-DCORE_XLEN={xlen}", "-DCORE_MUL_IMPL=0", "-DCORE_DIV_IMPL=1",
                           "-f", "scripts/pango_files.f", str(stub), "--top-module", "pango_200hp_top",
                           f"-GSOC_PROFILE={int(profile == 'lite')}", f"-GLOCAL_TCM_ENABLE={local}"]
                completed = subprocess.run(command, cwd=REPO, text=True, stdout=subprocess.PIPE,
                                           stderr=subprocess.STDOUT)
                (destination / "elaborate.log").write_text(completed.stdout)
                if completed.returncode:
                    raise RuntimeError(f"wrapper elaboration failed: {destination}\n{completed.stdout[-8000:]}")
                warnings = [line for line in completed.stdout.splitlines() if
                            re.search(r"%(?:Error|Warning-(?:PINMISSING|PINNOTFOUND|LATCH|UNOPTFLAT|MULTIDRIVEN)):", line) or
                            (re.search(r"%Warning-WIDTH[A-Z]*:", line) and
                             ("vsrc/cpu/pango_200hp_top.sv:" in line or "vendor_stubs.sv:" in line))]
                if warnings:
                    raise RuntimeError(f"wrapper critical warnings: {warnings}")
                # core 内既有位宽提示保留在日志，不把本次参数接线检查说成全仓 lint 干净。
                result = check_tree(tree, xlen, profile, local)
                result["warning_count"] = len(re.findall(r"^%Warning-", completed.stdout, re.M))
                results.append(result)
                print("PASS wrapper elaboration " + json.dumps(result, sort_keys=True), flush=True)
    (output / "summary.json").write_text(json.dumps({"status": "offline elaboration only; no PDS/DDR/board evidence",
                                                    "configurations": results}, indent=2) + "\n")
    print("PASS 8/8 wrapper configurations; PDS, DDR behavior, timing and board checks NOT RUN")


if __name__ == "__main__":
    main()
