#!/usr/bin/env python3
"""Check DRM reconstruction against independently packed memory images."""
from pathlib import Path
import json
import re
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
from scripts.pango.check_tcm_init import reconstruct, reconstruct_native


def fixture(xlen=32, native=True, primitive_width=None):
    lane_bits = xlen // 8 if native else 2
    primitive_width = primitive_width or lane_bits
    words = [(0x9e3779b97f4a7c15 * (index + 1)) & ((1 << xlen) - 1)
             for index in range(65536 // (xlen // 8))]
    blocks = []
    for bank in range(2 if native else 1):
        image = words[bank::2] if native else words
        for low in range(0, xlen, lane_bits):
            # 先构造厂商的 4096 个九位存储单元，parity 全置一以检验窄数据提取。
            cells = [256] * 4096
            for index, word in enumerate(image):
                cell = index // (8 // lane_bits)
                shift = (index % (8 // lane_bits)) * lane_bits
                cells[cell] |= ((word >> low) & ((1 << lane_bits) - 1)) << shift
            params = [f'.DATA_WIDTH_A({primitive_width})', '.RAM_MODE("SINGLE_PORT")', '.INIT_FILE("NONE")']
            for chunk in range(128):
                value = sum(cells[chunk * 32 + slot] << (9 * slot) for slot in range(32))
                params.append(f".INIT_{chunk:02X}(288'b{value:0288b})")
            if native:
                address_low = (xlen // 8).bit_length()
                address = (["1'b1"] +
                    [f"\\g_bank[{bank}].access.addr [{bit}]" for bit in range(15, address_low - 1, -1)] +
                    ["1'b1"] * (address_low - 1))
                data = [f"\\bank_data[{bank}] [{bit}]" for bit in range(low + lane_bits - 1, low - 1, -1)]
            else:
                address = ["1'b1"] + [f"\\request.addr [{bit}]" for bit in range(15, 1, -1)] + ["1'b1"]
                data = [f"\\response.rdata [{bit}]" for bit in range(low + 1, low - 1, -1)]
            data = [f"\\unused_{bit}_floating " for bit in range(35, lane_bits - 1, -1)] + data
            blocks.append("GTP_DRM36K_E1 /* fixture */ #(" + ",\n".join(params) +
                f") ram_{bank}_{low} (\n.ADDRA ({{" + ",".join(address) +
                "}),\n.DOA ({" + ",".join(data) + "}));")
    return "module fixture;\n" + "\n".join(blocks) + "\nendmodule\n fixture u_itcm ();\n", words


class TcmInitTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.native32, cls.words32 = fixture()
        cls.native64, cls.words64 = fixture(64)
        cls.legacy32, cls.old_words = fixture(native=False)

    def test_native_rv32_all_bytes(self):
        self.assertEqual(reconstruct_native(self.native32, "u_itcm", 32), self.words32)

    def test_native_rv64_x8_and_x9_all_bytes(self):
        for width in (8, 9):
            with self.subTest(primitive_width=width):
                vm = self.native64.replace(".DATA_WIDTH_A(8)", f".DATA_WIDTH_A({width})")
                self.assertEqual(reconstruct_native(vm, "u_itcm", 64), self.words64)

    def test_legacy_rv32_all_bytes(self):
        self.assertEqual(reconstruct(self.legacy32, "u_itcm"), self.old_words)

    def test_wrong_address_rejected(self):
        altered = self.native32.replace("\\g_bank[0].access.addr [3]", "\\g_bank[0].access.addr [2]", 1)
        with self.assertRaisesRegex(ValueError, "address mapping"):
            reconstruct_native(altered, "u_itcm", 32)

    def test_duplicate_output_lane_rejected(self):
        altered = self.native32
        for bit in range(4, 8):
            altered = altered.replace(f"\\bank_data[0] [{bit}]", f"\\bank_data[0] [{bit-4}]", 1)
        with self.assertRaisesRegex(ValueError, "data mapping"):
            reconstruct_native(altered, "u_itcm", 32)

    def test_missing_init_and_wrong_width_rejected(self):
        for altered in (re.sub(r"\.INIT_42\(288'b[01]{288}\)", "", self.native32, count=1),
                        self.native32.replace(".DATA_WIDTH_A(4)", ".DATA_WIDTH_A(2)", 1)):
            with self.subTest():
                with self.assertRaises(ValueError):
                    reconstruct_native(altered, "u_itcm", 32)

    def test_single_init_bit_changes_exact_address(self):
        match = re.search(r"\.INIT_00\(288'b([01]{288})\)", self.native32)
        start, end = match.span(1)
        bits = match[1][:-1] + str(1 - int(match[1][-1]))
        altered = self.native32[:start] + bits + self.native32[end:]
        actual = reconstruct_native(altered, "u_itcm", 32)
        self.assertEqual([index for index, pair in enumerate(zip(actual, self.words32))
                          if pair[0] != pair[1]], [0])
        self.assertEqual(actual[0] ^ self.words32[0], 1)

    def test_cli_summary_only_after_both_images_match(self):
        with tempfile.TemporaryDirectory() as temporary:
            project = Path(temporary)
            (project / "firmware").mkdir()
            (project / "manifest.json").write_text(json.dumps({"xlen": 32, "core_backend": "scoreboard"}))
            for kind in ("i", "d"):
                (project / f"firmware/{kind}mem.hex").write_text("".join(f"{word:08x}\n" for word in self.words32))
            vm = project / "test.vm"
            vm.write_text(self.native32 + " fixture u_dtcm ();\n")
            summary = project / "result.json"
            command = [sys.executable, "scripts/pango/check_tcm_init.py", str(project),
                       "--netlist", str(vm), "--summary", str(summary)]
            result = subprocess.run(command, text=True, capture_output=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            evidence = json.loads(summary.read_text())
            self.assertEqual(evidence["regions"]["itcm"]["bytes"], 65536)
            self.assertEqual(evidence["regions"]["dtcm"]["bytes"], 65536)
            summary.unlink()
            path = project / "firmware/dmem.hex"
            path.write_text("00000000\n" + path.read_text().split("\n", 1)[1])
            result = subprocess.run(command, text=True, capture_output=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("DTCM init mismatch", result.stderr)
            self.assertFalse(summary.exists())


if __name__ == "__main__":
    unittest.main()
