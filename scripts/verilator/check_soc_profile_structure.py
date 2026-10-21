#!/usr/bin/env python3
"""Check elaborated SoC profile instances and request slots, not synthesis resource estimates."""
import argparse
from collections import Counter
import json
from pathlib import Path


def walk(node):
    yield node
    for value in node.values():
        if isinstance(value, list):
            for child in value:
                if isinstance(child, dict):
                    yield from walk(child)


def instantiated_modules(module, modules, ancestors=()):
    # 沿每个 CELL 的实例边递归；不能全局去重 modp，同一模块定义可被实例化多次。
    assert module["addr"] not in ancestors, "recursive elaborated module hierarchy"
    yield module
    ancestry = (*ancestors, module["addr"])
    for node in walk(module):
        if node["type"] == "CELL":
            assert node["modp"] in modules, f"unresolved instantiated module: {node['name']}"
            yield from instantiated_modules(modules[node["modp"]], modules, ancestry)


def parameter(module, name, default=None):
    for node in module["stmtsp"]:
        if node["type"] == "VAR" and node.get("isParam") and node["name"] == name:
            values = node["valuep"]
            assert len(values) == 1 and values[0]["type"] == "CONST", f"nonconstant {name}"
            _, radix_value = values[0]["name"].split("'", 1)
            radix_value = radix_value.removeprefix("s")
            return int(radix_value[1:], {"b": 2, "o": 8, "d": 10, "h": 16}[radix_value[0]])
    if default is not None:
        return default
    raise AssertionError(f"missing parameter {name}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("tree", type=Path)
    parser.add_argument("--profile", choices=("full", "lite"), required=True)
    parser.add_argument("--ddr-bytes", type=int, choices=(0, 65536), required=True)
    parser.add_argument("--xlen", type=int, choices=(32, 64), required=True)
    parser.add_argument("--local-tcm", type=int, choices=(0, 1), required=True)
    args = parser.parse_args()
    tree = json.loads(args.tree.read_text())
    core_config = next(node for node in tree["modulesp"] if node.get("origName") == "core_config_pkg")
    assert parameter(core_config, "XLEN") == args.xlen, "JSON was elaborated for a different XLEN"
    modules = {node["addr"]: node for node in tree["modulesp"] if node["type"] == "MODULE"}
    top = next(node for node in modules.values() if node.get("origName") == "soc_top")
    instance_counts = Counter(node["origName"] for node in instantiated_modules(top, modules))
    assert instance_counts["tcm_controller"] == 2, \
        f"expected exactly 2 physical TCM instances, got {instance_counts['tcm_controller']}"
    local_tcm = parameter(top, "LOCAL_TCM_ENABLE")
    assert local_tcm == args.local_tcm, "JSON was elaborated for a different LOCAL_TCM_ENABLE"
    assert instance_counts["tcm_local_fabric"] == local_tcm, \
        f"expected {local_tcm} local TCM fabric instances, got {instance_counts['tcm_local_fabric']}"
    top_cells = {node["name"]: modules[node["modp"]] for node in walk(top) if node["type"] == "CELL"}
    peripherals = top_cells["u_peripherals"]
    device_cells = [modules[node["modp"]] for node in walk(peripherals) if node["type"] == "CELL"]
    counts = Counter(node["origName"] for node in device_cells)
    profile_id = int(args.profile == "lite")
    present = (0x327f if profile_id else 0x3fff) | (0x4000 if args.ddr_bytes else 0)
    expected_counts = {"machine_timer": 1, "irq_controller": 1, "uart": 1 if profile_id else 2,
                       "gpio": 1 if profile_id else 3, "dma_controller": 1, "soc_info": 1}
    if not profile_id:
        expected_counts["general_timer"] = 1
    assert counts == Counter(expected_counts), f"wrong instantiated devices: {counts}"
    assert parameter(top, "SOC_PROFILE") == parameter(peripherals, "SOC_PROFILE") == profile_id
    assert parameter(top, "DDR_BYTES") == parameter(peripherals, "DDR_BYTES") == args.ddr_bytes
    assert parameter(top, "DEVICE_PRESENT") == parameter(peripherals, "PRESENT") == present
    # 软件能力是全局物理存在性；局部 TCM 路由只清慢 fabric 的两个目标位。
    slow_present = present & (0x7ff3 if local_tcm else 0x7fff)
    assert parameter(top, "SLOW_PRESENT") == parameter(top_cells["u_fabric"], "PRESENT") == slow_present
    info = next(node for node in device_cells if node["origName"] == "soc_info")
    assert parameter(info, "PRESENT") == present and parameter(info, "SOC_PROFILE") == profile_id
    assert top_cells["u_itcm"]["origName"] == top_cells["u_dtcm"]["origName"] == "tcm_controller"
    slots = 0
    for target in range(4, 14):
        scope = next(node for node in peripherals["stmtsp"]
                     if node["type"] == "GENBLOCK" and node["name"] == f"g_mmio_boundary[{target}]")
        state = [node for node in walk(scope) if node["type"] == "VAR" and
                 node.get("origName") in ("state_q", "request_q")]
        expected = 2 if present & (1 << target) else 0
        assert len(state) == expected, f"target {target} retained/missing request state: {len(state)}"
        slots += expected // 2
    assert slots == (6 if profile_id else 10)
    print(f"PASS soc profile structure RV{args.xlen} profile={args.profile} "
          f"LOCAL_TCM_ENABLE={local_tcm} DDR_BYTES={args.ddr_bytes} "
          f"presence=0x{present:04x} uart={counts['uart']} gpio={counts['gpio']} "
          f"general_timer={counts['general_timer']} request_slots={slots} "
          f"tcm={instance_counts['tcm_controller']} local_fabric={instance_counts['tcm_local_fabric']}; "
          "elaboration only")


if __name__ == "__main__":
    main()
