"""Synthetic UART transcripts exercise the PC decoder; they are not measured scores."""
import importlib.util
import contextlib
import io
from pathlib import Path
import sys
import tempfile
import types
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location('coremark_host', ROOT / 'scripts/coremark/host.py')
host = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(host)


def ready(test=False):
    return ('READY app=coremark version=1 firmware=test core_hz=100000000 '
            'sys_hz=100000000 ddr_hz=125000000 periph_hz=60000000 '
            f'memory=tcm opt=O3 baud=115200 test_only={int(test)}\n')


def attempt(mode='performance', iterations=20000, cycles=6000000000, formal=1):
    crc = host.EXPECTED[mode]
    return (f'CM_BEGIN mode={mode} iterations={iterations}\n' +
            '\n'.join(f'{"" if k == "seedcrc" else "[0]"}{k} : 0x{v:04x}' for k, v in crc.items()) +
            '\n[0]crcfinal : 0x1234\nTotal ticks : 1705032704\n' +
            (host.DURATION_ERROR + '\nErrors detected\n' if not formal else 'Correct operation validated.\n') +
            f'CM_RESULT mode={mode} iterations={iterations} roi_cycles={cycles} core_hz=100000000 formal={formal}\n')


def transcript(**kwargs):
    return ready() + attempt(**kwargs) + 'DONE status=completed\n' + ready()


class CoreMarkHostTest(unittest.TestCase):
    def test_u64_roi_ignores_wrapped_vendor_ticks(self):
        report = host.decode(transcript())
        self.assertTrue(report['valid'])
        self.assertTrue(report['requests'][0]['official'])
        result = report['requests'][0]['attempts'][0]['result']
        self.assertEqual(result['roi_cycles'], 6000000000)
        self.assertEqual(result['duration_seconds'], 60)
        self.assertAlmostEqual(result['coremark_per_mhz'], 20000 / 6000)

    def test_two_requests_with_calibration_crc_ignored(self):
        text = ready() + 'CAL_BEGIN mode=performance iterations=32\nseedcrc : 0x0000\nCAL_END roi_cycles=123\n'
        text += attempt() + 'DONE status=completed\n' + ready()
        text += attempt(mode='validation') + 'DONE status=completed\n' + ready()
        report = host.decode(text.replace('\n', '\r\n'))
        self.assertTrue(report['valid'])
        self.assertEqual(len(report['requests']), 2)
        self.assertTrue(all(x['official'] for x in report['requests']))

    def test_short_crc_valid_measurement_is_not_official(self):
        text = ready(True) + attempt(iterations=2, cycles=600000, formal=0)
        text += 'DONE status=short\n' + ready(True)
        report = host.decode(text)
        self.assertTrue(report['valid'])
        self.assertFalse(report['requests'][0]['official'])

    def test_crc_failure_and_missing_crc(self):
        for text in (transcript().replace('0xe714', '0x0000'),
                     transcript().replace('[0]crcfinal : 0x1234\n', '')):
            with self.subTest(text=text):
                self.assertFalse(host.decode(text)['valid'])

    def test_forged_formal_flag_fails_duration(self):
        self.assertFalse(host.decode(transcript(cycles=999999999))['valid'])

    def test_begin_result_mismatch(self):
        for text in (transcript().replace('CM_RESULT mode=performance', 'CM_RESULT mode=validation'),
                     transcript().replace('CM_RESULT mode=performance iterations=20000',
                                          'CM_RESULT mode=performance iterations=20001')):
            with self.subTest(text=text):
                self.assertFalse(host.decode(text)['valid'])

    def test_clock_mismatch(self):
        text = transcript().replace('roi_cycles=6000000000 core_hz=100000000',
                                    'roi_cycles=6000000000 core_hz=90000000')
        self.assertFalse(host.decode(text)['valid'])

    def test_done_and_next_ready_both_required(self):
        for text in (ready() + attempt(), ready() + attempt() + 'DONE status=completed\n',
                     ready() + attempt() + ready()):
            with self.subTest(text=text):
                self.assertFalse(host.decode(text)['valid'])

    def test_retry_keeps_attempts_in_one_request(self):
        text = ready() + attempt(iterations=2000, cycles=600000000, formal=0)
        text += 'CM_RETRY reason=duration\n' + attempt() + 'DONE status=completed\n' + ready()
        report = host.decode(text)
        self.assertTrue(report['valid'])
        self.assertTrue(report['requests'][0]['official'])
        self.assertEqual(len(report['requests'][0]['attempts']), 2)

    def test_vendor_algorithm_error_is_not_tolerated(self):
        text = transcript().replace('[0]crcfinal', '[0]ERROR! state crc mismatch\n[0]crcfinal')
        self.assertFalse(host.decode(text)['valid'])

    def test_failed_command_preserves_ready_cycle(self):
        report = host.decode(ready() + 'DONE status=bad_command\n' + ready())
        self.assertFalse(report['valid'])
        self.assertEqual(report['requests'][0]['done'], 'bad_command')

    def test_duplicate_crc_and_fields_rejected(self):
        for text in (transcript().replace('Total ticks', 'seedcrc : 0xe9f5\nTotal ticks'),
                     transcript().replace('formal=1', 'formal=1 formal=1')):
            with self.subTest(text=text):
                self.assertFalse(host.decode(text)['valid'])

    def test_serial_two_requests_and_raw_bytes(self):
        payload = (ready() + attempt(mode='validation') + 'DONE status=completed\n' + ready() +
                   attempt(mode='validation') + 'DONE status=completed\n' + ready()).encode('ascii')
        sent = []

        class Serial:
            def __init__(self, *args, **kwargs):
                self.input = payload

            def __enter__(self): return self
            def __exit__(self, *args): pass
            def flush(self): pass
            def write(self, data): sent.append(data)
            def read(self, size):
                value, self.input = self.input[:37], self.input[37:]
                return value

        with tempfile.TemporaryDirectory() as directory:
            raw = Path(directory) / 'uart.log'
            with patch.dict(sys.modules, serial=types.SimpleNamespace(Serial=Serial)), contextlib.redirect_stdout(io.StringIO()):
                report = host.receive('MOCK', 115200, 'validation', 2, 1, raw)
            self.assertEqual(raw.read_bytes(), payload)
        self.assertTrue(report['valid'])
        self.assertEqual(sent, [b'V\r', b'V\r'])

    def test_serial_timeout_retains_raw_bytes(self):
        payload = b'partial UART line'

        class Serial:
            def __init__(self, *args, **kwargs): self.input = payload
            def __enter__(self): return self
            def __exit__(self, *args): pass
            def read(self, size):
                value, self.input = self.input, b''
                return value

        with tempfile.TemporaryDirectory() as directory:
            raw = Path(directory) / 'uart.log'
            with patch.dict(sys.modules, serial=types.SimpleNamespace(Serial=Serial)):
                with patch.object(host.time, 'monotonic', side_effect=[0, 0, 2]), self.assertRaises(TimeoutError):
                    host.receive('MOCK', 115200, 'performance', 1, 1, raw)
            self.assertEqual(raw.read_bytes(), payload)


if __name__ == '__main__':
    unittest.main()
