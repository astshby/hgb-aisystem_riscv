#!/usr/bin/env python3
"""Reject a wrong routing claim against an actual, previously checked elaboration."""
import argparse
from pathlib import Path
import subprocess
import sys


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("tree", type=Path)
    parser.add_argument("--profile", choices=("full", "lite"), required=True)
    parser.add_argument("--ddr-bytes", choices=("0", "65536"), required=True)
    parser.add_argument("--xlen", choices=("32", "64"), required=True)
    parser.add_argument("--local-tcm", type=int, choices=(0, 1), required=True)
    args = parser.parse_args()
    checker = Path(__file__).resolve().parents[2] / "scripts/verilator/check_soc_profile_structure.py"
    # 不改 JSON 或 DUT：故意将同一份真实 elaboration 的模式声明反转。
    result = subprocess.run(
        [sys.executable, "-B", str(checker), str(args.tree), "--profile", args.profile,
         "--ddr-bytes", args.ddr_bytes, "--xlen", args.xlen,
         "--local-tcm", str(1 - args.local_tcm)],
        text=True, capture_output=True, check=False)
    assert result.returncode != 0, "wrong LOCAL_TCM_ENABLE claim unexpectedly passed"
    assert "JSON was elaborated for a different LOCAL_TCM_ENABLE" in result.stderr, \
        f"negative test failed for an unrelated reason: {result.stderr}"
    print(f"PASS soc profile structure wrong-local rejected RV{args.xlen} "
          f"profile={args.profile} actual_local={args.local_tcm} DDR_BYTES={args.ddr_bytes}")


if __name__ == "__main__":
    main()
