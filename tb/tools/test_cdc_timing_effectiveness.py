#!/usr/bin/env python3
"""Reject timing comparisons that hide synchronous paths or miss CDC bounds."""
import copy
from pathlib import Path
import sys
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'scripts/pango'))
from verify_cdc_timing import verify


class EffectivenessTests(unittest.TestCase):
    def fixture(self):
        same = {'Launch Clock': 'core', 'Capture Clock': 'core', 'WNS(ns)': '-0.7', 'Total Endpoints': '120'}
        cross = dict(same, **{'Capture Clock': 'sys', 'WNS(ns)': '1.0'})
        normal = dict(same, **{'Start Point': 'a/CLK', 'End Point': 'b/D', 'Exception': None})
        bounded = dict(cross, **{'Start Point': 'fifo/payload/CLK', 'End Point': 'capture/D',
                                'Exception': 'MaxDelay Path 10.000ns -datapath_only'})
        data = {'report_timing_clock_summary': [{'Clock Name': 'core', 'Period': '10'}],
                'report_timing_fmax': [{'Clock': 'core', 'Fmax': '93MHz'}],
                'report_timing_setup': [same, cross], 'report_timing_hold': [same],
                'report_timing_path_setup': [normal, bounded], 'report_timing_path_hold': [normal]}
        return {'before': copy.deepcopy(data), 'after': copy.deepcopy(data)}

    def run_comparison(self, data, log='CDC_TIMING_REPORT_DONE'):
        with patch('verify_cdc_timing.rows', side_effect=lambda directory, name: data[directory][name]):
            return verify('before', 'after', {'clocks': {'core': 'core', 'sys': 'sys'}}, log)

    def test_unchanged_synchronous_checks_and_reported_bounded_crossings(self):
        self.assertTrue(self.run_comparison(self.fixture())['status'].startswith('PASS'))

    def test_regressions_and_false_success_are_rejected(self):
        mutations = [('report_timing_fmax', 0, 'Fmax', '130MHz'),
                     ('report_timing_hold', 0, 'Total Endpoints', '119'),
                     ('report_timing_setup', 1, 'WNS(ns)', '-0.1'),
                     ('report_timing_path_setup', 0, 'Exception', 'MaxDelay Path 10.000ns'),
                     ('report_timing_path_setup', 1, 'End Point', 'fifo/read_sync2_q[0]/D'),
                     ('report_timing_path_setup', 1, 'Exception', None)]
        for table, index, field, value in mutations:
            data = self.fixture(); data['after'][table][index][field] = value
            with self.subTest(field=field, value=value), self.assertRaises(ValueError):
                self.run_comparison(data)
        with self.assertRaises(ValueError):
            self.run_comparison(self.fixture(), 'CDC_TIMING_REPORT_DONE\nC: STA-3015: No path found')


if __name__ == '__main__':
    unittest.main()
