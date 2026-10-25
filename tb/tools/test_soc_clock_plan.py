#!/usr/bin/env python3
"""Verify offline clock candidates reject board misapplication and preserve source files."""
import hashlib
import json
from pathlib import Path
import shutil
import sys
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO))
from scripts.pango.plan_soc_clocks import SOURCES, build_plan, check_topology, clock_profiles, write_plan
from scripts.pango.prepare_project import verify_default_board_clocks


class ClockPlanTest(unittest.TestCase):
    def setUp(self):
        self.source = {name: (REPO / name).read_text() for name in SOURCES}

    def test_all_profiles_have_four_clocks_without_exceptions(self):
        for profile in ("C0", "C1", "C2", "C3", "C4", "floor85"):
            with self.subTest(profile=profile):
                report, fdc = build_plan(REPO, profile)
                commands = [line for line in fdc.splitlines() if line and not line.startswith("#")]
                self.assertEqual(len(commands), 4)
                self.assertTrue(all(line.startswith("create_clock ") for line in commands))
                self.assertNotIn("set_false_path", fdc)
                self.assertNotIn("set_clock_groups", fdc)
                self.assertFalse(report["physical_timing_pass"])

    def test_c3_records_actual_rounded_simulation_periods(self):
        report, _ = build_plan(REPO, "C3")
        self.assertEqual(report["clocks"]["core"]["period_ns"], "11.764")
        self.assertAlmostEqual(report["clocks"]["core"]["frequency_hz"], 1e9 / 11.764)
        self.assertNotEqual(report["clocks"]["core"]["frequency_hz"], 85e6)

    def test_c4_equal_rates_keep_cdc_and_record_distinct_phase(self):
        report, _ = build_plan(REPO, "C4")
        self.assertEqual(report["clocks"]["core"]["period_ns"], report["clocks"]["sys"]["period_ns"])
        self.assertNotEqual(report["clocks"]["core"]["testbench_start_offset_ps"],
                            report["clocks"]["sys"]["testbench_start_offset_ps"])
        self.assertEqual(len(report["fifo_boundaries"]), 31)

    def test_all_fifo_directions_depths_and_gray_budgets(self):
        report, _ = build_plan(REPO, "C1")
        entries = {f["rtl_instance"]: f for f in report["fifo_boundaries"]}
        self.assertEqual(len(entries), 31)
        self.assertEqual(sum(f["depth"] == 8 for f in entries.values()), 25)
        self.assertEqual(sum(f["depth"] == 2 for f in entries.values()), 6)
        self.assertEqual(entries["g_ddr.u_ddr_cdc.u_ar"]["source_domain"], "sys")
        self.assertEqual(entries["g_ddr.u_ddr_cdc.u_r"]["source_domain"], "ddr")
        self.assertEqual(entries["g_ddr.u_ddr_cdc.u_r"]["gray_physical_budget_ns"], "8")
        self.assertEqual(sum(len(f["gray_crossings"]) for f in entries.values()), 62)

    def test_reference_clock_and_local_hot_domain_are_preserved(self):
        report, _ = build_plan(REPO, "floor85")
        self.assertEqual(report["board"]["reference_hz"], 125e6)
        self.assertEqual(report["board"]["ddr_user_hz"], 125e6)
        self.assertEqual(report["local_hot_path"]["domain"], "core")
        self.assertFalse(report["board"]["candidate_applied"])
        self.assertAlmostEqual(report["clocks"]["core"]["frequency_hz"], 85e6, delta=5)

    def test_mtime_and_uart_use_peripheral_clock(self):
        report, _ = build_plan(REPO, "C1")
        self.assertEqual(report["timebases"]["mtime_hz"], 25e6)
        self.assertEqual(report["timebases"]["uart_divisor_for_115200"], 217)
        self.assertEqual(report["timebases"]["mcycle_domain"], "core")

    def test_pango_target_is_rejected_before_output(self):
        with self.assertRaisesRegex(ValueError, "remain unbound"):
            build_plan(REPO, "floor85", "pango_200hp_top")

    def test_changed_board_clock_mapping_is_rejected(self):
        self.source["vsrc/cpu/pango_200hp_top.sv"] = self.source["vsrc/cpu/pango_200hp_top.sv"].replace(
            ".clk_sys(sys_clk)", ".clk_sys(other_clk)")
        with self.assertRaisesRegex(ValueError, "board clk_sys"):
            check_topology(self.source)

    def test_physical_staging_cannot_silently_select_independent_profile(self):
        wrapper = self.source["vsrc/cpu/pango_200hp_top.sv"]
        verify_default_board_clocks(wrapper)
        for before, after in (("BOARD_CLOCK_PROFILE = 0,", "BOARD_CLOCK_PROFILE = 1,"),
                              ("assign sys_clk = core_clk;", "assign sys_clk = ref_clk;"),
                              ("HOT_HZ = BOARD_CLOCK_PROFILE == 0 ? 125000000", "HOT_HZ = BOARD_CLOCK_PROFILE == 0 ? 85000000")):
            with self.subTest(before=before), self.assertRaises(ValueError):
                verify_default_board_clocks(wrapper.replace(before, after))

    def test_board_candidate_keeps_physical_evidence_pending(self):
        report, _ = build_plan(REPO, "C1")
        pll = report["board"]["pll_candidate"]
        self.assertEqual(pll["reference_hz"] // pll["idiv"] * pll["mdiv"] * pll["feedback_div"], pll["vco_hz"])
        self.assertEqual([pll["vco_hz"] // divider for divider in pll["output_div_c1"]], [100000000, 80000000, 25000000])
        self.assertFalse(pll["site_and_route_verified"])
        self.assertEqual(report["board"]["default_profile"], 0)

    def test_changed_tcm_domain_is_rejected(self):
        self.source["vsrc/soc/soc_system.sv"] = self.source["vsrc/soc/soc_system.sv"].replace(
            "u_ram (\n            .clk(clk_core)", "u_ram (\n            .clk(clk_sys)")
        with self.assertRaisesRegex(ValueError, "u_ram"):
            check_topology(self.source)

    def test_removed_synchronizer_stage_is_rejected(self):
        self.source["vsrc/soc/common/async_fifo.sv"] = self.source["vsrc/soc/common/async_fifo.sv"].replace(
            "write_sync2_q <= write_sync1_q;", "write_sync2_q <= write_gray_q;")
        with self.assertRaisesRegex(ValueError, "two-stage"):
            check_topology(self.source)

    def test_incomplete_testbench_profile_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "incomplete"):
            clock_profiles(self.source["tb/soc/tb_soc_system.sv"].replace("default:return 40000;", ""))

    def test_isolated_artifacts_hash_and_no_source_mutation(self):
        before = {name: hashlib.sha256((REPO / name).read_bytes()).hexdigest() for name in SOURCES}
        with tempfile.TemporaryDirectory() as directory:
            fixture = Path(directory)
            for name in SOURCES:
                destination = fixture / name
                destination.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(REPO / name, destination)
            output = fixture / "build/candidate"
            report = write_plan(fixture, output, "C1")
            saved = json.loads((output / "clock-plan.json").read_text())
            self.assertEqual(saved, report)
            self.assertEqual(saved["source_sha256"], before)
            self.assertEqual(saved["constraint_sha256"],
                             hashlib.sha256((output / "soc_system_clocks.fdc").read_bytes()).hexdigest())
            with self.assertRaisesRegex(ValueError, "empty"):
                write_plan(fixture, output, "C2")
            with self.assertRaisesRegex(ValueError, "isolated"):
                write_plan(fixture, fixture / "board", "C2")
        self.assertEqual(before, {name: hashlib.sha256((REPO / name).read_bytes()).hexdigest() for name in SOURCES})


if __name__ == "__main__":
    unittest.main(verbosity=2)
