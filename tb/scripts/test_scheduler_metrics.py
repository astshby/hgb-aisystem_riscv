#!/usr/bin/env python3
"""Validate passive scheduler records without rebuilding software or RTL."""
import json
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'scripts/verilator'))
from compare_coremark import scheduler_fields


class SchedulerFieldsTest(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix='scheduler-fields-')
        self.addCleanup(temporary.cleanup)
        self.log = Path(temporary.name) / 'run.log'
        self.record = dict(window='whole_run', cycles=100, occupied_cycles=60, ready_cycles=30,
            full_cycles=4, raw_cycles=30, raw_alu_cycles=20, raw_mdu_cycles=5, raw_load_cycles=18,
            mdu_resource_cycles=10, mdu_iq_idle_cycles=3, accepted_cycles=20, accepted_operations=35,
            bypass_raw_cycles=8, bypass_mdu_cycles=3)

    def write(self, **changes):
        self.log.write_text('SCHEDULER_STATS ' + json.dumps(dict(self.record, **changes)) + '\n')

    def test_valid_overlapping_categories(self):
        self.write()
        self.assertEqual(scheduler_fields(self.log, 100, True), self.record)

    def test_legacy_missing_optional_record(self):
        self.log.write_text('PASS existing baseline\n')
        self.assertIsNone(scheduler_fields(self.log, 100))

    def test_missing_required_record(self):
        self.log.write_text('PASS existing baseline\n')
        with self.assertRaises(ValueError):
            scheduler_fields(self.log, 100, True)

    def test_duplicate_record(self):
        self.write()
        self.log.write_text(self.log.read_text() * 2)
        with self.assertRaises(ValueError):
            scheduler_fields(self.log, 100)

    def test_wrong_window_and_unknown_fields(self):
        for changes in ({'window': 'roi'}, {'extra': 1}):
            self.write(**changes)
            with self.assertRaises(ValueError):
                scheduler_fields(self.log, 100)

    def test_counter_types_and_negative_values(self):
        for value in (-1, True, '1', 1.5):
            self.write(raw_cycles=value)
            with self.assertRaises(ValueError):
                scheduler_fields(self.log, 100)

    def test_wrong_cycle_boundary(self):
        self.write(cycles=101)
        with self.assertRaises(ValueError):
            scheduler_fields(self.log, 100)

    def test_inconsistent_category_bounds(self):
        for changes in ({'ready_cycles': 61}, {'raw_load_cycles': 31}, {'mdu_iq_idle_cycles': 11},
                        {'bypass_raw_cycles': 21}, {'accepted_operations': 41}, {'accepted_operations': 19}):
            self.write(**changes)
            with self.assertRaises(ValueError):
                scheduler_fields(self.log, 100)


if __name__ == '__main__':
    unittest.main(verbosity=2)
