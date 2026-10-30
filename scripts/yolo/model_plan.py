#!/usr/bin/env python3
"""Check a saved YOLOX graph audit and plan NPU1 convolution tiles without importing torch.

This emits a convolution/asset plan. It does not export calibrated weights or execute
the non-convolution graph. The firmware keeps DETECT unavailable until those exist.
"""
import argparse
import hashlib
import json
from pathlib import Path


def sha(path):
    result = hashlib.sha256()
    with Path(path).open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            result.update(chunk)
    return result.hexdigest()


def conv_plan(row):
    ni, ci, ih, iw = row["input"]
    no, co, oh, ow = row["output"]
    kernel, stride = row["kernel"], row["stride"]
    if not (ni == no == 1 and row["groups"] == 1 and kernel in ([1, 1], [3, 3]) and
            stride in ([1, 1], [2, 2]) and 0 < ci <= 768 and 0 < co <= 768 and
            min(ih, iw, oh, ow) > 0 and max(ih, iw) <= 416):
        raise ValueError("unsupported convolution: " + row["name"])
    k, s = kernel[0], stride[0]
    padding = [p for p in range(k // 2 + 1)
               if (ih + 2 * p - k) // s + 1 == oh and (iw + 2 * p - k) // s + 1 == ow]
    if len(padding) != 1 or row["weight_elements"] != co * ci * k * k:
        raise ValueError("inconsistent convolution shape/weights: " + row["name"])
    side = (16 - k) // s + 1
    gy, gx, out_groups = (oh + side - 1) // side, (ow + side - 1) // side, (co + 15) // 16
    groups = (ci + 7) // 8
    return dict(name=row["name"], input=row["input"], output=row["output"],
                kernel=k, stride=s, pad=padding[0], input_channel_groups=groups, output_channel_blocks=out_groups,
                maximum_output_tile_side=side, spatial_tiles=[gy, gx],
                tile_commands=gy * gx * out_groups,
                max_activation_index=16 * 16 * groups - 1,
                max_weight_index=k * k * groups - 1,
                weight_staging_bytes_per_output_block=k * k * groups * 128,
                int32_output_bytes=co * oh * ow * 4,
                halo="CPU materializes global zero padding; NPU pad=0, bank0, raw INT32")


def make_plan(audit, lock, size):
    if audit["commit"] != lock["commit"] or audit["model"].lower() != lock["model"].lower():
        raise ValueError("model audit differs from pinned model/commit")
    if audit["source_sha256"] != lock["source_sha256"]:
        raise ValueError("model audit source hashes differ from lock")
    profile = next((p for p in audit["profiles"] if p["size"] == size), None)
    if profile is None:
        raise ValueError("requested input size is absent from audit")
    layers = [conv_plan(row) for row in profile["layers"]]
    if len(layers) != 83 or audit["module_counts"]["Conv2d"] != 83:
        raise ValueError("YOLOX-Tiny requires 83 saved convolution records")
    required = ["BGR/top-left resize/pad=114/CHW preprocessing",
                "Focus slicing and concatenation", "residual Add and Concat",
                "MaxPool 5/9/13 and nearest-neighbor Upsample", "BN-folded INT8 weights and scales",
                "activation calibration and SiLU requantization",
                "Sigmoid and detector Decode", "NMS and original-image coordinates",
                "83-layer tensor ownership/lifetimes and layer executor",
                "HDMI framebuffer reader and MS7210 output"]
    return dict(model=lock["model"], upstream_commit=lock["commit"], input_size=size,
                status="CONVOLUTION_PLAN_ONLY", detector_ready=False, hdmi_ready=False,
                saved_audit_mode=audit["mode"], convolution_count=len(layers),
                total_tile_commands=sum(row["tile_commands"] for row in layers),
                conv_int8_weight_bytes=audit["conv_weight_elements"],
                largest_int32_conv_output_bytes=max(row["int32_output_bytes"] for row in layers),
                required_before_detect=required, layers=layers)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--audit", type=Path, required=True)
    parser.add_argument("--model-lock", type=Path, required=True)
    parser.add_argument("--checkpoint", type=Path)
    parser.add_argument("--size", type=int, choices=(320, 416), default=416)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    lock = json.loads(args.model_lock.read_text())
    report = make_plan(json.loads(args.audit.read_text()), lock, args.size)
    report["inputs"] = {"audit_sha256": sha(args.audit), "model_lock_sha256": sha(args.model_lock)}
    if args.checkpoint:
        weight_hash = sha(args.checkpoint)
        if weight_hash != lock["weights_sha256"]:
            raise ValueError("checkpoint differs from official pinned weights")
        report["inputs"]["checkpoint_sha256"] = weight_hash
        report["inputs"]["checkpoint_bytes"] = args.checkpoint.stat().st_size
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps({key: value for key, value in report.items() if key != "layers"}, indent=2))


if __name__ == "__main__":
    main()
