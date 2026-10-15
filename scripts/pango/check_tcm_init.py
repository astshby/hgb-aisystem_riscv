#!/usr/bin/env python3
"""Reconstruct RV32 TCM contents from this ADS flow's 16Kx2 DRM banks.

Checks all 64 KiB per TCM against the staged loader HEX. This is a netlist
initial-value check, not a gate-level protocol simulation or a bitstream check.
Unknown mapping shapes fail rather than silently accepting a different layout.
"""
import argparse
import hashlib
from pathlib import Path
import re


def reconstruct(vm, instance):
    instantiated = re.search(r"^\s+(\w+)\s+" + instance + r"\s+\(", vm, re.M)
    if not instantiated:
        raise ValueError(f"missing {instance}")
    module = re.search(r"^module\s+" + instantiated[1] + r"\b(.*?)^endmodule", vm, re.M | re.S)
    if not module:
        raise ValueError("missing TCM module")
    banks = re.findall(r"GTP_DRM36K_E1\s*/\*.*?\*/\s*#\((.*?)\)\s+(\w+)\s+\((.*?)\);", module[1], re.S)
    if len(banks) != 16:
        raise ValueError(f"{instance}: expected 16 DRM banks, found {len(banks)}")
    words = [0] * 16384
    covered = set()
    expected_address = ["1'b1"] + [f"\\request.addr[{bit}]" for bit in range(15, 1, -1)] + ["1'b1"]
    for params, name, ports in banks:
        if not re.search(r'\.INIT_FILE\("NONE"\)', params) or not re.search(r"\.DATA_WIDTH_A\(2\)", params):
            raise ValueError(f"unsupported init/width: {name}")
        address = re.search(r"\.ADDRA\s*\(\{(.*?)\}\)", ports, re.S)
        output = re.search(r"\.DOA\s*\(\{(.*?)\}\)", ports, re.S)
        if not address or not output:
            raise ValueError(f"missing address/output: {name}")
        if [re.sub(r"\s+", "", item) for item in address[1].split(",")] != expected_address:
            raise ValueError(f"unsupported address mapping: {name}")
        bits = [re.fullmatch(r"\\response\.rdata\[(\d+)\]", re.sub(r"\s+", "", item))
                for item in output[1].split(",")[-2:]]
        if not all(bits):
            raise ValueError(f"unsupported data mapping: {name}")
        high, low = [int(bit[1]) for bit in bits]
        if high != low + 1 or low % 2 or not 0 <= low < 32 or low in covered:
            raise ValueError(f"overlap/invalid data mapping: {name}")
        covered.add(low)
        init_items = re.findall(r"\.INIT_([0-7][0-9A-F])\(288'b([01]{288})\)", params)
        init = {int(index, 16): int(value, 2) for index, value in init_items}
        if len(init_items) != 128 or set(init) != set(range(128)):
            raise ValueError(f"incomplete INIT parameters: {name}")
        # 厂商模型将每个 INIT 切为 32 个 9-bit 单元；x2 模式每单元存四个字，跳过 parity 位。
        for word in range(16384):
            cell, pair = divmod(word, 4)
            chunk, slot = divmod(cell, 32)
            value = (init[chunk] >> (9 * slot + 2 * pair)) & 3
            words[word] |= value << low
    if covered != set(range(0, 32, 2)):
        raise ValueError("incomplete word coverage")
    return words


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("project", type=Path)
    parser.add_argument("--netlist", type=Path, help="override synthesized VM for fault checks")
    args = parser.parse_args()
    netlist = args.netlist or args.project / "prj_tasks/syn_1/synthesize/pango_200hp_top_syn.vm"
    vm = netlist.read_text(encoding="utf-8")
    for kind in ("i", "d"):
        expected = [int(word, 16) for word in (args.project / f"firmware/{kind}mem.hex").read_text().split()]
        actual = reconstruct(vm, f"u_{kind}tcm")
        if len(expected) != 16384:
            raise ValueError("expected 64 KiB of RV32 HEX")
        for index, (a, b) in enumerate(zip(actual, expected)):
            if a != b:
                raise ValueError(f"{kind.upper()}TCM init mismatch word={index:#x}: VM={a:08x}, HEX={b:08x}")
        raw = b"".join(word.to_bytes(4, "little") for word in actual)
        print(f"PASS synthesized {kind.upper()}TCM init: 65536 bytes, 16 DRM banks, SHA256={hashlib.sha256(raw).hexdigest()}")


if __name__ == "__main__":
    main()
