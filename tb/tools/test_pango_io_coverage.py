#!/usr/bin/env python3
"""Pure-Python warning classification checks; no synthetic STA closure claims."""
import json
from pathlib import Path
import tempfile
import unittest

from scripts.pango.io_coverage import DDR_INPUTS, DDR_OUTPUTS, audit, classify_io_gaps


class BoardIOCoverageTests(unittest.TestCase):
    def gaps(self):
        return dict(no_input_delay=sorted(DDR_INPUTS | {"board_reset_n", "ref_clk_n", "uart_rxd"}),
                    no_output_delay=sorted(DDR_OUTPUTS | {"uart_txd", "ddr_ready_led"}))

    def test_board_warning_inventory_is_classified_without_closure_claim(self):
        result = classify_io_gaps(self.gaps())
        self.assertEqual(result["raw_warning_counts"], dict(no_input_delay=35, no_output_delay=73))
        self.assertEqual(result["role_counts"]["ddr_ip"], 103)
        self.assertEqual(result["status"], "CLASSIFIED_NOT_TIMING_CLOSED")
        self.assertFalse(result["timing_closure_claim"])
        self.assertEqual(result["generated_constraints"], [])
        self.assertEqual(result["unclassified"], [])

    def test_unknown_wrong_direction_and_out_of_range_ports_are_not_waived(self):
        gaps = self.gaps()
        gaps["no_input_delay"] += ["new_sync_input", "mem_dq[32]", "uart_txd"]
        result = classify_io_gaps(gaps)
        self.assertEqual(result["status"], "UNCLASSIFIED_IO_GAPS")
        self.assertEqual({entry["port"] for entry in result["unclassified"]},
                         {"new_sync_input", "mem_dq[32]", "uart_txd"})

    def test_duplicate_and_missing_warning_lists_are_rejected(self):
        gaps = self.gaps()
        gaps["no_input_delay"].append("uart_rxd")
        with self.assertRaises(ValueError):
            classify_io_gaps(gaps)
        with self.assertRaises(ValueError):
            classify_io_gaps(dict(no_input_delay=[]))

    def test_fewer_warnings_do_not_invent_or_require_fake_delays(self):
        result = classify_io_gaps(dict(no_input_delay=[], no_output_delay=[]))
        self.assertFalse(result["timing_closure_claim"])
        self.assertEqual(result["generated_constraints"], [])
        self.assertTrue(result["pending_checks"])

    def test_native_summary_identity_and_route_input_are_separate_checks(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            project = root / "native"
            project.mkdir()
            manifest = dict(source_commit="frozen-source", files={})
            (project / "manifest.json").write_text(json.dumps(manifest))
            (project / "compile.tcl").write_text("add_constraint {board_ddr.fdc}\n")
            (project / "board_ddr.fdc").write_text("create_clock -name ref_clk\n")
            summary = dict(project=str(project), source_commit="frozen-source", io_delay_gaps=self.gaps())
            summary_path = root / "summary.json"
            summary_path.write_text(json.dumps(summary))
            result = audit(project, summary_path)
            self.assertEqual(result["route_input_status"], "MISSING_GENERATED_DDR_RCF_INPUT")
            self.assertEqual(result["constraint_inputs"]["board_ddr.fdc"]["command_counts"], {"create_clock": 1})
            (project / "compile.tcl").write_text("add_constraint {board_ddr.rcf}\n")
            self.assertEqual(audit(project, summary_path)["route_input_status"], "LOADED_INPUT_NOT_ROUTE_PROOF")
            summary["source_commit"] = "different-source"
            summary_path.write_text(json.dumps(summary))
            with self.assertRaisesRegex(ValueError, "source commits differ"):
                audit(project, summary_path)
            summary["project"] = str(root / "other-project")
            summary_path.write_text(json.dumps(summary))
            with self.assertRaisesRegex(ValueError, "different native project"):
                audit(project, summary_path)


if __name__ == "__main__":
    unittest.main()
