"""Exercise CPU framebuffer ownership and publication against a deterministic control-device substitute."""
import ctypes as C
import os
from pathlib import Path
import subprocess
import unittest

ROOT=Path(__file__).resolve().parents[2]
READ=C.CFUNCTYPE(C.c_uint32,C.c_void_p,C.c_uint32)
WRITE=C.CFUNCTYPE(None,C.c_void_p,C.c_uint32,C.c_uint32)
CLEAN=C.CFUNCTYPE(C.c_int,C.c_void_p)
WORDS=1920*1080
A,B=0x83000000,0x83800000

class IO(C.Structure):
    _fields_=[('read',READ),('write',WRITE),('clean',CLEAN),('context',C.c_void_p)]

class Display(C.Structure):
    _fields_=[('io',IO),('buffer',C.POINTER(C.c_uint32)*2),('available',C.c_uint32),
              ('last_error',C.c_uint32),('published',C.c_uint32)]

class VideoServiceTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        out=Path(os.environ.get('YDM_VIDEO_SERVICE_OUT',ROOT/'build/yolo/video-service-tests'))
        out.mkdir(parents=True,exist_ok=True)
        path=out/'display.so'
        subprocess.run(['cc','-shared','-fPIC','-std=c11','-O3','-Wall','-Wextra','-Werror',
                        '-DYOLO_VIDEO_POLLS=16','software/yolo/video_service.c','-o',str(path)],cwd=ROOT,check=True)
        cls.lib=C.CDLL(str(path))
        cls.lib.yolo_video_configure.argtypes=[C.POINTER(Display),C.POINTER(C.c_uint32),C.POINTER(C.c_uint32),IO]
        cls.lib.yolo_video_publish_rgb.argtypes=[C.POINTER(Display),C.POINTER(C.c_uint8),C.c_uint32,C.c_uint32]
        cls.lib.yolo_video_healthy.argtypes=[C.POINTER(Display)]

    def setUp(self):
        self.buffers=[(C.c_uint32*WORDS)(),(C.c_uint32*WORDS)()]
        self.regs={0:0x56494431,4:8,0x20:A,0x24:0}
        self.writes=[];self.cleaned=0;self.clean_error=0
        self.pending=0;self.hold_init=self.hold_commit=self.hold_frame=False
        self.error_after_commit=False;self.poll=0
        def read(_,offset):
            if offset==4:
                if self.hold_init:return 0
                if self.pending:
                    self.pending+=1
                    if self.error_after_commit:self.regs[4]|=64
                    if self.pending>=3 and not self.hold_commit:
                        self.regs[4]&=~2;self.regs[0x20]=self.regs[8];self.pending=0
                return self.regs[4]
            if offset==0x24 and self.regs[4]&1 and not self.pending and not self.hold_frame:
                self.poll+=1
                if self.poll%3==0:self.regs[0x24]+=1
            return self.regs.get(offset,0)
        def write(_,offset,value):
            self.writes.append((offset,value));self.regs[offset]=value
            if offset==0x1c:self.regs[4]|=value&1
            if offset==0x18:self.pending=1;self.regs[4]|=2
        def clean(_):
            self.cleaned+=1
            self.assertNotIn((0x18,1),self.writes)
            return self.clean_error
        self.io=IO(READ(read),WRITE(write),CLEAN(clean),None)
        self.display=Display()
        self.assertEqual(self.lib.yolo_video_configure(C.byref(self.display),*self.buffers,self.io),0)

    def tearDown(self):
        self.display=Display();self.io=IO();self.buffers=None

    def publish(self,color=(1,2,3)):
        pixel=(C.c_uint8*3)(*color)
        return self.lib.yolo_video_publish_rgb(C.byref(self.display),pixel,1,1)

    def test_centered_xrgb_and_completed_scan_before_ready(self):
        self.assertEqual(self.publish(),0)
        index=539*1920+959
        self.assertEqual(self.buffers[0][index],0x010203)
        self.assertEqual(self.buffers[0][index-1],0)
        self.assertEqual(self.cleaned,1)
        self.assertEqual(self.display.published,1)
        self.assertGreater(self.regs[0x24],0)
        self.assertEqual(self.lib.yolo_video_healthy(C.byref(self.display)),1)

    def test_next_frame_only_writes_inactive_bank(self):
        self.assertEqual(self.publish(),0)
        index=539*1920+959;old=self.buffers[0][index]
        self.writes.clear()
        self.assertEqual(self.publish((4,5,6)),0)
        self.assertEqual(self.buffers[0][index],old)
        self.assertEqual(self.buffers[1][index],0x040506)
        self.assertEqual(self.regs[0x20],B)
        self.assertEqual(self.display.published,2)

    def test_cache_error_prevents_commit(self):
        self.clean_error=1
        self.assertEqual(self.publish(),4)
        self.assertNotIn((0x18,1),self.writes)
        self.assertEqual(self.display.published,0)

    def test_existing_video_error_is_reported(self):
        self.regs[4]|=32
        self.assertEqual(self.publish(),2)
        self.assertEqual(self.cleaned,0)

    def test_init_and_ownership_timeouts(self):
        self.hold_init=True
        self.assertEqual(self.publish(),3)
        self.hold_init=False;self.hold_commit=True
        self.assertEqual(self.publish(),6)
        self.assertEqual(self.lib.yolo_video_healthy(C.byref(self.display)),0)

    def test_no_completed_scan_times_out(self):
        self.hold_frame=True
        self.assertEqual(self.publish(),8)
        self.assertEqual(self.display.published,0)

    def test_error_after_commit_prevents_success(self):
        self.error_after_commit=True
        self.assertEqual(self.publish(),5)
        self.assertEqual(self.display.published,0)

if __name__=='__main__': unittest.main()
