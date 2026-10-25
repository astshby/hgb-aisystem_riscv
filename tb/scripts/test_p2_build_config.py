#!/usr/bin/env python3
"""Check real Make target configuration without invoking Verilator or software builds."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
REAL_BASH = shutil.which('bash')
CORE_KEYS = ('CORE_BACKEND', 'ISSUE_WIDTH', 'RETIRE_ENTRIES', 'MUL_IMPL', 'DIV_IMPL',
             'PREDICTOR_MODE', 'RAS_ENABLE', 'SPLIT_ISSUE_QUEUE', 'INTEGER_QUEUE_ENTRIES',
             'MEMORY_QUEUE_ENTRIES', 'LIMITED_INTEGER_OOO', 'SCHEDULER_FORWARD_MODE',
             'CORE_ISSUE_WIDTH', 'CORE_RETIRE_ENTRIES', 'CORE_PREDICTOR_MODE', 'CORE_RAS_ENABLE')
PROFILE_COMMAND = '''source scripts/verilator/p2_core_config.sh
printf '%s\\n' "$core_backend" "$core_issue_width" "$core_retire_entries" "$MUL_IMPL" "$DIV_IMPL" \\
 "$core_predictor_mode" "$core_ras_enable" "$core_split_issue_queue" "$core_integer_queue_entries" \\
 "$core_memory_queue_entries" "$core_limited_integer_ooo" "$core_scheduler_forward_mode" "$p2_core_build_tag"
'''
FIELDS = ('backend', 'issue', 'retire', 'mul', 'div', 'predictor', 'ras', 'split',
          'integer', 'memory', 'ooo', 'forward', 'tag')
P0 = ('scoreboard', '2', '16', '0', '1', '0', '0', '0', '8', '4', '0', '0',
      'm0d1-p0r0q16i2-scoreboard')
# p1_core_config.sh 当前已选择 RAS0/OOO0；历史 P1 配置不覆盖当前入口。
P1 = ('scoreboard', '2', '32', '0', '1', '1', '0', '1', '8', '4', '0', '3',
      'm0d1-p1r0q32i2-scoreboard-s1j8m4-f3')


class P2MakeConfigurationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.bin_dir = Path(self.temporary.name)
        # 真正执行 Makefile；替身只截住最后的 bash runner 调用，再用真实 bash 校验共享配置。
        wrapper = self.bin_dir / 'bash'
        wrapper.write_text(f'''#!{sys.executable}
import json,subprocess,sys
result=subprocess.run([{REAL_BASH!r}, '-euc', {PROFILE_COMMAND!r}], text=True, capture_output=True)
if result.returncode:
    sys.stderr.write(result.stderr)
    sys.exit(result.returncode)
print(json.dumps({{'runner':sys.argv[1:], 'profile':result.stdout.splitlines()}}))
''')
        wrapper.chmod(0o755)
        self.env = {key: value for key, value in os.environ.items()
                    if key not in CORE_KEYS and key not in ('MAKEFLAGS', 'MFLAGS', 'MAKELEVEL')}
        self.env['PATH'] = str(self.bin_dir) + os.pathsep + self.env.get('PATH', '')

    def invoke(self, target, *, overrides=(), environment=None, p1=False):
        env = dict(self.env, **(environment or {}))
        command = ['make', '--no-print-directory', '-s', target, *overrides]
        if p1:
            command = [REAL_BASH, '-euc',
                       'source scripts/verilator/p1_core_config.sh\nexec "$@"', 'profile-check', *command]
        return subprocess.run(command, cwd=ROOT, env=env, text=True, capture_output=True)

    def expect_profile(self, result, expected, runner):
        self.assertEqual(result.returncode, 0, result.stderr)
        record = json.loads(result.stdout)
        self.assertEqual(record['runner'], [runner, '32'])
        self.assertEqual(dict(zip(FIELDS, record['profile'])), dict(zip(FIELDS, expected)))

    def test_bare_p2_targets_use_p0_control_defaults(self):
        for target, runner in [('soc-system-test', 'run_soc_system.sh'), ('soc-axi-test', 'run_axi_system.sh')]:
            with self.subTest(target=target):
                self.expect_profile(self.invoke(target), P0, 'scripts/verilator/' + runner)

    def test_sourced_p1_reaches_both_targets(self):
        for target, runner in [('soc-system-test', 'run_soc_system.sh'), ('soc-axi-test', 'run_axi_system.sh')]:
            with self.subTest(target=target):
                self.expect_profile(self.invoke(target, p1=True), P1, 'scripts/verilator/' + runner)

    def test_cli_overrides_sourced_p1(self):
        expected = list(P1)
        expected[2], expected[4], expected[11] = '8', '0', '2'
        expected[12] = 'm0d0-p1r0q8i2-scoreboard-s1j8m4-f2'
        self.expect_profile(self.invoke('soc-system-test', p1=True,
            overrides=('RETIRE_ENTRIES=8', 'DIV_IMPL=0', 'SCHEDULER_FORWARD_MODE=2')),
            expected, 'scripts/verilator/run_soc_system.sh')

    def test_explicit_environment_is_not_replaced(self):
        expected = list(P0)
        expected[2], expected[4] = '8', '0'
        expected[12] = 'm0d0-p0r0q8i2-scoreboard'
        self.expect_profile(self.invoke('soc-axi-test',
            environment={'CORE_BACKEND': 'scoreboard', 'ISSUE_WIDTH': '2', 'RETIRE_ENTRIES': '8', 'DIV_IMPL': '0'}),
            expected, 'scripts/verilator/run_axi_system.sh')

    def test_explicit_legacy_configuration_is_rejected(self):
        for target in ('soc-system-test', 'soc-axi-test'):
            for mode in ('environment', 'command-line'):
                with self.subTest(target=target, mode=mode):
                    result = self.invoke(target, environment={'CORE_BACKEND': 'legacy'} if mode == 'environment' else {},
                                         overrides=('CORE_BACKEND=legacy',) if mode == 'command-line' else ())
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn('P2 requires a dual-issue scoreboard profile', result.stderr)


if __name__ == '__main__':
    unittest.main()
