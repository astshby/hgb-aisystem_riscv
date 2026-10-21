#!/usr/bin/env python3
"""Run the real implementation Tcl against mocked PDS and memory commands."""
from pathlib import Path
import ctypes
import ctypes.util
import tempfile
from types import SimpleNamespace
import unittest

REPO = Path(__file__).resolve().parents[2]
TCL_LIBRARY = ctypes.util.find_library("tcl8.6")


@unittest.skipUnless(TCL_LIBRARY, "libtcl8.6 is required")
class MemoryFlowTests(unittest.TestCase):
    def run_flow(self, blocked=""):
        with tempfile.TemporaryDirectory() as directory:
            project = Path(directory) / "fixture.pds"
            project.touch()
            wrapper = """
set ::env(HGB_PDS_PROJECT) {@PROJECT@}
set blocked {@BLOCKED@}
set events {}
proc open_project {args} {}
proc set_option {args} {}
proc puts {args} {}
proc exec {args} {
    set phase [lindex $args end]
    lappend ::events check:$phase
    if {$phase eq $::blocked} {error "insufficient memory"}
    return "PASS memory $phase"
}
foreach phase {dev_map place route route_optimize report_timing} {
    proc $phase {args} [format {lappend ::events run:%s} $phase]
}
set failed [catch {source {@IMPLEMENT@}} message]
list $failed $events
""".replace("@PROJECT@", str(project)).replace("@BLOCKED@", blocked).replace(
                "@IMPLEMENT@", str(REPO / "scripts/pango/implement.tcl"))
            library = ctypes.CDLL(TCL_LIBRARY)
            library.Tcl_CreateInterp.restype = ctypes.c_void_p
            library.Tcl_Eval.argtypes = [ctypes.c_void_p, ctypes.c_char_p]
            library.Tcl_GetStringResult.argtypes = [ctypes.c_void_p]
            library.Tcl_GetStringResult.restype = ctypes.c_char_p
            library.Tcl_DeleteInterp.argtypes = [ctypes.c_void_p]
            interpreter = library.Tcl_CreateInterp()
            try:
                code = library.Tcl_Eval(interpreter, wrapper.encode())
                result = library.Tcl_GetStringResult(interpreter).decode()
                self.assertEqual(code, 0, result)
                status, events = result.split(" ", 1)
                return SimpleNamespace(returncode=int(status), stdout="EVENTS " + events.strip("{}"), stderr="")
            finally:
                library.Tcl_DeleteInterp(interpreter)

    def test_every_expensive_phase_is_gated(self):
        result = self.run_flow()
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        self.assertIn("EVENTS check:dev_map run:dev_map check:place run:place "
                      "check:route run:route check:route_optimize run:route_optimize "
                      "run:report_timing", result.stdout)

    def test_rejection_prevents_that_phase_and_following_work(self):
        phases = ["dev_map", "place", "route", "route_optimize"]
        for index, phase in enumerate(phases):
            with self.subTest(phase=phase):
                result = self.run_flow(phase)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(f"check:{phase}", result.stdout)
                for later in phases[index:] + ["report_timing"]:
                    self.assertNotIn(f"run:{later}", result.stdout)


if __name__ == "__main__":
    unittest.main()
