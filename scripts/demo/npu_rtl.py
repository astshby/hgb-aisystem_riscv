"""ctypes interface to the explicit AXI/CDC/NPU RTL co-simulation backend."""
import ctypes as c
from pathlib import Path


class Conv(c.Structure):
    _fields_=[('input',c.POINTER(c.c_int8)),('weight',c.POINTER(c.c_int8)),
              ('bias',c.POINTER(c.c_int32)),('output',c.POINTER(c.c_int32)),
              *[(name,c.c_uint32) for name in ('width','height','cin','cout','kernel','stride','pad')]]


class Stats(c.Structure):
    _fields_=[(name,c.c_uint64) for name in ('sys_cycles','npu_cycles','reads','writes','error_responses',
        'response_stalls','aw_count','w_count','b_count','ar_count','r_count','maximum_transaction_cycles')]


class RtlNPU:
    def __init__(self,library,sys_period_ps=10000,npu_period_ps=10000,phase_ps=1700,seed=1):
        self.library=Path(library);self.lib=c.CDLL(str(self.library.resolve()));p=c.c_void_p;u=c.c_uint32;q=c.c_uint64
        self.lib.yolo_npu_rtl_create.argtypes=[q,q,q,u];self.lib.yolo_npu_rtl_create.restype=p
        self.lib.yolo_npu_rtl_destroy.argtypes=[p];self.lib.yolo_npu_rtl_destroy.restype=None
        self.lib.yolo_npu_rtl_reset.argtypes=[p];self.lib.yolo_npu_rtl_reset.restype=c.c_int
        self.lib.yolo_npu_rtl_transaction.argtypes=[p,c.c_int,u,u,u,u,u,c.POINTER(u)];self.lib.yolo_npu_rtl_transaction.restype=c.c_int
        self.lib.yolo_npu_rtl_nread.argtypes=[p,u];self.lib.yolo_npu_rtl_nread.restype=u
        self.lib.yolo_npu_rtl_nwrite.argtypes=[p,u,u];self.lib.yolo_npu_rtl_nwrite.restype=None
        self.lib.yolo_npu_rtl_error.argtypes=[p];self.lib.yolo_npu_rtl_error.restype=c.c_int
        self.lib.yolo_npu_rtl_clear_error.argtypes=[p];self.lib.yolo_npu_rtl_clear_error.restype=None
        self.lib.yolo_npu_rtl_get_stats.argtypes=[p,c.POINTER(Stats)];self.lib.yolo_npu_rtl_get_stats.restype=None
        self.lib.yolo_npu_rtl_conv.argtypes=[p,c.POINTER(Conv)];self.lib.yolo_npu_rtl_conv.restype=c.c_int
        self.handle=self.lib.yolo_npu_rtl_create(sys_period_ps,npu_period_ps,phase_ps,seed)
        if not self.handle:raise MemoryError('cannot create NPU RTL context')

    def close(self):
        if self.handle:self.lib.yolo_npu_rtl_destroy(self.handle);self.handle=None

    def __enter__(self):return self
    def __exit__(self,*_):self.close()
    def stats(self):
        stats=Stats();self.lib.yolo_npu_rtl_get_stats(self.handle,c.byref(stats))
        return {name:getattr(stats,name) for name,_ in Stats._fields_}
    def read(self,offset):
        result=self.lib.yolo_npu_rtl_nread(self.handle,offset)
        error=self.lib.yolo_npu_rtl_error(self.handle)
        if error:raise RuntimeError(f'NPU AXI read offset={offset:x} error={error}')
        return result
    def write(self,offset,value):
        self.lib.yolo_npu_rtl_nwrite(self.handle,offset,value)
        error=self.lib.yolo_npu_rtl_error(self.handle)
        if error:raise RuntimeError(f'NPU AXI write offset={offset:x} error={error}')
    def transaction(self,write,address,value=0,strobes=15,size=2,hold=0):
        result=c.c_uint32();error=self.lib.yolo_npu_rtl_transaction(self.handle,write,address,value,strobes,size,hold,c.byref(result))
        return error,result.value
    def clear_error(self):self.lib.yolo_npu_rtl_clear_error(self.handle)
    def reset(self):self.lib.yolo_npu_rtl_reset(self.handle)
    def convolve(self,conv):
        error=self.lib.yolo_npu_rtl_conv(self.handle,c.byref(conv))
        if error:raise RuntimeError(f'NPU convolution error={error} bus_error={self.lib.yolo_npu_rtl_error(self.handle)}')
