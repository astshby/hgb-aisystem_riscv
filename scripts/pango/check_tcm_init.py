#!/usr/bin/env python3
"""Reconstruct TCM contents from ADS DRM parameters and address/data wiring.

Checks all 64 KiB per TCM against the staged loader HEX. This is a netlist
initial-value check, not a gate-level protocol simulation or a bitstream check.
Unknown mapping shapes fail rather than silently accepting a different layout.
"""
import argparse
import hashlib
import json
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


def reconstruct_native(vm, instance, xlen):
    """Two word-interleaved banks: RV32 8Kx4, RV64 4Kx8/9 primitives.

    Pango's GTP_DRM36K_E1 model stores each INIT as 32 nine-bit cells.
    Narrow x4 mode packs two words per cell; x8/9 uses one cell per word.
    The unused parity bit is excluded from the CPU data in either case.
    """
    if xlen not in (32, 64):
        raise ValueError("native TCM needs RV32 or RV64")
    instantiated = re.search(r"^\s+(\w+)\s+\\?" + re.escape(instance) + r"\s+\(", vm, re.M)
    if not instantiated:
        raise ValueError(f"missing {instance}")
    module = re.search(r"^module\s+" + instantiated[1] + r"\b(.*?)^endmodule", vm, re.M | re.S)
    if not module:
        raise ValueError("missing TCM module")
    primitives = re.findall(r"GTP_DRM36K_E1\s*/\*.*?\*/\s*#\((.*?)\)\s+(\S+)\s+\((.*?)\);",
                            module[1], re.S)
    if len(primitives) != 16:
        raise ValueError(f"{instance}: expected 16 DRM primitives, found {len(primitives)}")
    lane_bits = xlen // 8
    word_count = 65536 // (xlen // 8)
    words = [0] * word_count
    covered = set()
    for params, name, ports in primitives:
        width = re.search(r"\.DATA_WIDTH_A\((\d+)\)", params)
        mode = re.search(r'\.RAM_MODE\("(SINGLE_PORT|TRUE_DUAL_PORT)"\)', params)
        if (not width or int(width[1]) not in ((4,) if xlen == 32 else (8, 9)) or
                not re.search(r'\.INIT_FILE\("NONE"\)', params) or not mode):
            raise ValueError(f"unsupported native init/width/mode: {name}")
        dual_port = mode[1] == "TRUE_DUAL_PORT"
        if dual_port:
            bank, low = dual_port_mapping(params, ports, instance, xlen, lane_bits, name)
            if (bank, low) in covered:
                raise ValueError(f"overlap/invalid native data mapping: {name}")
        else:
            bank, low = single_port_mapping(ports, xlen, lane_bits, name)
            if (bank, low) in covered:
                raise ValueError(f"overlap/invalid native data mapping: {name}")
        covered.add((bank, low))
        init_items = re.findall(r"\.INIT_([0-7][0-9A-F])\(288'b([01]{288})\)", params)
        init = {int(index, 16): int(value, 2) for index, value in init_items}
        if len(init_items) != 128 or set(init) != set(range(128)):
            raise ValueError(f"incomplete INIT parameters: {name}")
        for word in range(word_count // 2):
            cell, subword = divmod(word, 8 // lane_bits)
            chunk, slot = divmod(cell, 32)
            value = (init[chunk] >> (9 * slot + lane_bits * subword)) & ((1 << lane_bits) - 1)
            words[2 * word + bank] |= value << low
    if covered != {(bank, low) for bank in (0, 1) for low in range(0, xlen, lane_bits)}:
        raise ValueError("incomplete native word coverage")
    return words


def single_port_mapping(ports, xlen, lane_bits, name):
    """Original word-interleaved single-port implementation."""
    address = re.search(r"\.ADDRA\s*\(\{(.*?)\}\)", ports, re.S)
    output = re.search(r"\.DOA\s*\(\{(.*?)\}\)", ports, re.S)
    if not address or not output:
        raise ValueError(f"missing address/output: {name}")
    signals = [re.sub(r"\s+", "", item) for item in output[1].split(",")]
    bits = [re.fullmatch(r"\\bank_data\[([01])\]\[(\d+)\]", item)
            for item in signals[-lane_bits:]]
    if not all(bits):
        raise ValueError(f"unsupported native data mapping: {name}")
    bank = int(bits[0][1])
    low = int(bits[-1][2])
    if (any(int(bit[1]) != bank for bit in bits) or
            [int(bit[2]) for bit in bits] != list(range(low + lane_bits - 1, low - 1, -1)) or
            low % lane_bits or not 0 <= low < xlen or
            any(not signal.endswith("_floating") for signal in signals[:-lane_bits])):
        raise ValueError(f"overlap/invalid native data mapping: {name}")
    address_low = (xlen // 8).bit_length()
    expected_address = (["1'b1"] +
        [f"\\g_bank[{bank}].access.addr[{bit}]" for bit in range(15, address_low - 1, -1)] +
        ["1'b1"] * (address_low - 1))
    if [re.sub(r"\s+", "", item) for item in address[1].split(",")] != expected_address:
        raise ValueError(f"unsupported native address mapping: {name}")
    return bank, low


def dual_port_mapping(params, ports, instance, xlen, lane_bits, name):
    """Accept either native A/B assignment, checking both data and address ports."""
    primary = {"u_itcm": 0, "u_dtcm": 1, "g_tcm[0].u_ram": 0, "g_tcm[1].u_ram": 1}.get(instance)
    if primary is None:
        raise ValueError(f"unknown primary client: {instance}")
    mappings = []
    roles = set()
    for port in ("A", "B"):
        width = re.search(rf"\.DATA_WIDTH_{port}\((\d+)\)", params)
        if (not width or int(width[1]) not in ((4,) if xlen == 32 else (8, 9)) or
                not re.search(rf'\.WRITE_MODE_{port}\("READ_BEFORE_WRITE"\)', params) or
                not re.search(rf'\.DO{port}_REG\(0\)', params)):
            raise ValueError(f"unsupported dual-port width/read mode: {name} {port}")
        address = re.search(rf"\.ADDR{port}\s*\(\{{(.*?)\}}\)", ports, re.S)
        output = re.search(rf"\.DO{port}\s*\(\{{(.*?)\}}\)", ports, re.S)
        if not address or not output:
            raise ValueError(f"missing dual-port address/output: {name} {port}")
        signals = [re.sub(r"\s+", "", item) for item in output[1].split(",")]
        bits = [re.fullmatch(r"\\([ab])_data\[([01])\]\[(\d+)\]", item)
                for item in signals[-lane_bits:]]
        if not all(bits):
            raise ValueError(f"unsupported dual-port data mapping: {name} {port}")
        role, bank, low = bits[0][1], int(bits[0][2]), int(bits[-1][3])
        if (any((bit[1], int(bit[2])) != (role, bank) for bit in bits) or
                [int(bit[3]) for bit in bits] != list(range(low + lane_bits - 1, low - 1, -1)) or
                low % lane_bits or not 0 <= low < xlen or role in roles or
                any(not signal.endswith("_floating") for signal in signals[:-lane_bits])):
            raise ValueError(f"overlap/invalid dual-port data mapping: {name} {port}")
        address_low = (xlen // 8).bit_length()
        source = f"request[{primary}]" if role == "a" else f"auxiliary[{bank}]"
        expected = (["1'b1"] + [f"\\{source}.addr[{bit}]"
                    for bit in range(15, address_low - 1, -1)] + ["1'b1"] * (address_low - 1))
        if [re.sub(r"\s+", "", item) for item in address[1].split(",")] != expected:
            raise ValueError(f"unsupported dual-port address mapping: {name} {port}")
        roles.add(role)
        mappings.append((bank, low))
    if mappings[0] != mappings[1]:
        raise ValueError(f"dual-port lane mismatch: {name}")
    return mappings[0]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("project", type=Path)
    parser.add_argument("--netlist", type=Path, help="override synthesized VM for fault checks")
    parser.add_argument("--summary", type=Path, help="create a new JSON result after both TCMs match")
    args = parser.parse_args()
    manifest_path = args.project / "benchmark.json"
    paired = manifest_path.is_file()
    if not paired:
        manifest_path = args.project / "manifest.json"
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    config = manifest["config"] if paired else manifest
    top = config["pds_top"] if paired else "pango_200hp_top"
    netlist = args.netlist or args.project / f"prj_tasks/syn_1/synthesize/{top}_syn.vm"
    vm = netlist.read_text(encoding="utf-8")
    xlen = config["xlen"]
    native = paired or config.get("core_backend", "legacy") == "scoreboard"
    if not native and xlen != 32:
        raise ValueError("legacy netlist reconstruction currently supports RV32 only")
    results = {}
    for kind in ("i", "d"):
        expected = [int(word, 16) for word in (args.project / f"firmware/{kind}mem.hex").read_text().split()]
        instance = f"u_{kind}tcm"
        if native:
            names = [instance, f"g_tcm[{0 if kind == 'i' else 1}].u_ram"]
            matches = [name for name in names if re.search(
                r"^\s+\w+\s+\\?" + re.escape(name) + r"\s+\(", vm, re.M)]
            if len(matches) != 1:
                raise ValueError(f"expected one {kind.upper()}TCM instance, found {matches}")
            instance = matches[0]
        actual = reconstruct_native(vm, instance, xlen) if native else reconstruct(vm, instance)
        if len(expected) != 65536 // (xlen // 8):
            raise ValueError(f"expected 64 KiB of RV{xlen} HEX")
        for index, (a, b) in enumerate(zip(actual, expected)):
            if a != b:
                raise ValueError(f"{kind.upper()}TCM init mismatch word={index:#x}: VM={a:08x}, HEX={b:08x}")
        raw = b"".join(word.to_bytes(xlen // 8, "little") for word in actual)
        results[kind + "tcm"] = {"bytes": len(raw), "drm_primitives": 16,
            "contents_sha256": hashlib.sha256(raw).hexdigest(),
            "hex_sha256": hashlib.sha256((args.project / f"firmware/{kind}mem.hex").read_bytes()).hexdigest()}
        print(f"PASS synthesized {kind.upper()}TCM init RV{xlen}: 65536 bytes, 16 DRM primitives, SHA256={hashlib.sha256(raw).hexdigest()}")
    if args.summary:
        # 只在两块 RAM 全部匹配后建立证据文件；已有报告不能被这次校验覆盖。
        with args.summary.open("x", encoding="utf-8") as output:
            json.dump({"status": "all synthesized TCM initial bytes match staged HEX",
                "xlen": xlen, "native_banks": native, "regions": results,
                "netlist_sha256": hashlib.sha256(netlist.read_bytes()).hexdigest(),
                "manifest_path": manifest_path.name,
                "manifest_sha256": hashlib.sha256(manifest_path.read_bytes()).hexdigest()},
                output, indent=2)
            output.write("\n")


if __name__ == "__main__":
    main()
