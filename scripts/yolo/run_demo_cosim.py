#!/usr/bin/env python3
"""Run original demo C modules through real UART/AXI/NPU/video RTL using a native CPU adapter."""
import argparse
import ctypes as c
import dataclasses
import hashlib
import json
import os
from pathlib import Path
import resource
import shlex
import shutil
import struct
import subprocess
import sys
import time
import zlib

ROOT=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/'scripts/yolo'))
import host
U8=c.c_uint8;U32=c.c_uint32;U64=c.c_uint64;PTR=c.c_void_p


class Config(c.Structure):
    _fields_=[('uart_baud',U32),('random_seed',U32)]


class IOStats(c.Structure):
    _fields_=[(name,U64) for name in ('sys_cycles','ddr_cycles','periph_cycles','npu_cycles','pixel_cycles',
        'uart_rx_bytes','uart_tx_bytes','uart_tx_frame_errors','uart_rx_queued','reads','writes','axi_error',
        'maximum_transaction_cycles','ddr_ar','ddr_aw','ddr_r','ddr_w','ddr_b','frames_complete')]+[
        (name,U32) for name in ('pixel_crc','frame_pixels','frame_sequence','active_buffer','underflow',
        'video_bus_errors','i2c_done','i2c_error','i2c_writes','uart_baud','uart_divisor')]


class AppState(c.Structure):
    _fields_=[(name,U64) for name in ('requests','model_publications','cacheless_clean_calls','frame_id',
        'frame_bytes','model_valid','frame_valid','pool_live','pool_peak','convolutions','nodes',
        'detections','display_publications','display_error','tiles','io_error','reference_layers','reference_outputs')]


class Detection(c.Structure):
    _fields_=[(name,c.c_float) for name in ('x1','y1','x2','y2','score','objectness','class_probability')]+[('class_id',U32)]


def plain(value):return {name:getattr(value,name) for name,_ in value._fields_}
def sha(path):return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def convolution_output_count(model):
    tensor_offset,node_offset=struct.unpack_from('<2I',model,40)
    node_count=struct.unpack_from('<I',model,20)[0];outputs=0
    for index in range(node_count):
        operation,tensor=struct.unpack_from('<2I',model,node_offset+index*64)
        if operation==1:
            channels,height,width=struct.unpack_from('<3I',model,tensor_offset+tensor*32)
            outputs+=channels*height*width
    return outputs


def build_app(io_library,output,logs):
    library=output/'libyolo_demo_app.so'
    sources=['tb/yolo/yolo_demo_app.c','software/yolo/demo_protocol.c','software/yolo/network_service.c',
        'software/yolo/network_pool.c','software/yolo/network.c','software/yolo/conv_schedule.c','software/yolo/video_service.c']
    headers=['tb/yolo/yolo_demo_app.h','tb/yolo/yolo_demo_io.h','software/yolo/demo_protocol.h',
        'software/yolo/network_service.h','software/yolo/network_pool.h','software/yolo/network.h',
        'software/yolo/conv_schedule.h','software/yolo/video_service.h','software/common/soc_clocks.h',
        'software/common/soc_capabilities.h','tb/yolo/ms7210_registers.hex','scripts/yolo/host.py',
        'scripts/yolo/run_demo_cosim.py']
    frozen=output/'source'
    for name in sources+headers:
        target=frozen/name;target.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(ROOT/name,target)
    command=[os.environ.get('CC','cc'),'-std=c11','-shared','-fPIC','-O3','-fno-fast-math','-ffp-contract=off',
        '-Wall','-Wextra','-Werror','-Itb/yolo','-Isoftware/yolo','-Isoftware/common',*sources,
        '-L'+str(io_library.parent),'-Wl,-rpath,'+str(io_library.parent),'-l:'+io_library.name,
        '-Wl,--wrap=yolo_conv_s8','-lm','-o',str(library)]
    with (logs/'app-build.log').open('w') as stream:
        stream.write(shlex.join(command)+'\n');stream.flush()
        subprocess.run(command,cwd=frozen,check=True,stdout=stream,stderr=subprocess.STDOUT)
    receipt=dict(command=command,source_sha256={name:sha(ROOT/name) for name in sources+headers},
        app_library_sha256=sha(library),io_library_sha256=sha(io_library),
        source_base_commit=subprocess.check_output(['git','rev-parse','HEAD'],cwd=ROOT,text=True).strip(),
        source_snapshot=str(frozen),scope='Native x86-64 C application adapter; board application modules are unchanged, no RISC-V ELF execution')
    (logs/'app-build.json').write_text(json.dumps(receipt,indent=2)+'\n')
    return library,receipt


class SerialRTL:
    def __init__(self,io_library,app_library,model,baud,output,logs):
        self.output=output;self.logs=logs;self.raw=bytearray();self.events=[];self.io=None;self.app=None
        self.side=struct.unpack_from('<I',model,64)[0]
        self.hw=c.CDLL(str(io_library),mode=c.RTLD_GLOBAL);self.sw=c.CDLL(str(app_library))
        signatures={
            'yolo_demo_io_open':([c.POINTER(Config)],PTR),
            'yolo_demo_io_close':([PTR],None),
            'yolo_demo_io_take_tx':([PTR,c.POINTER(U8),c.c_size_t],c.c_size_t),
            'yolo_demo_io_step':([PTR,U64],c.c_int),
            'yolo_demo_io_get_stats':([PTR,c.POINTER(IOStats)],None),
            'yolo_demo_io_ram_ptr':([PTR,U32,c.c_size_t],PTR),
            'yolo_demo_io_error':([PTR],c.c_int)}
        for name,(arguments,result) in signatures.items():
            function=getattr(self.hw,name);function.argtypes=arguments;function.restype=result
        signatures={
            'yolo_demo_app_create':([PTR,c.POINTER(U8),c.c_size_t,U32,c.c_char_p],PTR),
            'yolo_demo_app_destroy':([PTR],None),
            'yolo_demo_app_exchange':([PTR,c.POINTER(U8),c.c_size_t],c.c_int),
            'yolo_demo_app_get_state':([PTR,c.POINTER(AppState)],None),
            'yolo_demo_app_publish_current':([PTR],c.c_int),
            'yolo_demo_app_reference_begin':([PTR,c.c_char_p],c.c_int),
            'yolo_demo_app_reference_finish':([PTR,U64],c.c_int),
            'yolo_demo_app_preprocess':([PTR,c.POINTER(U8),c.c_size_t,c.POINTER(c.c_float)],c.c_int)}
        for name,(arguments,result) in signatures.items():
            function=getattr(self.sw,name);function.argtypes=arguments;function.restype=result
        begin=time.monotonic();self.io=self.hw.yolo_demo_io_open(c.byref(Config(baud,79)))
        if not self.io:raise RuntimeError('real I/O RTL open failed')
        array=(U8*len(model)).from_buffer_copy(model)
        self.app=self.sw.yolo_demo_app_create(self.io,array,len(model),baud,str(logs/'app-progress.jsonl').encode())
        if not self.app:raise RuntimeError('C application startup/model validation failed')
        self.events.append(dict(event='startup',seconds=time.monotonic()-begin,stats=self.stats(),state=self.state()))

    def stats(self):
        stats=IOStats();self.hw.yolo_demo_io_get_stats(self.io,c.byref(stats));return plain(stats)
    def state(self):
        state=AppState();self.sw.yolo_demo_app_get_state(self.app,c.byref(state));return plain(state)
    def write(self,data):
        before=self.stats();begin=time.monotonic();array=(U8*len(data)).from_buffer_copy(data)
        error=self.sw.yolo_demo_app_exchange(self.app,array,len(data));after=self.stats()
        kind=int.from_bytes(data[4:8],'little')>>16
        event=dict(event='packet',kind=kind,bytes=len(data),seconds=time.monotonic()-begin,
                   sys_cycles=after['sys_cycles']-before['sys_cycles'],stats=after,state=self.state())
        self.events.append(event)
        with (self.logs/'app-packets.jsonl').open('a') as stream:stream.write(json.dumps(event)+'\n')
        if error:raise RuntimeError(f'C application/real UART failed error={error} kind={kind} stats={after}')
        return len(data)
    def read(self,count):
        if count<=0:return b''
        array=(U8*count)();received=self.hw.yolo_demo_io_take_tx(self.io,array,count)
        if not received:
            error=self.hw.yolo_demo_io_step(self.io,512)
            if error:raise RuntimeError('real I/O step failed error='+str(error))
            received=self.hw.yolo_demo_io_take_tx(self.io,array,count)
        data=bytes(array[:received]);self.raw.extend(data);return data
    def framebuffer(self,address):
        ptr=self.hw.yolo_demo_io_ram_ptr(self.io,address,1920*1080*4)
        if not ptr:raise RuntimeError('framebuffer address outside shared DDR')
        xrgb=memoryview(c.string_at(ptr,1920*1080*4));rgb=bytearray(1920*1080*3)
        rgb[0::3]=xrgb[2::4];rgb[1::3]=xrgb[1::4];rgb[2::3]=xrgb[0::4]
        return rgb
    def preprocess(self):
        target=(U8*(self.side*self.side*3))();ratio=c.c_float()
        if self.sw.yolo_demo_app_preprocess(self.app,target,len(target),c.byref(ratio)):raise RuntimeError('same-source C preprocessing failed')
        return bytes(target),ratio.value
    def close(self):
        (self.logs/'uart-tx.bin').write_bytes(self.raw)
        (self.logs/'app-events.json').write_text(json.dumps(self.events,indent=2)+'\n')
        if self.app:self.sw.yolo_demo_app_destroy(self.app);self.app=None
        if self.io:self.hw.yolo_demo_io_close(self.io);self.io=None


def expected_display(rgb,width,height):
    result=bytearray(1920*1080*3);left=(1920-width)//2;top=(1080-height)//2
    for y in range(height):
        offset=((top+y)*1920+left)*3
        result[offset:offset+width*3]=rgb[y*width*3:(y+1)*width*3]
    return result


def check_display(serial,rgb,width,height,previous_frames=0):
    expected=expected_display(rgb,width,height);crc=zlib.crc32(expected)
    for _ in range(500):
        stats=serial.stats()
        if (stats['frames_complete']>previous_frames and stats['frame_pixels']==1920*1080 and
                stats['pixel_crc']==crc):break
        if stats['underflow'] or stats['video_bus_errors'] or stats['axi_error'] or stats['i2c_error']:
            raise RuntimeError('video/AXI/I2C error '+str(stats))
        if serial.hw.yolo_demo_io_step(serial.io,10000):raise RuntimeError('video frame wait failed')
    else:raise RuntimeError(f'no complete expected HDMI frame crc={crc:08x} stats={serial.stats()}')
    stats=serial.stats();actual=serial.framebuffer(stats['active_buffer'])
    if actual!=expected:raise AssertionError('C XRGB framebuffer differs from centered uploaded/annotated RGB')
    if stats['underflow'] or stats['video_bus_errors'] or stats['axi_error'] or stats['i2c_error']:
        raise AssertionError('display error counters nonzero')
    return dict(crc32=crc,pixels=1920*1080,active_buffer=stats['active_buffer'],stats=stats)


def prepare_reference(args,library,output,logs):
    rgb=args.image_rgb.read_bytes();assert len(rgb)==args.width*args.height*3
    model=args.model.read_bytes();side=struct.unpack_from('<I',model,64)[0]
    sw=c.CDLL(str(library));sw.yolo_network_service_preprocess.argtypes=[c.POINTER(U8),U32,U32,c.POINTER(U8),U32,c.POINTER(c.c_float)]
    sw.yolo_network_service_preprocess.restype=c.c_int
    source=(U8*len(rgb)).from_buffer_copy(rgb);resized=(U8*(side*side*3))();ratio=c.c_float()
    if sw.yolo_network_service_preprocess(source,args.width,args.height,resized,side,c.byref(ratio)):raise RuntimeError('C reference preprocessing failed')
    image=output/f'same-source-input-{side}.rgb';image.write_bytes(bytes(resized))
    command=[str(args.native_runner.resolve()),'--model',str(args.model.resolve()),'--image-rgb',str(image),
             '--output',str(output/'scalar-result.json'),'--trace',str(output/'scalar-trace.bin')]
    with (logs/'scalar.log').open('w') as stdout,(logs/'scalar.stderr').open('w') as stderr:
        subprocess.run(command,cwd=ROOT,stdout=stdout,stderr=stderr,check=True,env=dict(os.environ,OMP_NUM_THREADS='1',OPENBLAS_NUM_THREADS='1'))
    result=json.loads((output/'scalar-result.json').read_text())
    assert result['convolutions']==83 and result['nodes']==266
    boxes=(Detection*len(result['boxes']))()
    for box,value in zip(boxes,result['boxes']):
        box.x1,box.y1,box.x2,box.y2=value['box_xyxy'];box.class_id=value['class_id']
        box.score=value['score'];box.objectness=value['objectness'];box.class_probability=value['class_probability']
    sw.yolo_demo_app_reference_rgb.argtypes=[c.POINTER(U8),U32,U32,c.POINTER(Detection),U32,c.c_float]
    sw.yolo_demo_app_reference_rgb(source,args.width,args.height,boxes,len(boxes),ratio)
    annotated=bytes(source);(output/'expected-annotated.rgb').write_bytes(annotated)
    detections=[dict(class_id=b.class_id,score=b.score,xyxy=[b.x1,b.y1,b.x2,b.y2]) for b in boxes]
    receipt=dict(model_sha256=sha(args.model),image_sha256=sha(args.image_rgb),width=args.width,height=args.height,
        model_side=side,ratio=ratio.value,resized_sha256=sha(image),scalar_command=command,
        native_runner_sha256=sha(args.native_runner),scalar_trace_sha256=sha(output/'scalar-trace.bin'),scalar_result=result,
        detections=detections,annotated_sha256=hashlib.sha256(annotated).hexdigest(),annotated_crc32=zlib.crc32(annotated),
        expected_display_crc32=zlib.crc32(expected_display(annotated,args.width,args.height)),
        preprocessing='Same yolo_network_service_preprocess C as the application; separate from the old416 cv2 reference')
    (output/'reference.json').write_text(json.dumps(receipt,indent=2)+'\n')
    return receipt


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--io-library',type=Path,required=True);parser.add_argument('--model',type=Path,required=True)
    parser.add_argument('--output',type=Path,required=True);parser.add_argument('--logs',type=Path,required=True)
    parser.add_argument('--baud',type=int,default=3000000);parser.add_argument('--mode',choices=('tiny','prepare','full'),default='tiny')
    parser.add_argument('--image-rgb',type=Path);parser.add_argument('--width',type=int);parser.add_argument('--height',type=int)
    parser.add_argument('--native-runner',type=Path);parser.add_argument('--reference',type=Path)
    args=parser.parse_args();os.chdir(ROOT);output=args.output.resolve();logs=args.logs.resolve();output.mkdir(parents=True,exist_ok=False);logs.mkdir(parents=True,exist_ok=False)
    if args.mode in ('prepare','full') and (args.image_rgb is None or not args.width or not args.height):parser.error('prepare/full requires complete raw RGB image/width/height')
    runtime=output/'runtime';runtime.mkdir();frozen_io=runtime/args.io_library.name;shutil.copy2(args.io_library,frozen_io)
    library,build=build_app(frozen_io,output,logs);model=args.model.read_bytes();begin=time.monotonic()
    (logs/'command.json').write_text(json.dumps(dict(argv=sys.argv,cwd=str(ROOT),started_unix=time.time()),indent=2)+'\n')
    (logs/'readelf-native.txt').write_text(subprocess.check_output(['readelf','-h',str(library)],text=True))
    serial=None;receipt=dict(mode=args.mode,uart_baud=args.baud,model_sha256=sha(args.model),model_bytes=len(model),
        model_storage='Startup preloaded shared DDR at0x82000000, validated by the same try_preloaded/publish C APIs. No UART5MB or Flash-loader validation.',
        scope='Original C application/control graph on native x86-64, real UART pins/AXI/DDR-model/NPU/video/I2C RTL. No RISC-V Core or CPU cache.',build=build)
    if args.mode=='prepare':
        if args.native_runner is None:parser.error('prepare requires --native-runner for explicit scalar golden')
        reference=prepare_reference(args,library,output,logs)
        receipt.update(status='PASS',reference=reference,scope='CPU-only same-source scalar golden preparation; no RTL application run')
        (logs/'result.json').write_text(json.dumps(receipt,indent=2)+'\n')
        print('PASS same-source reference preparation side='+str(reference['model_side']));return
    try:
        os.chdir(output/'source')
        serial=SerialRTL(frozen_io,library,model,args.baud,output,logs);client=host.Client(serial,timeout=30)
        ready=client.ready();assert ready.capabilities&host.CAP_DETECT and not ready.valid
        rounds=[]
        if args.mode=='tiny':
            initial=serial.stats();test_ready=client.selftest();assert test_ready.capabilities&host.CAP_DETECT
            for index,(width,height) in enumerate(((32,16),(17,19))):
                rgb=bytes((i*37+index*91)%256 for i in range(width*height*3));start=time.monotonic();before=serial.stats()
                uploaded=client.upload(rgb,width,height);returned,status=client.read_frame();assert returned==rgb
                upload_seconds=time.monotonic()-start;before_display=serial.stats()
                error=serial.sw.yolo_demo_app_publish_current(serial.app)
                if error:raise RuntimeError('original video_service publication failed '+str(error))
                display=check_display(serial,rgb,width,height,before_display['frames_complete'])
                current=client.status();assert current.capabilities&host.CAP_HDMI
                client.request(host.CANCEL);after_cancel=client.ready();assert not after_cancel.valid
                rounds.append(dict(width=width,height=height,bytes=len(rgb),crc32=zlib.crc32(rgb),frame_id=uploaded.frame_id,
                    uart_roundtrip_seconds=upload_seconds,sys_cycles_uart_roundtrip=before_display['sys_cycles']-before['sys_cycles'],
                    display=display,state=serial.state(),note='Tiny directed display publication calls original video_service directly; no DETECT/full-network assertion.'))
                print('PASS tiny real UART+video',width,height,'A/B',hex(display['active_buffer']),'crc',hex(display['crc32']),flush=True)
            assert rounds[0]['display']['active_buffer']!=rounds[1]['display']['active_buffer']
            assert serial.state()['model_publications']==1 and serial.state()['pool_live']==0
            receipt.update(status='PASS',rounds=rounds,initial_stats=initial,actual_full_network_requests=0)
        else:
            if not args.reference:raise ValueError('full requires independent --reference with scalar-trace.bin')
            rgb=args.image_rgb.read_bytes();assert len(rgb)==args.width*args.height*3
            client.upload(rgb,args.width,args.height);resized,ratio=serial.preprocess();(output/f'same-source-input-{serial.side}.rgb').write_bytes(resized)
            (output/'preprocess.json').write_text(json.dumps(dict(ratio=ratio,input_sha256=hashlib.sha256(resized).hexdigest()),indent=2)+'\n')
            # Long execution is explicit --mode full; the tiny default never starts 83 convolutions.
            if serial.sw.yolo_demo_app_reference_begin(serial.app,str(args.reference.resolve()/'scalar-trace.bin').encode()):raise RuntimeError('cannot install scalar INT32 observer')
            before=serial.stats();detection=client.detect();annotated,status=client.read_frame();(output/'annotated.rgb').write_bytes(annotated)
            state=serial.state()
            if state['convolutions']!=83 or state['nodes']!=266:raise AssertionError('full model graph did not execute83 Conv/266 nodes')
            if args.reference:
                reference=json.loads((args.reference/'reference.json').read_text())
                if reference['model_sha256']!=sha(args.model) or reference['image_sha256']!=sha(args.image_rgb):raise AssertionError('golden model/image differs')
                if reference['resized_sha256']!=hashlib.sha256(resized).hexdigest():raise AssertionError('C preprocessing differs from scalar input')
                if detection['detections']!=reference['detections']:raise AssertionError('real NPU application detection differs from scalar golden')
                if annotated!=(args.reference/'expected-annotated.rgb').read_bytes():raise AssertionError('UART annotated RGB differs from scalar/C-draw golden')
            expected_outputs=convolution_output_count(model)
            if serial.sw.yolo_demo_app_reference_finish(serial.app,expected_outputs):raise AssertionError('INT32 observer incomplete or scalar trace has trailing bytes')
            display=check_display(serial,annotated,args.width,args.height,before['frames_complete'])
            after_first=serial.stats();tiles_first=serial.state()['tiles'];cached=client.detect()
            if (cached['detections']!=detection['detections'] or serial.state()['reference_outputs']!=expected_outputs or
                    serial.state()['tiles']!=tiles_first):raise AssertionError('cached result differs or performed another convolution')
            current=client.status();assert current.valid
            client.request(host.CANCEL);cancelled=client.ready();assert not cancelled.valid
            assert serial.state()['model_publications']==1 and serial.state()['pool_live']==0
            receipt.update(status='PASS',detection=detection,display=display,frame_crc32=zlib.crc32(annotated),
                actual_full_network_requests=1,cached_detection=cached,after_first_stats=after_first,
                cached_request_note='Second DETECT reuses the first inference; STATUS and CANCEL then genuine READY. It is not a second83Conv inference.')
        receipt.update(final_stats=serial.stats(),final_state=serial.state(),elapsed_seconds=time.monotonic()-begin,
            peak_rss_kib=resource.getrusage(resource.RUSAGE_SELF).ru_maxrss)
    except Exception as error:
        receipt.update(status='FAIL',error=repr(error),elapsed_seconds=time.monotonic()-begin,
            final_stats=serial.stats() if serial and serial.io else None,final_state=serial.state() if serial and serial.app else None)
        raise
    finally:
        if serial:serial.close()
        (logs/'result.json').write_text(json.dumps(receipt,indent=2)+'\n')
    print('PASS original C application I/O co-simulation mode='+args.mode+' evidence='+str(logs/'result.json'))


if __name__=='__main__':main()
