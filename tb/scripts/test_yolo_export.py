"""No-Torch checkpoint/quantization/ABI tests and optional pinned real-model export checks."""
import importlib.util
import io
import json
import os
from pathlib import Path
import struct
import sys
import tempfile
import unittest
from unittest import mock
import zlib

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("yolo_export_network", ROOT / "scripts/yolo/export_network.py")
exporter = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = exporter
SPEC.loader.exec_module(exporter)


class ExportUnitTests(unittest.TestCase):
    def test_binary_record_sizes(self):
        self.assertEqual((exporter.HEADER.size, exporter.TENSOR.size, exporter.NODE.size), (128, 32, 64))

    def test_reject_executable_pickle_global(self):
        with self.assertRaisesRegex(ValueError, "global rejected"):
            exporter.MetadataUnpickler(io.BytesIO(b"cos\nsystem\n.")).load()

    def test_reject_other_torch_globals(self):
        with self.assertRaisesRegex(ValueError, "global rejected"):
            exporter.MetadataUnpickler(io.BytesIO(b"ctorch\nTensor\n.")).load()

    def test_weight_digest_before_any_unpickle(self):
        with tempfile.NamedTemporaryFile() as bad:
            bad.write(b"not the official checkpoint"); bad.flush()
            with mock.patch.object(exporter, "MetadataUnpickler") as reader:
                with self.assertRaisesRegex(ValueError, "official weight SHA"):
                    exporter.Checkpoint(bad.name)
                reader.assert_not_called()

    def test_tensor_metadata_never_allocates_storage(self):
        storage = exporter.Storage("<f4", "9", 12)
        tensor = exporter.rebuild_tensor(storage, 0, (3, 4), (4, 1), False, {})
        self.assertEqual(tensor.shape, (3, 4))
        self.assertIs(tensor.storage, storage)
        for arguments in ((storage, -1, (3, 4), (4, 1)),
                          (storage, 0, (3, 4), (1,)), (storage, 0, (-1, 4), (4, 1))):
            with self.assertRaises(ValueError):
                exporter.rebuild_tensor(*arguments)

    def test_ties_even_and_zero_weight_channels(self):
        np = exporter.np
        weights = np.array([[[[-127, -2.5, -1.5, -0.5, 0.5, 1.5, 2.5, 127]]],
                            [[[0, 0, 0, 0, 0, 0, 0, 0]]]], dtype=np.float32)
        quantized, scales = exporter.quantize_weights(weights)
        self.assertEqual(quantized[0].reshape(-1).tolist(), [-127, -2, -2, 0, 0, 2, 2, 127])
        self.assertEqual(quantized[1].reshape(-1).tolist(), [0] * 8)
        self.assertEqual(scales.tolist(), [1, np.float32(1e-12)])

    def test_disconnected_conv_is_rejected(self):
        class ShapeOnly:
            model = {}
            def shape(self, name):
                return 16, 4, 3, 3
        graph = exporter.Graph(ShapeOnly(), 416)
        with self.assertRaisesRegex(ValueError, "disconnected"):
            graph.conv("wrong", 0)

    def test_no_torch_module_was_imported(self):
        self.assertFalse(any(name == "torch" or name.startswith("torch.") for name in sys.modules))


@unittest.skipUnless(os.environ.get("YDM_MODEL_ROOT"), "set YDM_MODEL_ROOT for the pinned real model")
class RealModelExportTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.model_root = Path(os.environ["YDM_MODEL_ROOT"])
        cls.output = Path(os.environ.get("YDM_EXPORT_TEST_OUT", ROOT / "build/yolo/export-tests"))
        cls.output.mkdir(parents=True, exist_ok=True)
        cls.report = exporter.export(cls.model_root, cls.output / "unit-416.bin", 416)
        cls.binary = (cls.output / "unit-416.bin").read_bytes()

    def test_all_83_quantized_weight_hashes_match_executed_rtl_reference(self):
        reference = json.loads((self.model_root / "build/dog-adam128.json").read_text())
        expected = {row["name"]: row["weight_int8_sha256"] for row in reference["layers"]}
        actual = {row["name"]: row["weight_int8_sha256"] for row in self.report["binary"]["layers"]}
        self.assertEqual(len(actual), 83)
        self.assertEqual(actual, expected)

    def test_complete_graph_and_three_heads(self):
        self.assertEqual(self.report["node_count"], 266)
        self.assertEqual(self.report["tensor_count"], 267)
        self.assertEqual(self.report["operators"], dict(conv=83, bn=74, silu=74, focus=1, add=7,
                                                        concat=16, maxpool=3, upsample=2, sigmoid=6))
        for tensor, side in zip(self.report["head_ids"], (52, 26, 13)):
            value = self.report["tensors"][tensor]
            self.assertEqual((value["shape"], value["flags"], value["last_use"]), ([85, side, side], 2, 0xFFFFFFFF))

    def test_file_header_crc_and_topology(self):
        magic, *header = exporter.HEADER.unpack_from(self.binary)
        self.assertEqual(magic, b"YOLONET1")
        self.assertEqual(header[1], len(self.binary))
        self.assertEqual(header[11], zlib.crc32(self.binary[128:]))
        last_use = [0] * header[2]
        for index in range(header[3]):
            node = exporter.NODE.unpack_from(self.binary, header[9] + index * 64)
            self.assertEqual(node[1], index + 1)
            self.assertEqual(node[15], 0)
            for value in node[3:3 + node[2]]:
                self.assertLess(value, node[1])
                last_use[value] = index
            if node[0] == exporter.CONV:
                self.assertEqual(node[14], 0)
                for offset in node[11:14]:
                    if offset != 0xFFFFFFFF:
                        self.assertGreaterEqual(offset, header[10])
                        self.assertEqual(offset % 4, 0)
        for index, tensor in enumerate(self.report["tensors"]):
            if tensor["flags"] != 2:
                self.assertEqual(last_use[index], tensor["last_use"])

    def test_original_batchnorm_parameters_are_preserved(self):
        checkpoint = exporter.Checkpoint(self.model_root / "build/models/yolox_tiny.pth")
        try:
            for index, row in enumerate(self.report["nodes"]):
                if row["op"] != exporter.BN:
                    continue
                node = exporter.NODE.unpack_from(self.binary, 128 + 267 * 32 + index * 64)
                for name, offset in zip(row["params"], node[11:15]):
                    expected = checkpoint.read(name).tobytes()
                    self.assertEqual(self.binary[offset:offset + len(expected)], expected)
        finally:
            checkpoint.close()

    def test_export_is_deterministic_and_320_graph_is_complete(self):
        repeated = exporter.export(self.model_root, self.output / "unit-repeat-416.bin", 416)
        small = exporter.export(self.model_root, self.output / "unit-320.bin", 320)
        self.assertEqual(repeated["binary"]["sha256"], self.report["binary"]["sha256"])
        self.assertEqual([t["weight_int8_sha256"] for t in small["binary"]["layers"]],
                         [t["weight_int8_sha256"] for t in self.report["binary"]["layers"]])
        self.assertEqual([small["tensors"][t]["shape"] for t in small["head_ids"]],
                         [[85, 40, 40], [85, 20, 20], [85, 10, 10]])


if __name__ == "__main__":
    unittest.main()
