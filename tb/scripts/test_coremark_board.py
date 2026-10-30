"""Exercise the actual command loop and duration policy with deterministic C timer/UART stubs."""
from pathlib import Path
import subprocess
import tempfile
import unittest
import re
import importlib.util

ROOT = Path(__file__).resolve().parents[2]
HARNESS = r'''
#include <setjmp.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "coremark.h"
#include "board.h"
struct hgb_soc_clocks board_clocks = {100000000, 80000000, 125000000, 25000000, 25000000};
volatile ee_s32 seed1_volatile, seed2_volatile, seed3_volatile, seed4_volatile, seed5_volatile;
static jmp_buf finished;
static const unsigned char *input;
static const char *scenario;
static unsigned calls;
static uint64_t elapsed;
int board_init(void) { return 0; }
void board_puts(const char *s) { fputs(s, stdout); }
void board_u64(uint64_t n) { printf("%llu", (unsigned long long)n); }
void board_ready(void) { puts("READY app=coremark"); }
int board_getchar(void) {
    if (!*input) longjmp(finished, 1);
    return *input++;
}
int coremark_run(void) {
    calls++;
    if (seed3_volatile != 0x66 || seed5_volatile != 0 ||
        seed1_volatile != seed2_volatile ||
        (seed1_volatile != 0 && seed1_volatile != 0x3415)) abort();
    elapsed = (uint64_t)seed4_volatile * 100000;
    if (!strcmp(scenario, "long") && seed4_volatile != 32) elapsed = UINT64_C(4294967313);
    if (!strcmp(scenario, "retry") && calls == 2) elapsed = 450000000;
    if (!strcmp(scenario, "zero")) elapsed = 0;
    return 0;
}
CORE_TICKS get_time(void) { return elapsed; }
int main(int argc, char **argv) {
    if (argc != 3) return 2;
    input = (const unsigned char *)argv[1]; scenario = argv[2];
    if (!setjmp(finished)) hgb_board_main();
    return 0;
}
'''


class CoreMarkBoardTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix='coremark-board-')
        root = Path(cls.temp.name)
        stub = root / 'stub.c'
        stub.write_text(HARNESS)
        cls.binaries = {}
        for iterations in (0, 2):
            binary = root / f'loop-{iterations}'
            command = ['cc', '-std=c11', '-O2', '-Wall', '-Wextra', '-Werror',
                       '-D__riscv_xlen=32', '-DPERFORMANCE_RUN=1',
                       f'-DHGB_BOARD_SIM_ITERATIONS={iterations}',
                       '-Isoftware/coremark-board', '-Isoftware/common',
                       '-Ibenchmark/coremark/port', '-Ibenchmark/coremark/vendor/coremark',
                       'software/coremark-board/main.c', str(stub), '-o', str(binary)]
            subprocess.run(command, cwd=ROOT, check=True, capture_output=True, text=True)
            cls.binaries[iterations] = binary

    @classmethod
    def tearDownClass(cls):
        cls.temp.cleanup()

    def execute(self, command='\r\n', scenario='normal', short=False):
        return subprocess.check_output([str(self.binaries[2 if short else 0]), command, scenario], text=True)

    def test_short_two_requests_crlf_and_seeds(self):
        text = self.execute('\r\nV\r\n', short=True)
        self.assertEqual(text.count('READY app='), 3)
        self.assertEqual(text.count('CM_BEGIN '), 2)
        self.assertIn('CM_BEGIN mode=performance iterations=2', text)
        self.assertIn('CM_BEGIN mode=validation iterations=2', text)
        self.assertEqual(text.count(' formal=0'), 2)
        self.assertNotIn('formal=1', text)

    def test_invalid_command_then_recovery(self):
        text = self.execute('wrong\r\nP\n', short=True)
        self.assertEqual(text.count('DONE status=bad_command'), 1)
        self.assertEqual(text.count('CM_BEGIN '), 1)
        self.assertEqual(text.count('READY app='), 3)

    def test_formal_calibration_uses_real_hz(self):
        text = self.execute()
        self.assertIn('CAL_BEGIN mode=performance iterations=32', text)
        self.assertIn('CM_BEGIN mode=performance iterations=12000', text)
        self.assertIn('roi_cycles=1200000000 core_hz=100000000 formal=1', text)
        self.assertIn('DONE status=completed', text)

    def test_64_bit_result_not_truncated(self):
        text = self.execute(scenario='long')
        self.assertIn('roi_cycles=4294967313 core_hz=100000000 formal=1', text)

    def test_short_formal_attempt_retries(self):
        text = self.execute(scenario='retry')
        self.assertIn('roi_cycles=450000000 core_hz=100000000 formal=0', text)
        self.assertIn('CM_RETRY reason=duration', text)
        self.assertIn('CM_BEGIN mode=performance iterations=24000', text)
        self.assertIn('roi_cycles=2400000000 core_hz=100000000 formal=1', text)
        self.assertEqual(text.count('DONE '), 1)

    def test_zero_timer_does_not_publish_score(self):
        text = self.execute(scenario='zero')
        self.assertIn('DONE status=timer_error', text)
        self.assertNotIn('CM_RESULT', text)


class CoreMarkVendorRepeatTest(unittest.TestCase):
    """Run the unchanged algorithms repeatedly; timer values are deterministic stubs."""

    def test_actual_vendor_reinitializes_performance_and_validation(self):
        stub = r'''
#include <setjmp.h>
#include <stdio.h>
#include "board.h"
#include "benchmark_runtime.h"
struct hgb_soc_clocks board_clocks = {100000000, 100000000, 125000000, 60000000, 60000000};
static jmp_buf finished;
static const unsigned char *input = (const unsigned char *)"\r\nV\r\nP\r\nV\r\n";
static benchmark_cycle_t cycles;
benchmark_cycle_t benchmark_read_cycle(void) { cycles += 100000; return cycles; }
void benchmark_putchar(char value) { putchar(value); }
void board_puts(const char *text) { fputs(text, stdout); }
void board_u64(uint64_t value) { printf("%llu", (unsigned long long)value); }
int board_init(void) { return 0; }
void board_ready(void) {
    puts("READY app=coremark version=1 firmware=vendor-repeat-test core_hz=100000000 "
         "sys_hz=100000000 ddr_hz=125000000 periph_hz=60000000 "
         "memory=tcm opt=-O2 baud=115200 test_only=1");
}
int board_getchar(void) {
    if (!*input) longjmp(finished, 1);
    return *input++;
}
int main(void) {
    if (!setjmp(finished)) hgb_board_main();
    return 0;
}
'''
        sources = ['software/coremark-board/main.c', 'software/coremark-board/port.c',
                   'benchmark/coremark/port/ee_printf.c',
                   *[f'benchmark/coremark/vendor/coremark/{name}.c' for name in
                     ('core_main', 'core_list_join', 'core_matrix', 'core_state', 'core_util')]]
        with tempfile.TemporaryDirectory(prefix='coremark-vendor-repeat-') as directory:
            temporary = Path(directory)
            harness = temporary / 'stub.c'
            harness.write_text(stub)
            objects = []
            flags = ['-std=c11', '-O2', '-D__riscv_xlen=64', '-DPERFORMANCE_RUN=1',
                     '-DHGB_BOARD_SIM_ITERATIONS=2', '-DTOTAL_DATA_SIZE=2000',
                     '-Isoftware/coremark-board', '-Isoftware/common',
                     '-Isoftware/common/baremetal', '-Ibenchmark/coremark/port',
                     '-Ibenchmark/coremark/vendor/coremark']
            for index, source in enumerate(sources):
                object_path = temporary / f'{index}.o'
                rename = ['-Dmain=coremark_run'] if source.endswith('/core_main.c') else []
                subprocess.run(['cc', *flags, *rename, '-c', source, '-o', str(object_path)],
                               cwd=ROOT, check=True, capture_output=True, text=True)
                objects.append(str(object_path))
            binary = temporary / 'vendor-loop'
            subprocess.run(['cc', *flags, str(harness), *objects, '-o', str(binary)],
                           cwd=ROOT, check=True, capture_output=True, text=True)
            text = subprocess.check_output([str(binary)], text=True)
        runs = re.findall(r'CM_BEGIN mode=(\w+) iterations=2\n(.*?)DONE status=short',
                          text, re.DOTALL)
        self.assertEqual([mode for mode, _ in runs],
                         ['performance', 'validation', 'performance', 'validation'])
        expected = {'performance': ('e9f5', 'e714', '1fd7', '8e3a'),
                    'validation': ('18f2', 'e3c1', '0747', '8d84')}
        for mode, report in runs:
            crc = [re.search(r'(?:\[0\])?' + name + r'\s*:\s*0x([0-9a-f]+)', report).group(1)
                   for name in ('seedcrc', 'crclist', 'crcmatrix', 'crcstate')]
            self.assertEqual(tuple(crc), expected[mode])
            self.assertRegex(report, r'\[0\]crcfinal\s*:\s*0x[0-9a-f]+')
            self.assertNotRegex(report, r'ERROR! (list|matrix|state) crc')
            self.assertIn('roi_cycles=100000 core_hz=100000000 formal=0', report)
        self.assertEqual(text.count('READY app='), 5)
        spec = importlib.util.spec_from_file_location('coremark_host', ROOT / 'scripts/coremark/host.py')
        host = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(host)
        report = host.decode(text)
        self.assertTrue(report['valid'], report)
        self.assertEqual(len(report['requests']), 4)
        self.assertTrue(all(request['valid'] and not request['official']
                            for request in report['requests']))


if __name__ == '__main__':
    unittest.main()
