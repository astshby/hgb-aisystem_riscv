#!/usr/bin/env python3
"""Exercise generated Tcl with a synthetic PDS object registry; never run PDS."""
import ctypes
import ctypes.util
import json
from pathlib import Path
import sys
import unittest

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO))
from scripts.pango.measurement_constraints import CLOCKS, DOMAINS, PRUNABLE_FIFOS, generate


def tcl_list(items):
    return " ".join("{" + item + "}" for item in items)


class Tcl:
    """Use an installed Tcl runtime without any simulator or shell process."""
    def __init__(self):
        name = ctypes.util.find_library("tcl8.6")
        if name is None:
            raise unittest.SkipTest("Tcl 8.6 shared library unavailable; generated Tcl execution not checked")
        self.library = ctypes.CDLL(name)
        self.library.Tcl_CreateInterp.restype = ctypes.c_void_p
        self.library.Tcl_Eval.argtypes = (ctypes.c_void_p, ctypes.c_char_p)
        self.library.Tcl_Eval.restype = ctypes.c_int
        self.library.Tcl_GetStringResult.argtypes = (ctypes.c_void_p,)
        self.library.Tcl_GetStringResult.restype = ctypes.c_char_p
        self.library.Tcl_DeleteInterp.argtypes = (ctypes.c_void_p,)
        self.interp = self.library.Tcl_CreateInterp()

    def evaluate(self, script):
        status = self.library.Tcl_Eval(self.interp, script.encode())
        result = self.library.Tcl_GetStringResult(self.interp).decode()
        if status:
            raise RuntimeError(result)
        return result

    def close(self):
        self.library.Tcl_DeleteInterp(self.interp)


class Objects:
    def __init__(self, spec):
        self.clocks = [f"clk_{d}" for d in spec["active_domains"]]
        self.ports = ["reset_async", *self.clocks]
        self.pins = []
        self.domains = {(d, kind): [] for d in spec["active_domains"] for kind in ("clock", "data", "output", "async")}
        for domain in spec["active_domains"]:
            bit = DOMAINS.index(domain)
            self.ports.extend(f"{p}[{bit}]" for p in ("scan_shift", "scan_update", "scan_capture", "scan_din", "scan_dout"))
            # The scan bank remains a timed member of its domain.
            self.register(f"g_scan_{domain}.u_scan", "drive", 0, domain)
        for reset in spec["reset_chains"]:
            for root in reset["roots"]:
                for bit in range(3):
                    self.register(root, "release_q", bit, reset["domain"], asynchronous=True)
        for fifo in spec["fifos"]:
            for crossing in fifo["crossings"]:
                direction = crossing["direction"]
                for bit in range(fifo["pointer_bits"]):
                    self.register(fifo["path"], f"{direction}_gray_q", bit, crossing["source_domain"])
                    for stage in (1, 2):
                        self.register(fifo["path"], f"{direction}_sync{stage}_q", bit, crossing["destination_domain"])
        if spec["layer"] == 2:
            for signal, bits, domain in (("irq_sync1_q", range(3), "core"), ("irq_sync2_q", range(3), "core"),
                                         ("ddr_system_online_q", range(2), "sys"), ("ddr_online_q", range(2), "periph")):
                for bit in bits:
                    self.register("g_soc.u_soc", signal, bit, domain)

    def register(self, root, signal, bit, domain, asynchronous=False, opit="opit_0"):
        stem = f"{root.replace('.', '/')}/{signal}[{bit}]/{opit}"
        for kind, pin in (("clock", "CLK"), ("data", "D"), ("output", "Q")):
            name = f"{stem}.{pin}"
            self.pins.append(name)
            self.domains[domain, kind].append(name)
        if asynchronous:
            name = f"{stem}.P"
            self.pins.append(name)
            self.domains[domain, "async"].append(name)

    def remove(self, predicate):
        self.pins = [p for p in self.pins if not predicate(p)]
        for key, names in self.domains.items():
            self.domains[key] = [p for p in names if not predicate(p)]

    def mock_tcl(self):
        lines = [f"set mock_pins {{{tcl_list(self.pins)}}}", f"set mock_ports {{{tcl_list(self.ports)}}}",
                 f"set mock_clocks {{{tcl_list(self.clocks)}}}", "set mock_output {}; set mock_calls {}"]
        for (domain, kind), names in self.domains.items():
            lines.append(f"set mock_domain({domain},{kind}) {{{tcl_list(names)}}}")
        lines.append(r'''
proc puts {args} { lappend ::mock_output [lindex $args end] }
proc mock_select {names args} {
    set pattern [lindex $args end]; set found {}
    foreach name $names {
        if {[lsearch -exact $args -regexp] >= 0} { set matches [regexp -- $pattern $name] } else { set matches [expr {$name eq $pattern}] }
        if {$matches} { lappend found $name }
    }
    return $found
}
proc get_pins {args} { return [mock_select $::mock_pins {*}$args] }
proc get_ports {args} { return [mock_select $::mock_ports {*}$args] }
proc get_clocks {args} { return [mock_select $::mock_clocks {*}$args] }
proc all_clocks {} { return $::mock_clocks }
proc all_registers {args} {
    if {[lsearch -exact $args -clock] < 0} {
        if {$args ne {-clock_pins}} { error "unexpected unfiltered register query" }
        set names {}; foreach pin $::mock_pins { if {[string match *.CLK $pin]} { lappend names $pin } }
        return $names
    }
    set clock [lindex $args [expr {[lsearch -exact $args -clock] + 1}]]
    set domain [string range $clock 4 end]
    set option [lindex $args end]
    set kinds [dict create -clock_pins clock -data_pins data -output_pins output -async_pins async]
    return $::mock_domain($domain,[dict get $kinds $option])
}
foreach name {create_clock set_clock_uncertainty set_input_delay set_output_delay set_false_path set_max_delay set_max_skew report_path_timing} {
    proc $name {args} [format { lappend ::mock_calls [linsert $args 0 %s] } $name]
}
''')
        return "\n".join(lines)


class MeasurementConstraintsTests(unittest.TestCase):
    def run_tcl(self, artifacts, objects=None, script="audit_clock_bindings.tcl"):
        spec = json.loads(artifacts["binding-spec.json"])
        runtime = Tcl()
        self.addCleanup(runtime.close)
        runtime.evaluate((objects or Objects(spec)).mock_tcl())
        runtime.evaluate(artifacts[script])
        return runtime

    def test_deterministic_api_and_profile_values(self):
        self.assertEqual(CLOCKS["C1"], dict(core=100000000, sys=80000000, ddr=125000000, periph=25000000))
        self.assertEqual(CLOCKS["C4"]["sys"], 100000000)
        for layer in range(3):
            for profile in CLOCKS:
                generated = generate(layer, profile)
                self.assertEqual(generated, generate(layer, profile))
                self.assertEqual(set(generated), {"measurement.fdc", "audit_clock_bindings.tcl", "report_domains.tcl", "binding-spec.json",
                                                 "proposed_cdc.fdc", "discover_clock_objects.tcl"})
                self.assertTrue(all(type(v) is str for v in generated.values()))

    def test_invalid_or_board_inputs_rejected(self):
        for layer in (-1, 3, "2", True, None):
            with self.subTest(layer=layer), self.assertRaises(ValueError):
                generate(layer)
        for profile in ("C0", "C3", "floor85", "C1; place", "C1\nroute"):
            with self.subTest(profile=profile), self.assertRaises(ValueError):
                generate(2, profile)

    def test_all_six_mock_designs_pass_binding_and_report_guards(self):
        for layer in range(3):
            for profile in CLOCKS:
                with self.subTest(layer=layer, profile=profile):
                    artifacts = generate(layer, profile)
                    runtime = self.run_tcl(artifacts)
                    self.assertEqual(runtime.evaluate("set ::hgb_measurement_bindings_pass"), "1")
                    runtime.evaluate(artifacts["report_domains.tcl"])
                    self.assertEqual(int(runtime.evaluate("llength $mock_calls")), 16 if layer == 2 else 1)

    def test_clock_scan_and_reset_io_constraints_execute_in_tcl(self):
        for layer in range(3):
            artifacts = generate(layer)
            runtime = self.run_tcl(artifacts, script="measurement.fdc")
            count = int(runtime.evaluate("llength $mock_calls"))
            self.assertGreater(count, 10)
            fdc = artifacts["measurement.fdc"]
            self.assertNotIn("set_clock_groups", fdc)
            self.assertNotIn("set_bus_skew", fdc)
            for command in ("set_false_path", "set_max_delay", "set_max_skew", "get_pins", "get_cells"):
                self.assertNotIn(command, fdc)
            for line in artifacts["proposed_cdc.fdc"].splitlines():
                if line.startswith("set_false_path"):
                    self.assertNotIn("scan_", line)
                    self.assertNotIn("sync2_q", line)
                    self.assertNotIn("payload", line)
                    self.assertNotIn("-to [get_clocks", line)
            self.assertIn("-max 1", fdc)
            self.assertIn("-min 0", fdc)
            self.assertEqual(fdc.count("create_clock -name"), 4 if layer == 2 else 1)
            self.assertNotIn("create_generated_clock", fdc)

    def test_cdc_inventory_directions_counts_and_budgets(self):
        spec = json.loads(generate(2)["binding-spec.json"])
        self.assertEqual(len(spec["fifos"]), 31)
        self.assertEqual(sum(2 * f["pointer_bits"] for f in spec["fifos"]), 224)
        entries = {f["path"]: f for f in spec["fifos"]}
        self.assertEqual(entries["g_soc.u_soc.g_ddr.u_ddr_cdc.u_ar"]["budget_ns"], "8")
        self.assertEqual(entries["g_soc.u_soc.u_periph_cdc.u_ar"]["budget_ns"], "12.5")
        response = entries["g_soc.u_soc.g_ddr.u_ddr_cdc.u_r"]["crossings"][0]
        self.assertEqual((response["source_domain"], response["destination_domain"]), ("ddr", "sys"))
        fdc = generate(2)["proposed_cdc.fdc"]
        self.assertEqual(fdc.count("set_max_delay "), 62)
        self.assertEqual(fdc.count("set_max_skew "), 62)
        self.assertFalse(spec["exceptions_loaded"])
        self.assertIn("conservative_external_clocks_io", spec["constraints_mode"])
        self.assertEqual(spec["pending_exception_count"], 197)

    def test_bootstrap_constraints_do_not_query_unbound_internal_pins(self):
        for layer in range(3):
            artifacts = generate(layer)
            runtime = Tcl(); self.addCleanup(runtime.close)
            runtime.evaluate(Objects(json.loads(artifacts["binding-spec.json"])).mock_tcl())
            # Reproduce the native pre-map failure mode: internal pin names cannot resolve.
            runtime.evaluate('proc get_pins {args} {error "compile DB internal pin is unbound"}')
            runtime.evaluate('proc get_cells {args} {error "compile DB internal cell is unbound"}')
            runtime.evaluate(artifacts["measurement.fdc"])
            runtime.evaluate(artifacts["discover_clock_objects.tcl"])
            self.assertIn("S4_QUERY_ERROR", runtime.evaluate("join $mock_output"))
            self.assertEqual(runtime.evaluate("lindex $mock_output end"), "S4_OBJECT_DISCOVERY_END")
            self.assertNotIn("set_false_path", runtime.evaluate("join $mock_calls"))

    def test_missing_and_extra_clock_fail_closed(self):
        artifacts = generate(2)
        for altered in (["clk_core"], ["clk_core", "clk_sys", "clk_ddr", "clk_periph", "inferred_wrong"]):
            objects = Objects(json.loads(artifacts["binding-spec.json"]))
            objects.clocks = altered
            with self.subTest(altered=altered), self.assertRaisesRegex(RuntimeError, "active diagnostic clocks"):
                self.run_tcl(artifacts, objects)

    def test_missing_first_or_second_stage_and_duplicate_bit_fail(self):
        artifacts = generate(2)
        for signal in ("write_sync1_q", "write_sync2_q"):
            objects = Objects(json.loads(artifacts["binding-spec.json"]))
            objects.remove(lambda p: "u_ddr_cdc/u_ar/" + signal + "[1]/" in p and p.endswith(".D"))
            with self.subTest(signal=signal), self.assertRaisesRegex(RuntimeError, "expected bits"):
                self.run_tcl(artifacts, objects)
        objects = Objects(json.loads(artifacts["binding-spec.json"]))
        objects.register("g_soc.u_soc.g_ddr.u_ddr_cdc.u_ar", "write_sync1_q", 0, "ddr", opit="opit_1")
        with self.assertRaisesRegex(RuntimeError, "expected bits"):
            self.run_tcl(artifacts, objects)

    def test_wrong_domain_for_first_stage_fails(self):
        artifacts = generate(2)
        objects = Objects(json.loads(artifacts["binding-spec.json"]))
        selected = next(p for p in objects.domains["ddr", "data"] if "u_ddr_cdc/u_ar/write_sync1_q[0]" in p)
        objects.domains["ddr", "data"].remove(selected)
        objects.domains["sys", "data"].append(selected)
        with self.assertRaisesRegex(RuntimeError, "does not belong to clk_ddr"):
            self.run_tcl(artifacts, objects)

    def test_unclocked_or_uncovered_register_fails(self):
        artifacts = generate(0)
        objects = Objects(json.loads(artifacts["binding-spec.json"]))
        objects.pins.append("uncovered_register.CLK")
        with self.assertRaisesRegex(RuntimeError, "outside the declared diagnostic domains"):
            self.run_tcl(artifacts, objects)

    def test_only_whole_whitelisted_fifo_can_be_pruned(self):
        artifacts = generate(2)
        objects = Objects(json.loads(artifacts["binding-spec.json"]))
        for path in PRUNABLE_FIFOS:
            prefix = path.replace(".", "/") + "/"
            objects.remove(lambda p, prefix=prefix: p.startswith(prefix))
        runtime = self.run_tcl(artifacts, objects)
        self.assertEqual(runtime.evaluate("llength [lsearch -all -glob $mock_output {MEASUREMENT_FIFO_PRUNED *}]"), "3")
        for path, partial in ((PRUNABLE_FIFOS[0], True), ("g_soc.u_soc.g_ddr.u_ddr_cdc.u_ar", False)):
            objects = Objects(json.loads(artifacts["binding-spec.json"]))
            prefix = path.replace(".", "/") + "/"
            objects.remove(lambda p: p.startswith(prefix) and (not partial or "write_gray_q" in p))
            with self.subTest(path=path), self.assertRaisesRegex(RuntimeError, "expected bits"):
                self.run_tcl(artifacts, objects)

    def test_reset_merging_allows_complete_chain_only(self):
        artifacts = generate(2)
        objects = Objects(json.loads(artifacts["binding-spec.json"]))
        objects.remove(lambda p: p.startswith("g_soc/u_soc/u_reset/"))
        self.run_tcl(artifacts, objects)
        objects.remove(lambda p: p.startswith("u_reset/g_domain[0]/release_q[1]/"))
        with self.assertRaisesRegex(RuntimeError, "reset core: expected bits"):
            self.run_tcl(artifacts, objects)

    def test_renamed_residual_fifo_cannot_be_reported_as_pruned(self):
        artifacts = generate(2)
        objects = Objects(json.loads(artifacts["binding-spec.json"]))
        path = PRUNABLE_FIFOS[0]
        objects.remove(lambda p: p.startswith(path.replace(".", "/") + "/"))
        objects.register(path, "unexpected_gray_alias", 0, "core")
        with self.assertRaisesRegex(RuntimeError, "residual registers"):
            self.run_tcl(artifacts, objects)

    def test_wrong_level_second_stage_or_unrelated_query_fails(self):
        artifacts = generate(2)
        objects = Objects(json.loads(artifacts["binding-spec.json"]))
        objects.remove(lambda p: "ddr_online_q[1]/" in p)
        with self.assertRaisesRegex(RuntimeError, "ddr_periph_ready second_d"):
            self.run_tcl(artifacts, objects)
        runtime = Tcl(); self.addCleanup(runtime.close)
        runtime.evaluate(Objects(json.loads(artifacts["binding-spec.json"])).mock_tcl())
        runtime.evaluate("proc get_pins {args} {return unrelated_register.D}")
        with self.assertRaisesRegex(RuntimeError, "unrelated object"):
            runtime.evaluate(artifacts["audit_clock_bindings.tcl"])

    def test_opaque_collections_and_report_without_audit_fail(self):
        artifacts = generate(0)
        runtime = Tcl(); self.addCleanup(runtime.close)
        runtime.evaluate(Objects(json.loads(artifacts["binding-spec.json"])).mock_tcl())
        with self.assertRaisesRegex(RuntimeError, "audit must pass"):
            runtime.evaluate(artifacts["report_domains.tcl"])
        runtime.evaluate("proc all_clocks {} {return _opaque123}")
        with self.assertRaisesRegex(RuntimeError, "expected clk_core"):
            runtime.evaluate(artifacts["audit_clock_bindings.tcl"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
