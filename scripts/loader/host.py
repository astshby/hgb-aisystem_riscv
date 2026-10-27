#!/usr/bin/env python3
"""Build an HGB1 packet from RISC-V ELF load segments, or send via USB-UART."""
import argparse
import json
import hashlib
from pathlib import Path
import struct
import zlib

def crc(data):
    return zlib.crc32(data) & 0xffffffff

def allowed(address, size):
    return size > 0 and any(lo <= address < hi and size <= hi-address
                           for lo, hi in [(0x80000000, 0x80020000), (0x0110c000, 0x0110e000)])

def packet(xlen, entry, segments):
    if xlen not in (32, 64) or not 1 <= len(segments) <= 8:
        raise ValueError("unsupported configuration/segment count")
    spans=[]
    for address, flags, data in segments:
        if not allowed(address, len(data)) or flags not in (0, 1) or (address < 0x80000000 and flags):
            raise ValueError("segment outside permitted layout")
        if any(address < end and start < address+len(data) for start,end in spans):
            raise ValueError("overlapping segments")
        spans.append((address,address+len(data)))
    if entry & 3 or not any(flags and address <= entry < address+len(data)
                            for address,flags,data in segments):
        raise ValueError("entry outside executable DDR segment")
    table=b"".join(struct.pack("<4I",address,len(data),flags,crc(data)) for address,flags,data in segments)
    header=struct.pack("<6I",0x31424748,1,xlen|(1<<16),entry,len(segments),crc(table))
    blocks=[data[i:i+128] for _,_,data in segments for i in range(0,len(data),128)]
    return header+struct.pack("<I",crc(header))+table, blocks

def elf_segments(path):
    raw=Path(path).read_bytes()
    if raw[:4] != b"\x7fELF" or raw[5:7] != b"\x01\x01" or raw[4] not in (1,2):
        raise ValueError("expected little-endian ELF32/ELF64")
    xlen=32 if raw[4]==1 else 64
    fmt="<HHIIIIIHHHHHH" if xlen==32 else "<HHIQQQIHHHHHH"
    h=struct.unpack_from(fmt,raw,16)
    if h[0]!=2 or h[1]!=243:
        raise ValueError("expected executable RISC-V ELF")
    entry,phoff,phsize,phnum=h[3],h[4],h[8],h[9]
    pformat="<8I" if xlen==32 else "<II6Q"
    if phsize!=struct.calcsize(pformat):
        raise ValueError("unexpected ELF program-header size")
    segments=[]
    for index in range(phnum):
        p=struct.unpack_from(pformat,raw,phoff+index*phsize)
        if xlen==32: typ,off,vma,addr,size,memsize,flags,align=p
        else: typ,flags,off,vma,addr,size,memsize,align=p
        if typ!=1 or not size:
            continue
        if size>memsize or off+size>len(raw):
            raise ValueError("truncated/invalid ELF segment")
        # 模型 bootstrap 与被动观察口不下载；其余不合法段直接拒绝。
        if 0x01000000<=addr<0x0100e000 and size<=0x0100e000-addr:
            continue
        if addr==0x01100000 and size<=16:
            continue
        execute=int(bool(flags&1) and addr>=0x80000000)
        segments.append((addr,execute,raw[off:off+size]))
    packet(xlen,entry,segments)
    return xlen,entry,segments

def send(port, baud, prefix, blocks):
    import serial  # Only serial transfer needs pyserial; packet generation has no external dependencies.
    with serial.Serial(port,baud,timeout=15,write_timeout=15,dsrdtr=False,rtscts=False) as uart:
        uart.dtr=False
        uart.rts=False
        while True:
            line=uart.readline()
            if not line: raise TimeoutError("no LOADER READY banner; reset board and retry")
            print(line.decode("ascii",errors="replace"),end="")
            if line.endswith(b"LOADER READY v1 m0d1\n"): break
        def ack(expected):
            value=uart.read(1)
            if value==b"\x15": raise RuntimeError(f"loader rejected transfer: code {uart.read(1).hex()}")
            if value!=expected: raise RuntimeError(f"expected {expected.hex()}, got {value.hex()}")
        uart.write(prefix)
        ack(b"\x06")
        for block in blocks:
            uart.write(block+struct.pack("<I",crc(block)))
            ack(b"\x06")
        ack(b"\x07")
        print("PASS loader published and read back image; application log follows")
        while True:
            data=uart.read(1)
            if data: print(data.decode("ascii",errors="replace"),end="",flush=True)

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument("elf",type=Path)
    parser.add_argument("--output",type=Path,required=True)
    parser.add_argument("--port")
    parser.add_argument("--baud",type=int,default=115200)
    args=parser.parse_args()
    xlen,entry,segments=elf_segments(args.elf)
    prefix,blocks=packet(xlen,entry,segments)
    wire=prefix+b"".join(b+struct.pack("<I",crc(b)) for b in blocks)
    args.output.parent.mkdir(parents=True,exist_ok=True)
    args.output.write_bytes(wire)
    args.output.with_suffix(".json").write_text(json.dumps({"format":"HGB1","xlen":xlen,
        "mul":0,"div":1,"entry":hex(entry),"packet_crc":hex(crc(wire)),
        "elf_sha256":hashlib.sha256(args.elf.read_bytes()).hexdigest(),
        "segments":[{"address":hex(a),"bytes":len(d),"execute":f,"crc":hex(crc(d))}
                    for a,f,d in segments]},indent=2)+"\n")
    print(f"PASS packet RV{xlen}: {len(segments)} segments, {len(wire)} wire bytes")
    if args.port: send(args.port,args.baud,prefix,blocks)

if __name__=="__main__": main()
