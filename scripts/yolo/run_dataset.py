#!/usr/bin/env python3
"""Execute tracked positive/empty images with the complete native INT8 C graph."""
import json
import math
import os
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts/yolo"))
from prepare_assets import prepare


def main():
    prepare()
    output = ROOT / "build/yolo/dataset"
    output.mkdir(parents=True, exist_ok=True)
    env = dict(os.environ, YOLO_NETWORK_OUT=str(output))
    subprocess.run(["bash", "scripts/demo/build_yolo_network.sh"], cwd=ROOT, env=env, check=True)
    cases = json.loads((ROOT / "tb/assets/yolo/cases.json").read_text())
    frozen = json.loads((ROOT / "tb/assets/yolo/expected-native.json").read_text())
    expected = {entry["case"]: entry for entry in frozen["results"]}
    results = []
    for case in cases:
        report = output / (case["name"] + ".json")
        subprocess.run([str(output / "yolo-network-native"), "--model",
                        str(ROOT / "software/yolo/assets" / case["model"]), "--image-rgb",
                        str(ROOT / "tb/assets/yolo" / case["image"]), "--output", str(report)],
                       cwd=ROOT, check=True, timeout=180)
        result = json.loads(report.read_text())
        classes = sorted(box["class_id"] for box in result["boxes"])
        if (result["convolutions"], result["nodes"], classes) != (83, 266, case["classes"]):
            raise ValueError(f"dataset mismatch: {case['name']}: {classes}")
        for actual, reference in zip(result["boxes"], expected[case["name"]]["boxes"]):
            if actual["class_id"] != reference["class_id"]:
                raise ValueError(f"detection order differs: {case['name']}")
            for name in ("score", "objectness", "class_probability"):
                if not math.isclose(actual[name], reference[name], abs_tol=1e-5, rel_tol=1e-5):
                    raise ValueError(f"detection {name} differs: {case['name']}")
            if any(not math.isclose(a, b, abs_tol=1e-3, rel_tol=1e-5)
                   for a, b in zip(actual["box_xyxy"], reference["box_xyxy"])):
                raise ValueError(f"box coordinates differ: {case['name']}")
        results.append(dict(case=case["name"], status="PASS", classes=classes))
    (output / "results.json").write_text(json.dumps(results, indent=2) + "\n")
    print(f"PASS YOLO tracked dataset: {len(results)} full C graph cases; no RTL or FPGA execution")


if __name__ == "__main__":
    main()
