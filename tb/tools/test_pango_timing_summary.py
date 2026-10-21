"""Check PDS evidence parsing without starting vendor tools or changing old reports."""
from pathlib import Path
import hashlib
import json
import shutil
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
from scripts.pango.summarize_timing import completed_actions, placement_reuse, setup_paths


class TimingEvidenceTests(unittest.TestCase):
    actions = ["dev_map -force_to_run", "place -mode fast", "route", "route_optimize"]

    def log(self, report="report_timing"):
        return "\n".join(f"Executing : {action} successfully."
                         for action in self.actions + [report])

    def test_original_commands(self):
        self.assertEqual(completed_actions(self.log()), self.actions + ["report_timing"])

    def test_extended_path_commands(self):
        command = "report_timing -max_path 100 -nworst 1"
        self.assertEqual(completed_actions(self.log(command))[-1], command)

    def test_default_place_command(self):
        expected = ["dev_map -force_to_run", "place", "route", "route_optimize", "report_timing"]
        self.assertEqual(completed_actions(self.log().replace("place -mode fast", "place")), expected)

    def test_standard_place_without_lut_combining(self):
        for command in ("place -logic_optimize_lut6d FALSE",
                        "place -logic_optimize_lut6d FALSE -logic_optimize_lut_cascade FALSE"):
            with self.subTest(command=command):
                self.assertEqual(completed_actions(self.log().replace("place -mode fast", command))[1], command)
                with self.assertRaises(ValueError):
                    completed_actions(self.log().replace("place -mode fast", command + " -mode fast"))

    def test_unknown_or_incomplete_place_rejected(self):
        for command in ("place -mode unknown", "place -mode fast extra", "not-complete place"):
            with self.subTest(command=command), self.assertRaises(ValueError):
                completed_actions(self.log().replace("place -mode fast", command))
        with self.assertRaises(ValueError):
            completed_actions(self.log().replace("place -mode fast successfully.", "place"))

    def test_missing_actions(self):
        for action in self.actions + ["report_timing"]:
            with self.subTest(action=action), self.assertRaises(ValueError):
                completed_actions(self.log().replace(f"Executing : {action} successfully.", ""))

    def test_started_but_incomplete(self):
        with self.assertRaises(ValueError):
            completed_actions(self.log().replace("report_timing successfully.", "report_timing"))

    def test_unrecognized_or_invalid_report(self):
        for command in ("report_timing -max_path 0 -nworst 1", "report_timing -max_path -1 -nworst 1",
                        "report_timing -unknown", "report_timing -max_path 100 -nworst 0"):
            with self.subTest(command=command), self.assertRaises(ValueError):
                completed_actions(self.log(command))

    def test_embedded_marker_is_not_evidence(self):
        with self.assertRaises(ValueError):
            completed_actions(self.log().replace("Executing : report_timing", "not-complete Executing : report_timing"))

    def paths(self, rows):
        with tempfile.TemporaryDirectory(prefix="pds-summary-test-") as directory:
            db = Path(directory)
            (db / "report_timing_slow_path_setup.db").write_text(
                '<tables><table><column_headers><data>Slack</data><data>End Point</data>'
                '</column_headers>' + rows + '</table></tables>')
            return setup_paths(db)

    def test_all_paths_and_resources_retained(self):
        paths = self.paths(
            '<row><data>-1.0</data><data>first/D</data></row>'
            '<row><data>-2.0</data><data>second/CE</data><general_container><table_container>'
            '<table><row><data>0.3</data><data>mux/L6</data></row></table>'
            '</table_container></general_container></row>')
        self.assertEqual(len(paths), 2)
        self.assertEqual(paths[0]["logical_resources"], [])
        self.assertEqual(paths[1]["logical_resources"], ["mux/L6"])
        self.assertEqual(min(paths, key=lambda path: float(path["Slack"]))["End Point"], "second/CE")

    def test_empty_paths_rejected(self):
        with self.assertRaises(ValueError):
            self.paths("")


class PlacementReuseTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="pds-placement-reuse-")
        self.addCleanup(temporary.cleanup)
        base = Path(temporary.name)
        self.source, self.root = base / "source", base / "target"
        self.database = "prj_tasks/pnr_1/place_route/design_plc.adf"
        names = ["a.sv", self.database, "init-both-summary.json",
                 "prj_tasks/syn_1/synthesize/pango_200hp_top.snr",
                 "prj_tasks/syn_1/synthesize/pango_200hp_top_syn.vm",
                 "prj_tasks/pnr_1/place_route/run_place.log"]
        for name in names:
            path = self.source / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(name)
        manifest = dict(xlen=32, mul=0, div=1, soc_clock_hz=125000000,
                        files={"a.sv": self.digest(self.source / "a.sv")})
        (self.source / "manifest.json").write_text(json.dumps(manifest))
        shutil.copytree(self.source, self.root)
        self.source_log, self.copy_log = base / "source.log", base / "copy.log"
        placement = "Executing : dev_map -force_to_run successfully.\nExecuting : place successfully.\n"
        self.source_log.write_text(placement)
        self.copy_log.write_text(placement)
        self.proof = dict(source_project=str(self.source), placement_database=self.database,
                          source_implementation_log=str(self.source_log),
                          copied_implementation_log=str(self.copy_log),
                          source_implementation_log_sha256=self.digest(self.source_log),
                          copied_files_sha256={name: self.digest(self.source / name)
                                               for name in names + ["manifest.json"]},
                          route_threads=4, route_mode="normal")
        self.save_proof()
        self.command = ("route -force_to_run -route_mode normal -number_of_router_thread 4 "
                        f"-input_place_db_file {self.root / self.database}")
        self.impl = "\n".join(f"Executing : {action} successfully."
                              for action in (self.command, "route_optimize", "report_timing"))

    @staticmethod
    def digest(path):
        return hashlib.sha256(path.read_bytes()).hexdigest()

    def save_proof(self):
        (self.root / "placement-reuse.json").write_text(json.dumps(self.proof))

    def test_valid_split_evidence(self):
        proof, placement, route = placement_reuse(self.root, self.impl)
        self.assertEqual(proof["route_threads"], 4)
        self.assertEqual(completed_actions(self.impl, placement, route),
                         ["dev_map -force_to_run", "place", self.command, "route_optimize", "report_timing"])
        with self.assertRaises(ValueError):
            completed_actions(self.impl)

    def test_changed_donor_or_copy_rejected(self):
        for base in (self.source, self.root):
            with self.subTest(base=base):
                path = base / self.database
                original = path.read_bytes()
                path.write_bytes(original + b"changed")
                with self.assertRaises(ValueError):
                    placement_reuse(self.root, self.impl)
                path.write_bytes(original)

    def test_both_original_logs_are_bound(self):
        for path in (self.source_log, self.copy_log):
            with self.subTest(path=path):
                original = path.read_text()
                path.write_text(original + "changed")
                with self.assertRaises(ValueError):
                    placement_reuse(self.root, self.impl)
                path.write_text(original)

    def test_route_mode_threads_database_and_completion_bound(self):
        for bad in (
            self.impl.replace("normal", "fast"),
            self.impl.replace("thread 4", "thread 8"),
            self.impl.replace(str(self.root / self.database), str(self.source / self.database)),
            self.impl.replace(f"{self.command} successfully.", self.command),
            self.impl + f"\nExecuting : {self.command} successfully.",
        ):
            with self.subTest(log=bad), self.assertRaises(ValueError):
                placement_reuse(self.root, bad)

    def test_later_nonstandard_placement_rejected(self):
        for path in (self.source_log, self.copy_log):
            path.write_text(path.read_text() + "Executing : place -mode fast successfully.\n")
        self.proof["source_implementation_log_sha256"] = self.digest(self.source_log)
        self.save_proof()
        with self.assertRaises(ValueError):
            placement_reuse(self.root, self.impl)

    def test_all_inputs_must_be_covered(self):
        del self.proof["copied_files_sha256"]["a.sv"]
        self.save_proof()
        with self.assertRaises(ValueError):
            placement_reuse(self.root, self.impl)

    def test_paths_must_stay_within_artifact_roots(self):
        self.proof["copied_files_sha256"]["../source.log"] = self.digest(self.source_log)
        self.save_proof()
        with self.assertRaises(ValueError):
            placement_reuse(self.root, self.impl)


if __name__ == "__main__":
    unittest.main(verbosity=2)
