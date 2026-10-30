"""Exercise persistent MiniMind software; native eight-layer tests need explicit local assets."""
import importlib.util
import json
import os
from pathlib import Path
import resource
import struct
import subprocess
import tempfile
import unittest
import zlib

ROOT=Path(__file__).resolve().parents[2]
SPEC=importlib.util.spec_from_file_location('minimind_uart',ROOT/'scripts/demo/minimind_uart.py')
host=importlib.util.module_from_spec(SPEC);SPEC.loader.exec_module(host)
READY='READY app=minimind version=1 layers=8 assets_loaded=1 backend=cpu context=64 max_new_tokens=1 prompt_bytes=512 live_bytes=100\n'
REPORT=READY+'BEGIN input_tokens=2\nTOKEN id=100 bytes=3 hex=e4bda0\nDONE status=ok input_tokens=2 generated=1 position=2 live_bytes=100\n'+READY


class MiniMindProtocolTest(unittest.TestCase):
    def test_two_responses_unicode_and_crlf(self):
        text=REPORT+REPORT[len(READY):]
        report=host.decode(text.replace('\n','\r\n'))
        self.assertTrue(report['valid']);self.assertEqual(len(report['responses']),2)
        self.assertEqual([r['text'] for r in report['responses']],['你','你'])

    def test_token_size_vocabulary_and_duplicate_fields(self):
        for change in ('TOKEN id=100 bytes=2 hex=e4bda0','TOKEN id=6400 bytes=3 hex=e4bda0','TOKEN id=100 id=101 bytes=3 hex=e4bda0'):
            with self.subTest(change=change):
                self.assertFalse(host.decode(REPORT.replace('TOKEN id=100 bytes=3 hex=e4bda0',change))['valid'])

    def test_unreleased_allocations_rejected(self):
        self.assertFalse(host.decode(REPORT.replace('position=2 live_bytes=100','position=2 live_bytes=101'))['valid'])
        self.assertFalse(host.decode(REPORT[:-len(READY)]+READY.replace('live_bytes=100','live_bytes=101'))['valid'])

    def test_requires_done_and_next_ready(self):
        self.assertFalse(host.decode(REPORT[:-len(READY)])['valid'])
        self.assertFalse(host.decode(REPORT.replace('DONE status=ok input_tokens=2 generated=1 position=2 live_bytes=100\n',''))['valid'])

    def test_asset_header_bounded_and_crc_checked(self):
        with tempfile.TemporaryDirectory(prefix='mm3-header-') as directory:
            paths=[]
            for magic in (b'MM3INT01',b'MM3TOK01'):
                data=bytearray(68);data[:8]=magic;struct.pack_into('<I',data,8,1);struct.pack_into('<Q',data,16,len(data));struct.pack_into('<I',data,64,zlib.crc32(data[:64]))
                path=Path(directory)/magic.decode();path.write_bytes(data);paths.append(path)
            header=host.asset_header(*paths)
            self.assertEqual(len(header),28)
            self.assertEqual(struct.unpack('<6I',header[:24]),(0x3141334d,1,0x81000000,68,0x85000000,68))
            self.assertEqual(zlib.crc32(header[:24]),struct.unpack_from('<I',header,24)[0])
            data=bytearray(paths[0].read_bytes());data[30]^=1;paths[0].write_bytes(data)
            with self.assertRaises(ValueError):host.asset_header(*paths)


@unittest.skipUnless(os.environ.get('MM3_DEMO_ASSETS') and os.environ.get('MM3_DEMO_OUT'),
                     'set MM3_DEMO_ASSETS and MM3_DEMO_OUT for actual model tests')
class MiniMindNativeTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.assets=Path(os.environ['MM3_DEMO_ASSETS']);cls.output=Path(os.environ['MM3_DEMO_OUT'])
        subprocess.run(['bash','scripts/demo/build_minimind.sh'],cwd=ROOT,check=True,capture_output=True,text=True)
        cls.command=[str(cls.output/'minimind-interactive'),'--model',str(cls.assets/'model_w8a16_int.bin'),
                     '--tokenizer',str(cls.assets/'tokenizer.bin'),'--max-new-tokens','1']
        original=ROOT/'software/minimind3/c_runtime'
        reference=cls.output/'minimind-original-reference'
        command=['cc','-std=c11','-O3','-fno-fast-math','-ffp-contract=off',
                 '-DMM3_INTEGER_RUNTIME','-DMAX_SEQ_LEN=64','-I'+str(original/'include'),
                 str(original/'main.c'),
                 *[str(original/'src'/f'{name}.c') for name in
                   ('integer_io','tokenizer','integer_math','integer_ops','integer_model','platform_integer')],
                 '-o',str(reference)]
        subprocess.run(command,cwd=ROOT,check=True,capture_output=True,text=True)
        cls.reference=[str(reference),'--model',str(cls.assets/'model_w8a16_int.bin'),
                       '--tokenizer',str(cls.assets/'tokenizer.bin'),'--max-new-tokens','1']

    def execute(self,payload,raw=True,maximum=None):
        def limit():resource.setrlimit(resource.RLIMIT_AS,(256*1024**2,256*1024**2))
        command=self.command+(['--raw'] if raw else [])
        if maximum is not None:command+=['--max-new-tokens',str(maximum)]
        proc=subprocess.run(command,input=payload,capture_output=True,
                            check=True,timeout=30,preexec_fn=limit)
        report=host.decode(proc.stdout.decode())
        self.assertTrue(report['valid'],(report,proc.stderr))
        return report,proc

    def test_real_eight_layers_repeated_kv_reset(self):
        report,proc=self.execute(b'Hi\r\nHi\r\n')
        responses=report['responses'];self.assertEqual(len(responses),2)
        self.assertEqual(responses[0]['tokens'],responses[1]['tokens'])
        self.assertEqual([r['done']['position'] for r in responses],['2','2'])
        self.assertEqual(responses[0]['done']['kv_hash'],responses[1]['done']['kv_hash'])
        self.assertGreater(int(responses[0]['done']['kv_hash']),0)
        self.assertTrue(all(r['done']['status']=='ok' for r in responses))
        self.assertNotIn(b'allocation leak',proc.stderr)

    def test_invalid_utf8_then_recovery(self):
        report,_=self.execute(b'\xff\rHi\r')
        self.assertEqual([r['done']['status'] for r in report['responses']],['tokenize_error','ok'])

    def test_long_line_empty_and_nul_recover(self):
        report,_=self.execute(b'x'*513+b'\r\n\r\na\x00b\rHi\r')
        self.assertEqual([r['done']['status'] for r in report['responses']],['too_long','empty','uart_error','ok'])

    def test_context_limit_then_recovery(self):
        report,_=self.execute(b'~'*512+b'\rHi\r')
        self.assertEqual([r['done']['status'] for r in report['responses']],['context_exhausted','ok'])

    def test_actual_chat_template_chinese(self):
        report,_=self.execute('你好\r'.encode(),raw=False)
        self.assertEqual(report['responses'][0]['done']['status'],'ok')
        self.assertEqual(len(report['responses'][0]['tokens']),1)

    def test_generation_stops_at_remaining_context(self):
        report,_=self.execute(b'~'*63+b'\r',maximum=2)
        done=report['responses'][0]['done']
        self.assertEqual(done['status'],'ok')
        self.assertEqual(done['input_tokens'],'63')
        self.assertEqual(done['generated'],'1')

    def test_matches_original_author_entry(self):
        report,_=self.execute(b'Hi\r')
        ids=self.output/'reference-output-ids.txt'
        original=subprocess.run(self.reference+['--raw','--prompt','Hi','--output-ids',str(ids)],
                                capture_output=True,check=True,timeout=30)
        self.assertEqual([int(t['id']) for t in report['responses'][0]['tokens']],
                         [int(token) for token in ids.read_text().split()])
        self.assertEqual(report['responses'][0]['text'].encode(),original.stdout.rstrip(b'\n'))


if __name__=='__main__':unittest.main()
