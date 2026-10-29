#!/usr/bin/env python3
"""Check unmodified NPU1 RTL through the real scalar AXI master/CDC against C integer convolution."""
import argparse
import ctypes as c
import hashlib
import json
import os
from pathlib import Path
import resource
import subprocess
import time
from npu_rtl import RtlNPU,Conv

ROOT=Path(__file__).resolve().parents[2]
CASES=[(1,1,1,1,1,1,0),(5,4,3,17,3,1,1),(8,7,9,19,3,2,1),
       (17,16,9,17,3,2,1),(7,5,17,7,1,2,0),(3,2,768,17,3,2,1),(5,3,768,17,1,1,0)]


def sha(path):return hashlib.sha256(path.read_bytes()).hexdigest()


def check_registers(npu):
    assert npu.read(0)==0x4e505531 and npu.read(4)==0x10000
    assert npu.read(0x14)==24576 and npu.read(0x18)==864
    assert npu.transaction(True,0x20000064,0x11223344,hold=8)[0]==0
    assert npu.transaction(True,0x20000064,0xaabbccdd,strobes=3,hold=5)[0]==0
    assert npu.transaction(False,0x20000064,hold=9)==(0,0x1122ccdd)
    assert npu.transaction(False,0x20010000,hold=4)[0]==1
    npu.clear_error()
    assert npu.transaction(False,0x20000300,hold=6)[0]==2
    npu.clear_error()
    assert npu.transaction(True,0x20000061,0x5500,strobes=2,size=0,hold=3)[0]==1
    npu.clear_error()
    assert npu.read(0)==0x4e505531


def run_case(npu,reference,shape):
    w,h,cin,cout,kernel,stride,pad=shape;ow=(w+pad*2-kernel)//stride+1;oh=(h+pad*2-kernel)//stride+1
    source=(c.c_int8*(w*h*cin))(*[((i*37+13)%255)-127 for i in range(w*h*cin)])
    weights=(c.c_int8*(cout*cin*kernel*kernel))(*[((i*53+7)%255)-127 for i in range(cout*cin*kernel*kernel)])
    bias=(c.c_int32*cout)(*[-35+i*19 for i in range(cout)])
    output=(c.c_int32*(ow*oh*cout))();golden=(c.c_int32*(ow*oh*cout))()
    conv=Conv(source,weights,bias,golden,w,h,cin,cout,kernel,stride,pad)
    assert reference.yolo_network_scalar_conv(None,c.byref(conv))==0
    conv.output=output;before=npu.stats();start=time.monotonic();npu.convolve(conv);elapsed=time.monotonic()-start;after=npu.stats()
    actual=bytes(output);expected=bytes(golden)
    if actual!=expected:
        index=next(i for i,(a,b) in enumerate(zip(output,golden)) if a!=b)
        raise AssertionError(f'INT32 mismatch shape={shape} index={index} RTL={output[index]} C={golden[index]}')
    return dict(shape=dict(zip(('width','height','cin','cout','kernel','stride','pad'),shape)),outputs=ow*oh*cout,
        output_sha256=hashlib.sha256(actual).hexdigest(),elapsed_seconds=elapsed,
        sys_cycles=after['sys_cycles']-before['sys_cycles'],npu_cycles=after['npu_cycles']-before['npu_cycles'],
        transactions=after['reads']+after['writes']-before['reads']-before['writes'],
        reads=after['reads']-before['reads'],writes=after['writes']-before['writes'])


def main():
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--library',type=Path,required=True)
    parser.add_argument('--output',type=Path,required=True);parser.add_argument('--build-dir',type=Path,required=True)
    parser.add_argument('--quick',action='store_true',help='one clock vector and first five shapes')
    args=parser.parse_args();args.build_dir.mkdir(parents=True,exist_ok=True)
    scalar=args.build_dir/'libyolo_scalar_reference.so'
    command=[os.environ.get('CC','cc'),'-std=c11','-O3','-shared','-fPIC','-fno-fast-math','-ffp-contract=off',
        '-Isoftware/yolo','software/yolo/network.c','-lm','-o',str(scalar.resolve())]
    subprocess.run(command,cwd=ROOT,check=True)
    reference=c.CDLL(str(scalar.resolve()));reference.yolo_network_scalar_conv.argtypes=[c.c_void_p,c.POINTER(Conv)];reference.yolo_network_scalar_conv.restype=c.c_int
    clocks=[(10000,10000,1700),(12500,10000,1700),(10000,8000,2300)]
    if args.quick:clocks=clocks[:1]
    results=[];start=time.monotonic()
    for index,(sys_period,npu_period,phase) in enumerate(clocks):
        with RtlNPU(args.library,sys_period,npu_period,phase,index+19) as npu:
            check_registers(npu);cases=[]
            for shape in CASES[:5] if args.quick else CASES:
                record=run_case(npu,reference,shape);cases.append(record)
                print('PASS real NPU AXI/CDC',sys_period,npu_period,shape,'outputs',record['outputs'],'seconds',round(record['elapsed_seconds'],3),flush=True)
            stats=npu.stats();assert stats['aw_count']==stats['w_count']==stats['b_count']==stats['writes']
            assert stats['ar_count']==stats['r_count']==stats['reads'] and stats['response_stalls']>0
            assert stats['error_responses']==3
            npu.reset();assert npu.read(0)==0x4e505531
            results.append(dict(sys_period_ps=sys_period,npu_period_ps=npu_period,phase_ps=phase,cases=cases,
                                transactions=stats,coordinated_reset=True))
    receipt=dict(status='PASS',scope='Actual scalar AXI master, independent-clock FIFO CDC and unchanged NPU1 RTL. C supplies convolution schedule; no RV32 core or full SoC.',
        library=str(args.library),library_sha256=sha(args.library),scalar_reference_sha256=sha(scalar),reference_command=command,
        cases=sum(len(x['cases']) for x in results),checked_output_int32=sum(c['outputs'] for x in results for c in x['cases']),
        elapsed_seconds=time.monotonic()-start,peak_rss_kib=resource.getrusage(resource.RUSAGE_SELF).ru_maxrss,clocks=results)
    args.output.write_text(json.dumps(receipt,indent=2)+'\n');print('PASS NPU RTL matrix',receipt['cases'],'shapes/clock combinations,',receipt['checked_output_int32'],'exact INT32 values')


if __name__=='__main__':main()
