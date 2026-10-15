#!/usr/bin/env python3
"""Exercise the exact loader C receiver using adversarial packets and a WB memory backend."""
import ctypes
from pathlib import Path
import struct
import sys
sys.dont_write_bytecode=True
sys.path.insert(0,str(Path(__file__).resolve().parent))
from host import crc, packet

lib=ctypes.CDLL(str(Path(sys.argv[1]).resolve()))
lib.test_receive.argtypes=[ctypes.c_char_p,ctypes.c_uint,ctypes.c_uint,ctypes.c_uint]
def raw(config,entry,segments):
    table=b"".join(struct.pack("<4I",a,n,f,c) for a,n,f,c in segments)
    h=struct.pack("<6I",0x31424748,1,config,entry,len(segments),crc(table))
    return h+struct.pack("<I",crc(h))+table
def run(name,wire,expected,config=32|(1<<16),fault=0,writes=None):
    result=lib.test_receive(wire,len(wire),config,fault)
    entry=ctypes.c_uint32.in_dll(lib,"test_entry").value
    assert result==expected,(name,result,expected)
    assert bool(entry)==(expected==0),(name,hex(entry))
    if writes is not None:
        assert ctypes.c_uint.in_dll(lib,"test_writes").value==writes,name
    print("PASS",name)

data=bytes(range(256))*2
for xlen in (32,64):
    h,blocks=packet(xlen,0x80000000,[(0x80000000,1,data),(0x0110c000,0,b"hot-code")])
    wire=h+b"".join(b+struct.pack("<I",crc(b)) for b in blocks)
    run(f"valid RV{xlen} DDR + DTCM, multiple blocks",wire,0,xlen|(1<<16),writes=520)
    if xlen==32: valid=wire
run("wrong config",valid,3,64|(1<<16),writes=0)
run("bad header CRC",bytes([valid[0]^1])+valid[1:],2,writes=0)
for name,a,n,f,entry in [
    ("loader overwrite",0x01000000,16,1,0x01000000),
    ("stack overwrite",0x0110a000,16,0,0x80000000),
    ("scratch overwrite",0x8003f000,16,1,0x8003f000),
    ("32-bit wrap",0xfffffff0,0x40,1,0xfffffff0),
    ("zero segment",0x80000000,0,1,0x80000000),
    ("unaligned entry",0x80000000,16,1,0x80000001),
    ("non executable entry",0x80000000,16,0,0x80000000)]:
    run(name,raw(32|(1<<16),entry,[(a,n,f,0)]),4,writes=0)
run("overlap",raw(32|(1<<16),0x80000000,[(0x80000000,32,1,0),(0x80000010,32,0,0)]),5,writes=0)
bad=bytearray(valid); bad[28]^=1
run("bad table CRC",bytes(bad),6,writes=0)
bad=bytearray(valid); bad[60+12]^=1
run("bad block CRC",bytes(bad),6)
bad_segment=raw(32|(1<<16),0x80000000,[(0x80000000,len(data),1,0)])
bad_segment+=b''.join(data[i:i+128]+struct.pack('<I',crc(data[i:i+128])) for i in range(0,len(data),128))
run("segment CRC independent of block CRC",bad_segment,6)
run("receive timeout",valid[:-3],1)
run("cache publication failure",valid,7,fault=1)
run("DDR readback corruption",valid,8,fault=2)
run("valid retry after failures",valid,0)
for name in sys.argv[2:]:
    wire=Path(name).read_bytes()
    config=struct.unpack_from('<I',wire,8)[0]
    run(f"actual ELF packet {Path(name).name}",wire,0,config)
