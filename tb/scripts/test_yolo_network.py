"""C graph operators and repeated real-model software requests; no RTL or FPGA execution."""
import os
from pathlib import Path
import resource
import subprocess
import tempfile
import unittest

ROOT=Path(__file__).resolve().parents[2]


class YoloNetworkTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary=None
        if os.environ.get('YOLO_NETWORK_OUT'):cls.output=Path(os.environ['YOLO_NETWORK_OUT'])
        else:
            cls.temporary=tempfile.TemporaryDirectory(prefix='yolo-network-c-')
            cls.output=Path(cls.temporary.name)
        cls.output.mkdir(parents=True,exist_ok=True)
        flags=['cc','-std=c11','-O3','-fno-fast-math','-ffp-contract=off','-Wall','-Wextra','-Werror','-Isoftware/yolo']
        for name in ('network_ops','network_replay'):
            command=[*flags,'software/yolo/network.c',f'tb/yolo/{name}.c','-lm','-o',str(cls.output/name)]
            subprocess.run(command,cwd=ROOT,check=True,capture_output=True,text=True)

    @classmethod
    def tearDownClass(cls):
        if cls.temporary:cls.temporary.cleanup()

    def test_c_graph_operators(self):
        text=subprocess.check_output([str(self.output/'network_ops')],text=True)
        self.assertIn('PASS YOLO network C operators groups=5',text)

    @unittest.skipUnless(os.environ.get('YOLO_NETWORK_MODEL') and os.environ.get('YOLO_NETWORK_RGB'),
                         'set YOLO_NETWORK_MODEL and YOLO_NETWORK_RGB for real 83-convolution replay')
    def test_two_real_network_requests_and_failure_release(self):
        def limit():resource.setrlimit(resource.RLIMIT_AS,(150*1024**2,150*1024**2))
        command=[str(self.output/'network_replay'),os.environ['YOLO_NETWORK_MODEL'],os.environ['YOLO_NETWORK_RGB']]
        text=subprocess.check_output(command,text=True,timeout=120,preexec_fn=limit)
        (self.output/'network-replay.log').write_text(text)
        self.assertIn('requests=2 convolutions=166',text)
        self.assertIn('live_after_request=0 allocation_failures=4 backend_failure=1 crc_failure=1',text)


if __name__=='__main__':unittest.main()
