"""A simulation process must not pass after emitting a fatal diagnostic."""
from pathlib import Path
import os
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]


class ScoreboardRunnerTest(unittest.TestCase):
    def run_fixture(self, output, exit_code=0):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            scripts = root / 'scripts/verilator'
            scripts.mkdir(parents=True)
            for name in ('run_scoreboard.sh', 'core_build_config.sh'):
                shutil.copyfile(ROOT / 'scripts/verilator' / name, scripts / name)
            tools = root / 'tools'
            tools.mkdir()
            # 只替代编译器和进程输出，不运行RTL；验证真实runner的退出码判定。
            compiler = tools / 'verilator'
            compiler.write_text('''#!/usr/bin/env python3
from pathlib import Path
import os
import sys
args = sys.argv[1:]
directory = Path(args[args.index('-Mdir') + 1])
top = args[args.index('--top-module') + 1]
directory.mkdir(parents=True, exist_ok=True)
binary = directory / ('V' + top)
binary.write_text('#!/usr/bin/env python3\\nimport sys\\nprint(' +
                  repr(os.environ['FIXTURE_OUTPUT']) + ')\\nsys.exit(' +
                  os.environ['FIXTURE_EXIT'] + ')\\n')
binary.chmod(0o755)
''')
            compiler.chmod(0o755)
            env = dict(os.environ, PATH=str(tools) + os.pathsep + os.environ['PATH'],
                       FIXTURE_OUTPUT=output, FIXTURE_EXIT=str(exit_code),
                       RETIRE_ENTRIES='16', SPLIT_ISSUE_QUEUE='1',
                       SCOREBOARD_LOG_ROOT='logs/fixture', SCOREBOARD_BUILD_ROOT='build/fixture')
            result = subprocess.run(['bash', str(scripts / 'run_scoreboard.sh'), '32', 'issue'],
                                    cwd=root, env=env, text=True, capture_output=True)
            self.assertTrue((root / 'logs/fixture').is_dir())
            self.assertTrue((root / 'build/fixture').is_dir())
            return result

    def test_clean_pass(self):
        result = self.run_fixture('PASS tb_scoreboard_issue fixture')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_fatal_after_pass(self):
        result = self.run_fixture('PASS tb_scoreboard_issue fixture\n%Error: late assertion failure')
        self.assertNotEqual(result.returncode, 0)

    def test_successful_process_without_pass(self):
        self.assertNotEqual(self.run_fixture('simulation ended').returncode, 0)

    def test_nonzero_process_after_pass(self):
        self.assertNotEqual(self.run_fixture('PASS tb_scoreboard_issue fixture', 2).returncode, 0)


if __name__ == '__main__':
    unittest.main()
