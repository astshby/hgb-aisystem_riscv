#!/usr/bin/env python3
"""Offline export. Quantize the locked FP32 model directly; no intermediate mixed-precision model."""
from pathlib import Path
import struct,json,zlib,hashlib,math,argparse
import numpy as np
ROOT=Path(__file__).resolve().parents[1]
def scale(x):
    if x==0:return (1<<30,1)
    frac,e=math.frexp(float(x));m=round(frac*(1<<31))
    if m==(1<<31):m>>=1;e+=1
    return m,e

def main():
    ap=argparse.ArgumentParser();ap.add_argument('--capacity',type=int,default=2048);a=ap.parse_args();assert 1<=a.capacity<=32768
    manifest=json.loads((ROOT/'assets/manifest.json').read_text());old=(ROOT/'assets/model_fp32.bin').read_bytes()
    assert hashlib.sha256(old).hexdigest()==manifest['files']['model_fp32.bin']['sha256'];assert zlib.crc32(old[:-4])==struct.unpack_from('<I',old,len(old)-4)[0]
    b=bytearray(128+93*160);struct.pack_into('<8sIIQ8I2I',b,0,b'MM3INT01',1,93,0,768,2432,8,8,4,96,6400,32768,a.capacity,0)
    b[64:104]=manifest['source']['revision'].encode();struct.pack_into('<IiIi',b,104,*scale(1e-6),*scale(1/math.sqrt(96)));entries=[]
    def add(name,data,rows,cols,dtype,scales=()):
        b.extend(bytes((-len(b))%64));off=len(b);b.extend(data);so=0
        if scales:
            b.extend(bytes((-len(b))%64));so=len(b)
            for s in scales:b.extend(struct.pack('<Ii',*s))
        i=len(entries);struct.pack_into('<96sQQIIIIQ',b,128+i*160,name.encode(),off,rows*cols,rows,cols,dtype,len(scales),so)
        entries.append(dict(name=name,offset=off,shape=[rows,cols],dtype=dtype,scale_count=len(scales),scale_offset=so))
    for t in manifest['tensors']:
        sh=t['shape'];rows=sh[0];cols=sh[1] if len(sh)==2 else 1
        if len(sh)==2:
            v=np.frombuffer(old,dtype='<f4',count=rows*cols,offset=t['offset']).reshape(rows,cols)
            maxima=np.abs(v).max(axis=1)
            sw=np.where(maxima==0,np.float32(1),maxima/np.float32(127)).astype('<f4')
            q=np.clip(np.rint(v.astype(np.float64)/sw[:,None].astype(np.float64)),-127,127).astype('i1')
            data=q.tobytes();sc=[scale(x) for x in sw];dtype=2
        else:
            v=np.frombuffer(old,dtype='<f4',count=rows,offset=t['offset']).astype(np.float64);s=float(np.abs(v).max())/32767 if np.any(v) else 1.;q=np.clip(np.rint(v/s),-32767,32767).astype('<i2');data=q.tobytes();sc=[scale(s)];dtype=3
        add(t['name'],data,rows,cols,dtype,sc)
    exp=np.rint(np.exp(-np.arange(4097)/256.)*(1<<31)).astype('<u4');sig=np.rint(65535/(1+np.exp(-np.arange(-4096,4097)/256.))).astype('<u2')
    rope=np.empty((a.capacity,48,2),dtype='<i2')
    for p in range(a.capacity):
        angle=p*np.power(1e6,-2*np.arange(48)/96.);rope[p,:,0]=np.clip(np.rint(np.cos(angle)*32768),-32767,32767);rope[p,:,1]=np.clip(np.rint(np.sin(angle)*32768),-32767,32767)
    add('__exp',exp.tobytes(),4097,1,4);add('__sigmoid',sig.tobytes(),8193,1,5);add('__rope',rope.tobytes(),a.capacity,96,3)
    b.extend(bytes((-len(b))%64));struct.pack_into('<Q',b,16,len(b)+4);b.extend(struct.pack('<I',zlib.crc32(b)))
    path=ROOT/'assets/model_w8a16_int.bin';path.write_bytes(b)
    report=dict(version=1,source=manifest['source'],source_fp32_sha256=manifest['files']['model_fp32.bin']['sha256'],capacity=a.capacity,bytes=len(b),sha256=hashlib.sha256(b).hexdigest(),scale='uint32 multiplier * 2**(int32 exponent-31)',tensors=entries)
    (ROOT/'assets/integer_manifest.json').write_text(json.dumps(report,indent=2)+'\n')
    print('INTEGER_EXPORT_PASS',len(b),'bytes;',a.capacity,'positions;',len(entries),'tensors/tables')
if __name__=='__main__':main()
