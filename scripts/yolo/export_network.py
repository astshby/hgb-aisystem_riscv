#!/usr/bin/env python3
"""Export the pinned full YOLOX-Tiny graph and real weights without importing torch.

The original BN parameters remain separate. Convolutions use per-output symmetric
INT8 weights; activations are dynamically quantized by the C runtime. Only the
official SHA-locked checkpoint is deserialized, through a four-global whitelist.
"""
import argparse
from collections import Counter, OrderedDict
from dataclasses import dataclass
import hashlib
import io
import json
import os
from pathlib import Path
import pickle
import struct
import subprocess
import zipfile
import zlib

for _name in ("OPENBLAS_NUM_THREADS", "OMP_NUM_THREADS", "MKL_NUM_THREADS"):
    os.environ[_name] = "1"
import numpy as np

PIN = "6ddff4824372906469a7fae2dc3206c7aa4bbaee"
WEIGHTS = "9de513de589ac98bb92d3bca53b5af7b9acfa9b0bacb831f7999d0f7afaee8f0"
NONE = 0xFFFFFFFF
MAGIC = b"YOLONET1"
HEADER = struct.Struct("<8s30I")
TENSOR = struct.Struct("<8I")
NODE = struct.Struct("<16I")
CONV, BN, SILU, FOCUS, ADD, CONCAT, MAXPOOL, UPSAMPLE, SIGMOID = range(1, 10)
OP_NAMES = dict(enumerate(("conv", "bn", "silu", "focus", "add", "concat", "maxpool", "upsample", "sigmoid"), 1))


def sha(path):
    digest = hashlib.sha256()
    with Path(path).open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


@dataclass(frozen=True)
class Storage:
    dtype: str
    key: str
    count: int


@dataclass(frozen=True)
class TensorRef:
    storage: Storage
    offset: int
    shape: tuple
    stride: tuple


def rebuild_tensor(storage, offset, shape, stride, *unused):
    if not isinstance(storage, Storage) or not isinstance(offset, int) or offset < 0:
        raise ValueError("invalid tensor storage metadata")
    if not isinstance(shape, tuple) or not isinstance(stride, tuple) or len(shape) != len(stride):
        raise ValueError("invalid tensor shape/stride metadata")
    if any(not isinstance(v, int) or v < 0 for v in (*shape, *stride)):
        raise ValueError("negative or non-integral shape/stride")
    return TensorRef(storage, offset, shape, stride)


class MetadataUnpickler(pickle.Unpickler):
    """No torch objects, imports, storage constructors or arbitrary pickle globals."""
    def find_class(self, module, name):
        allowed = {("collections", "OrderedDict"): OrderedDict,
                   ("torch._utils", "_rebuild_tensor_v2"): rebuild_tensor,
                   ("torch", "FloatStorage"): "<f4", ("torch", "LongStorage"): "<i8"}
        if (module, name) not in allowed:
            raise ValueError(f"checkpoint global rejected: {module}.{name}")
        return allowed[module, name]

    def persistent_load(self, identity):
        if not isinstance(identity, tuple) or len(identity) != 5 or identity[0] != "storage":
            raise ValueError("checkpoint persistent identity rejected")
        _, dtype, key, location, count = identity
        if dtype not in ("<f4", "<i8") or not isinstance(key, str) or not key.isdecimal() or \
                not isinstance(count, int) or not 0 <= count <= 8 * 1024 * 1024 or \
                not isinstance(location, str):
            raise ValueError("checkpoint storage identity rejected")
        return Storage(dtype, key, count)


class Checkpoint:
    def __init__(self, path, expected=WEIGHTS):
        self.path = Path(path)
        # No pickle opcode is read before the official digest has matched.
        if expected != WEIGHTS or sha(self.path) != WEIGHTS:
            raise ValueError("checkpoint differs from the pinned official weight SHA256")
        self.archive = zipfile.ZipFile(self.path)
        metadata = self.archive.read("archive/data.pkl")
        if len(metadata) > 1024 * 1024:
            raise ValueError("checkpoint metadata exceeds bound")
        state = MetadataUnpickler(io.BytesIO(metadata)).load()
        self.model = state["model"]
        if not isinstance(self.model, OrderedDict) or len(self.model) != 462:
            raise ValueError("pinned Tiny state must have 462 model entries")

    def shape(self, name):
        tensor = self.model[name]
        if not isinstance(tensor, TensorRef):
            raise ValueError("state entry is not tensor metadata: " + name)
        return tensor.shape

    def read(self, name):
        tensor = self.model[name]
        expected_stride, count = [], 1
        for size in reversed(tensor.shape):
            expected_stride.insert(0, count)
            count *= size
        if tensor.storage.dtype != "<f4" or tensor.offset != 0 or \
                tuple(expected_stride) != tensor.stride or count != tensor.storage.count:
            raise ValueError("expected contiguous whole FP32 parameter: " + name)
        data = self.archive.read("archive/data/" + tensor.storage.key)
        if len(data) != count * 4:
            raise ValueError("parameter storage length mismatch: " + name)
        result = np.frombuffer(data, dtype="<f4").reshape(tensor.shape)
        if not np.isfinite(result).all():
            raise ValueError("non-finite model parameter: " + name)
        return result

    def close(self):
        self.archive.close()


def quantize_weights(weight):
    scales = np.maximum(np.max(np.abs(weight), axis=(1, 2, 3)) / np.float32(127), np.float32(1e-12))
    quantized = np.clip(np.rint(weight / scales[:, None, None, None]), -127, 127).astype(np.int8)
    return quantized, scales.astype("<f4", copy=False)


class Graph:
    def __init__(self, model, size):
        self.model, self.size = model, size
        self.tensors = [dict(name="input.bgr", shape=[3, size, size], flags=1, last_use=0)]
        self.nodes, self.heads = [], []

    def shape(self, tensor):
        return self.tensors[tensor]["shape"]

    def emit(self, kind, name, inputs, shape, p=(0, 0, 0, 0), params=()):
        output = len(self.tensors)
        self.tensors.append(dict(name=name, shape=list(shape), flags=0, last_use=len(self.nodes)))
        self.nodes.append(dict(op=kind, name=name, output=output, inputs=list(inputs), p=list(p), params=list(params)))
        return output

    def conv(self, name, tensor, stride=1):
        co, ci, kh, kw = self.model.shape(name + ".weight")
        channels, height, width = self.shape(tensor)
        if channels != ci or kh != kw or kh not in (1, 3) or stride not in (1, 2):
            raise ValueError("unsupported or disconnected convolution: " + name)
        pad = kh // 2
        shape = [co, (height + 2 * pad - kh) // stride + 1, (width + 2 * pad - kw) // stride + 1]
        return self.emit(CONV, name, [tensor], shape, (kh, stride, pad, 0),
                         [name + ".weight", name + ".bias" if name + ".bias" in self.model.model else None])

    def base(self, prefix, tensor, stride=1):
        x = self.conv(prefix + ".conv", tensor, stride)
        channels = self.shape(x)[0]
        names = [prefix + ".bn." + suffix for suffix in ("weight", "bias", "running_mean", "running_var")]
        if any(self.model.shape(name) != (channels,) for name in names):
            raise ValueError("BatchNorm channel mismatch: " + prefix)
        x = self.emit(BN, prefix + ".bn", [x], self.shape(x), params=names)
        return self.emit(SILU, prefix + ".act", [x], self.shape(x))

    def cat(self, name, inputs):
        shape = self.shape(inputs[0]).copy()
        if len(inputs) > 4 or any(self.shape(t)[1:] != shape[1:] for t in inputs):
            raise ValueError("invalid concat: " + name)
        shape[0] = sum(self.shape(t)[0] for t in inputs)
        return self.emit(CONCAT, name, inputs, shape)

    def bottleneck(self, prefix, tensor, shortcut):
        x = self.base(prefix + ".conv1", tensor)
        x = self.base(prefix + ".conv2", x)
        if shortcut:
            if self.shape(x) != self.shape(tensor):
                raise ValueError("residual shape mismatch")
            x = self.emit(ADD, prefix + ".add", [x, tensor], self.shape(x))
        return x

    def csp(self, prefix, tensor, repeats, shortcut=True):
        # Preserve the source's conv1, conv2, m order, including branch lifetimes.
        left = self.base(prefix + ".conv1", tensor)
        right = self.base(prefix + ".conv2", tensor)
        for index in range(repeats):
            left = self.bottleneck(prefix + f".m.{index}", left, shortcut)
        return self.base(prefix + ".conv3", self.cat(prefix + ".concat", [left, right]))

    def spp(self, prefix, tensor):
        x = self.base(prefix + ".conv1", tensor)
        values = [x]
        for index, kernel in enumerate((5, 9, 13)):
            values.append(self.emit(MAXPOOL, prefix + f".m.{index}", [x], self.shape(x), (kernel, 1, kernel // 2, 0)))
        return self.base(prefix + ".conv2", self.cat(prefix + ".concat", values))

    def upsample(self, name, tensor):
        c, h, w = self.shape(tensor)
        return self.emit(UPSAMPLE, name, [tensor], [c, h * 2, w * 2], (2, 0, 0, 0))

    def build(self):
        prefix = "backbone.backbone"
        x = self.emit(FOCUS, prefix + ".stem.focus", [0], [12, self.size // 2, self.size // 2])
        x = self.base(prefix + ".stem.conv", x)
        features = []
        for stage, repeats in ((2, 1), (3, 3), (4, 3), (5, 1)):
            x = self.base(prefix + f".dark{stage}.0", x, 2)
            if stage == 5:
                x = self.spp(prefix + ".dark5.1", x)
                x = self.csp(prefix + ".dark5.2", x, repeats, False)
            else:
                x = self.csp(prefix + f".dark{stage}.1", x, repeats)
            if stage >= 3:
                features.append(x)
        x2, x1, x0 = features
        fpn0 = self.base("backbone.lateral_conv0", x0)
        x = self.cat("backbone.topdown0.concat", [self.upsample("backbone.upsample.0", fpn0), x1])
        x = self.csp("backbone.C3_p4", x, 1, False)
        fpn1 = self.base("backbone.reduce_conv1", x)
        x = self.cat("backbone.topdown1.concat", [self.upsample("backbone.upsample.1", fpn1), x2])
        pan2 = self.csp("backbone.C3_p3", x, 1, False)
        x = self.base("backbone.bu_conv2", pan2, 2)
        pan1 = self.csp("backbone.C3_n3", self.cat("backbone.bottomup0.concat", [x, fpn1]), 1, False)
        x = self.base("backbone.bu_conv1", pan1, 2)
        pan0 = self.csp("backbone.C3_n4", self.cat("backbone.bottomup1.concat", [x, fpn0]), 1, False)
        for level, feature in enumerate((pan2, pan1, pan0)):
            stem = self.base(f"head.stems.{level}", feature)
            cls = self.base(f"head.cls_convs.{level}.0", stem)
            cls = self.base(f"head.cls_convs.{level}.1", cls)
            cls = self.conv(f"head.cls_preds.{level}", cls)
            reg_feature = self.base(f"head.reg_convs.{level}.0", stem)
            reg_feature = self.base(f"head.reg_convs.{level}.1", reg_feature)
            reg = self.conv(f"head.reg_preds.{level}", reg_feature)
            obj = self.conv(f"head.obj_preds.{level}", reg_feature)
            obj = self.emit(SIGMOID, f"head.obj_sigmoid.{level}", [obj], self.shape(obj))
            cls = self.emit(SIGMOID, f"head.cls_sigmoid.{level}", [cls], self.shape(cls))
            self.heads.append(self.cat(f"head.output.{level}", [reg, obj, cls]))
        for index, node in enumerate(self.nodes):
            for tensor in node["inputs"]:
                self.tensors[tensor]["last_use"] = index
        for tensor in self.heads:
            self.tensors[tensor]["flags"] = 2
            self.tensors[tensor]["last_use"] = NONE
        return self

    def verify(self, audit):
        profile = next(p for p in audit["profiles"] if p["size"] == self.size)
        convs = [node for node in self.nodes if node["op"] == CONV]
        if len(convs) != 83:
            raise ValueError("complete Tiny graph must have 83 convolutions")
        for node, reference in zip(convs, profile["layers"]):
            actual = dict(name=node["name"], input=[1, *self.shape(node["inputs"][0])],
                          output=[1, *self.shape(node["output"])], kernel=[node["p"][0]] * 2,
                          stride=[node["p"][1]] * 2)
            if any(actual[key] != reference[key] for key in actual):
                raise ValueError("graph differs from saved upstream audit: " + node["name"])
        if [self.shape(t) for t in self.heads] != [[85, self.size // s, self.size // s] for s in (8, 16, 32)]:
            raise ValueError("head shape mismatch")

    def peak_live_bytes(self):
        live = {0: int(np.prod(self.shape(0))) * 4}
        peak = live[0]
        for index, node in enumerate(self.nodes):
            live[node["output"]] = int(np.prod(self.shape(node["output"]))) * 4
            peak = max(peak, sum(live.values()))
            for tensor in list(live):
                if self.tensors[tensor]["last_use"] == index:
                    del live[tensor]
        return peak


def write_binary(graph, path):
    tensor_offset = HEADER.size
    node_offset = tensor_offset + len(graph.tensors) * TENSOR.size
    data_offset = node_offset + len(graph.nodes) * NODE.size
    data = bytearray()
    node_records, layers = [], []

    def blob(value):
        data.extend(b"\0" * ((-len(data)) % 4))
        offset = data_offset + len(data)
        data.extend(value)
        return offset

    for node in graph.nodes:
        offsets = [0] * 4
        if node["op"] == CONV:
            offsets[2] = NONE
            weight, bias = node["params"]
            quantized, scales = quantize_weights(graph.model.read(weight))
            weight_data = quantized.tobytes(order="C")
            offsets[0], offsets[1] = blob(weight_data), blob(scales.tobytes())
            if bias is not None:
                offsets[2] = blob(graph.model.read(bias).tobytes())
            layers.append(dict(name=node["name"], weight_int8_sha256=hashlib.sha256(weight_data).hexdigest(),
                               weight_offset=offsets[0], weight_bytes=len(weight_data),
                               scales_offset=offsets[1], bias_offset=offsets[2]))
        elif node["op"] == BN:
            offsets = [blob(graph.model.read(name).tobytes()) for name in node["params"]]
        node_records.append(NODE.pack(node["op"], node["output"], len(node["inputs"]),
                                      *(node["inputs"] + [NONE] * (4 - len(node["inputs"]))),
                                      *node["p"], *offsets, 0))
    tensors = b"".join(TENSOR.pack(*tensor["shape"], tensor["last_use"], tensor["flags"], 0, 0, 0)
                       for tensor in graph.tensors)
    payload = tensors + b"".join(node_records) + data
    fields = [1, HEADER.size + len(payload), len(graph.tensors), len(graph.nodes), 0, *graph.heads,
              tensor_offset, node_offset, data_offset, zlib.crc32(payload), 3, graph.size, graph.size] + [0] * 15
    path.write_bytes(HEADER.pack(MAGIC, *fields) + payload)
    return dict(file=path.name, bytes=path.stat().st_size, sha256=sha(path), payload_crc32=zlib.crc32(payload),
                data_bytes=len(data), peak_live_tensor_bytes=graph.peak_live_bytes(), layers=layers)


def export(model_root, output, size=416):
    model_root, output = Path(model_root), Path(output)
    lock_path = model_root / "config/yolox-tiny.lock.json"
    audit_path = model_root / "build/yolox-tiny-audit.json"
    checkpoint_path = model_root / "build/models/yolox_tiny.pth"
    upstream = model_root / "build/upstream/YOLOX"
    lock, audit = json.loads(lock_path.read_text()), json.loads(audit_path.read_text())
    if lock["commit"] != PIN or lock["weights_sha256"] != WEIGHTS or \
            lock["model"] != "YOLOX-Tiny" or audit["commit"] != PIN or audit["source_sha256"] != lock["source_sha256"]:
        raise ValueError("model lock/audit is not the pinned Tiny source")
    for name, digest in lock["source_sha256"].items():
        if sha(upstream / name) != digest:
            raise ValueError("upstream source hash mismatch: " + name)
    checkpoint = Checkpoint(checkpoint_path)
    try:
        graph = Graph(checkpoint, size).build()
        graph.verify(audit)
        output.parent.mkdir(parents=True, exist_ok=True)
        result = write_binary(graph, output)
    finally:
        checkpoint.close()
    report = dict(schema=1, model="YOLOX-Tiny", input_size=size, upstream_commit=PIN,
                  weights_sha256=WEIGHTS, source_sha256=lock["source_sha256"],
                  exporter_sha256=sha(Path(__file__)), model_lock_sha256=sha(lock_path), audit_sha256=sha(audit_path),
                  torch_imported=False, numpy=np.__version__, binary=result,
                  node_count=len(graph.nodes), tensor_count=len(graph.tensors),
                  operators={OP_NAMES[k]: v for k, v in sorted(Counter(n["op"] for n in graph.nodes).items())},
                  input="preprocessed BGR888 CHW converted to float32, pad114, no /255", head_ids=graph.heads,
                  quantization="per-output weight symmetric INT8 [-127,127], ties-even; dynamic input scale at runtime",
                  batchnorm="74 separate original BN parameter sets, eps=1e-3; weights are not folded",
                  scope="Complete 83-convolution graph/assets; execution and detection are validated separately",
                  tensors=graph.tensors, nodes=graph.nodes)
    root = Path(__file__).resolve().parents[2]
    report["source_branch"] = subprocess.check_output(["git", "-C", str(root), "branch", "--show-current"], text=True).strip()
    report["source_commit"] = subprocess.check_output(["git", "-C", str(root), "rev-parse", "HEAD"], text=True).strip()
    report["command"] = ["python3", "scripts/yolo/export_network.py", "--model-root", str(model_root),
                         "--size", str(size), "--output", str(output)]
    output.with_suffix(".json").write_text(json.dumps(report, indent=2) + "\n")
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--model-root", type=Path, required=True)
    parser.add_argument("--size", type=int, choices=(320, 416), default=416)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    report = export(args.model_root, args.output, args.size)
    print(json.dumps({key: value for key, value in report.items() if key not in ("tensors", "nodes", "binary", "source_sha256")}, indent=2))
    print(json.dumps({key: value for key, value in report["binary"].items() if key != "layers"}, indent=2))


if __name__ == "__main__":
    main()
