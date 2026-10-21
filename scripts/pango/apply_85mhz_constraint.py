#!/usr/bin/env python3
"""Retarget a staged PDS project's board clock to 85 MHz for a constraint check.

This changes only the staged board_ddr.fdc and its manifest hash.  It does not
change the DDR IP configuration, the wrapper's CLOCK_HZ, the UART divisor, or the
actual board oscillator.  Results are a what-if STA target, not a board clock.
"""
from pathlib import Path
import argparse
import hashlib
import json
import re
import sys


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("project", type=Path, help="staged PDS project root")
    args = parser.parse_args()
    root = args.project.resolve()
    fdc = root / "board_ddr.fdc"
    manifest_path = root / "manifest.json"
    if not fdc.is_file() or not manifest_path.is_file():
        parser.error("project must contain board_ddr.fdc and manifest.json")
    text = fdc.read_text(encoding="utf-8")
    pattern = re.compile(
        r"create_clock -name \{ref_clk\} \[get_ports \{ref_clk_p\}\] "
        r"-period \{[0-9.]+\} -waveform \{[0-9. ]+\}")
    replacement = (
        "create_clock -name {ref_clk} [get_ports {ref_clk_p}] "
        "-period {11.7647} -waveform {0 5.88235}")
    new_text, count = pattern.subn(replacement, text)
    if count != 1:
        parser.error(f"expected exactly one ref_clk create_clock, found {count}")
    fdc.write_text(new_text, encoding="utf-8")
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    manifest["files"]["board_ddr.fdc"] = hashlib.sha256(fdc.read_bytes()).hexdigest()
    manifest["target_clock_hz"] = 85000000
    manifest["constraint_note"] = (
        "board ref_clk retargeted to 85 MHz after staging for a constraint-only STA; "
        "DDR IP, wrapper CLOCK_HZ, UART divisor and board oscillator remain 125 MHz")
    manifest_path.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    print(f"PASS retargeted {root} to 85 MHz (staged board_ddr.fdc only)")


if __name__ == "__main__":
    main()
