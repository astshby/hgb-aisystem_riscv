#!/usr/bin/env python3
"""Convert byte-oriented GNU objcopy Verilog hex into fixed-width readmemh words."""

import argparse
from pathlib import Path


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("input", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--word-bytes", type=int, required=True)
    parser.add_argument("--depth", type=int, default=4096)
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    memory = bytearray(args.word_bytes * args.depth)
    address = 0

    for token in args.input.read_text(encoding="ascii").split():
        if token.startswith("@"):
            address = int(token[1:], 16)
            continue
        if len(token) != 2:
            raise ValueError(f"unexpected byte token: {token}")
        if address >= len(memory):
            raise ValueError(f"image address 0x{address:x} exceeds memory size")
        memory[address] = int(token, 16)
        address += 1

    with args.output.open("w", encoding="ascii") as output:
        for offset in range(0, len(memory), args.word_bytes):
            word = memory[offset : offset + args.word_bytes]
            output.write(bytes(reversed(word)).hex() + "\n")


if __name__ == "__main__":
    main()
