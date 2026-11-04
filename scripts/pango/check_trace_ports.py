#!/usr/bin/env python3
"""Check that the FPGA wrapper drives every pango_boot_trace input.

未连接的输入会被综合成常量，启动帧因此全零。本检查在综合前静态比对模块端口与
顶层实例，避免再次把“观测口全零”误判为 RTL 故障。
"""

import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]


def module_ports(text, name):
    match = re.search(rf"module\s+{name}\b(.*?)\);", text, re.S)
    if match is None:
        raise SystemExit(f"missing module {name}")
    body = match.group(1)
    body = re.sub(r"//[^\n]*", "", body)
    ports = []
    for item in re.split(r",(?![^\[]*\])", body):
        item = item.strip()
        if not item or item.startswith("#") or item.startswith("parameter"):
            continue
        item = item.split("=")[0].strip()
        names = re.search(r"([A-Za-z_]\w*)\s*$", item)
        if names:
            ports.append(names.group(1))
    return ports


def instance_connections(text, instance):
    match = re.search(rf"{instance}\b(.*?)\);", text, re.S)
    if match is None:
        raise SystemExit(f"missing instance {instance}")
    body = re.sub(r"//[^\n]*", "", match.group(1))
    connected = {}
    for item in re.split(r",(?![^\[]*\])", body):
        item = item.strip()
        if not item:
            continue
        pair = re.match(r"\.(\w+)\s*(?:\((.*)\))?$", item, re.S)
        if pair:
            connected[pair.group(1)] = (pair.group(2) or pair.group(1)).strip()
    return connected


def main():
    trace = (ROOT / "vsrc/cpu/pango_boot_trace.sv").read_text(encoding="utf-8")
    top = (ROOT / "vsrc/cpu/pango_200hp_top.sv").read_text(encoding="utf-8")
    ports = module_ports(trace, "pango_boot_trace")
    connections = instance_connections(top, "u_boot_trace")
    missing = [name for name in ports if name not in connections]
    empty = [name for name in ports
             if name in connections and connections[name] == ""]
    if missing or empty:
        for name in missing:
            print(f"FAIL missing connection: {name}")
        for name in empty:
            print(f"FAIL empty connection: {name}")
        return 1
    print(f"PASS boot trace ports: {len(ports)} connected")
    return 0


if __name__ == "__main__":
    sys.exit(main())
