"""Compile and exercise the same bounded command parser used by the RT UART demo."""
import ctypes
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class Input(ctypes.Structure):
    _fields_ = [('text', ctypes.c_char * 128), ('length', ctypes.c_size_t),
                ('swallow_lf', ctypes.c_uint), ('overflow', ctypes.c_uint)]


class RtDemoTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix='rt-uart-demo-')
        library = Path(cls.temp.name) / 'commands.so'
        subprocess.run(['cc', '-shared', '-fPIC', '-std=c11', '-O3', '-Wall', '-Wextra', '-Werror',
                        'software/rt-thread/demo_command.c', '-o', str(library)], cwd=ROOT, check=True)
        cls.library = ctypes.CDLL(str(library))
        cls.feed = cls.library.rt_demo_feed
        cls.feed.argtypes = (ctypes.POINTER(Input), ctypes.c_ubyte)
        cls.feed.restype = ctypes.c_int

    @classmethod
    def tearDownClass(cls):
        cls.temp.cleanup()

    def parse(self, data, state=None):
        state = state if state is not None else Input()
        result = []
        for value in data:
            command = self.feed(ctypes.byref(state), value)
            if command:
                result.append((command, state.text))
        return result

    def test_enter_and_crlf_once(self):
        self.assertEqual(self.parse(b'\r\nSTATUS\r\n'), [(1, b''), (1, b'STATUS')])

    def test_commands_and_unknown(self):
        self.assertEqual([x[0] for x in self.parse(b'PING\nDEMO\nwrong\n')], [2, 4, 5])

    def test_utf8_echo_keeps_bytes(self):
        text = 'ECHO 你好 FPGA'.encode()
        self.assertEqual(self.parse(text + b'\r'), [(3, text)])

    def test_overflow_recovery(self):
        result = self.parse(b'ECHO ' + b'x' * 200 + b'\r\nPING\n')
        self.assertEqual([x[0] for x in result], [6, 2])

    def test_exact_length_limit(self):
        self.assertEqual(self.parse(b'ECHO ' + b'x' * 122 + b'\n')[0][0], 3)
        self.assertEqual(self.parse(b'ECHO ' + b'x' * 123 + b'\n')[0][0], 6)

    def test_embedded_nul_rejected(self):
        self.assertEqual([x[0] for x in self.parse(b'PI\0NG\rPING\r')], [6, 2])

    def test_partial_and_repeated_requests(self):
        state = Input()
        self.assertEqual(self.parse(b'PI', state), [])
        self.assertEqual(self.parse(b'NG\r\n', state), [(2, b'PING')])
        self.assertEqual(len(self.parse(b'PING\r\n' * 1000, state)), 1000)
        self.assertEqual(state.length, 0)


if __name__ == '__main__':
    unittest.main()
