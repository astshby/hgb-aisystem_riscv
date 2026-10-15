#!/usr/bin/env python3
"""Compare saved Pango DDR IP DQ pin parameters with the board FDC.

This checks only DQ placement metadata; it does not validate PHY timing,
other DDR signals, memory-part equivalence, or the generated netlist.
"""
import argparse
from pathlib import Path
import re
import xml.etree.ElementTree as ET

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("idf", type=Path)
parser.add_argument("--fdc", type=Path, default=Path("scripts/pango/mes2l676_200hp.fdc"))
args = parser.parse_args()
params = {p.findtext("name"): p.findtext("value")
          for p in ET.parse(args.idf).findall(".//param")}
matches = re.findall(r"\{p:mem_dq\[(\d+)\]\} \{PAP_IO_LOC\} \{(\w+)\}",
                     args.fdc.read_text(encoding="utf-8"))
if len(matches) != 32 or {int(n) for n, _ in matches} != set(range(32)):
    raise SystemExit("FAIL board FDC must contain exactly one LOC for every DQ[0:31]")
errors = 0
for index, pin in sorted(matches, key=lambda item: int(item[0])):
    saved = params.get(f"PAD_DQ{index}")
    if saved != pin:
        print(f"FAIL DQ[{index}]: IDF={saved!r}, board={pin}")
        errors += 1
print(f"INFO Active Memory Part={params.get('DDR_MEM_PART')!r}; "
      f"CUSTOMIZE_MEM={params.get('CUSTOMIZE_MEM')!r}; equivalence not checked")
print(f"{'FAIL' if errors else 'PASS'} DDR IP DQ metadata: {32-errors}/32 match")
raise SystemExit(bool(errors))
