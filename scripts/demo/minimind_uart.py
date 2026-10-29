#!/usr/bin/env python3
"""Receive the persistent MiniMind text service or prepare its checked DDR asset header."""
import argparse
import hashlib
import json
from pathlib import Path
import struct
import time
import zlib


def fields(line):
    result={}
    for item in line.split()[1:]:
        if '=' not in item:raise ValueError('malformed field')
        key,value=item.split('=',1)
        if key in result:raise ValueError('duplicate field')
        result[key]=value
    return result


def integer(info,key):
    value=info.get(key,'')
    if not value.isdecimal():raise ValueError('invalid '+key)
    return int(value)


class Decoder:
    def __init__(self):
        self.ready=None;self.current=None;self.responses=[];self.errors=[]

    def feed(self,line):
        try:self._feed(line.strip())
        except (ValueError,UnicodeDecodeError) as error:self.errors.append(str(error))

    def _feed(self,line):
        if line.startswith('READY '):
            info=fields(line)
            if info.get('app')!='minimind' or info.get('layers')!='8' or info.get('assets_loaded')!='1':
                raise ValueError('invalid MiniMind READY')
            if self.current is not None:
                if self.current.get('done') is None:raise ValueError('READY before DONE')
                self.current['next_ready']=info
                if info!=self.ready:raise ValueError('persistent allocation or configuration changed')
                self.current['text']=bytes.fromhex(self.current.pop('text_hex')).decode('utf8')
                self.responses.append(self.current);self.current=None
            self.ready=info
        elif line.startswith('BEGIN '):
            if self.ready is None or self.current is not None:raise ValueError('unexpected BEGIN')
            info=fields(line);count=integer(info,'input_tokens')
            if count<1 or count>=integer(self.ready,'context'):raise ValueError('invalid input context')
            self.current={'begin':info,'tokens':[],'text_hex':'','done':None}
        elif line.startswith('TOKEN '):
            if self.current is None or self.current.get('done') is not None:raise ValueError('unexpected TOKEN')
            info=fields(line);token=integer(info,'id');size=integer(info,'bytes')
            if not 0<=token<6400:raise ValueError('token outside vocabulary')
            payload=bytes.fromhex(info.get('hex',''))
            if len(payload)!=size or size>1024:raise ValueError('token byte count mismatch')
            self.current['tokens'].append(info);self.current['text_hex']+=payload.hex()
        elif line.startswith('DONE '):
            info=fields(line)
            if self.ready is None:raise ValueError('DONE before READY')
            if self.current is None:self.current={'begin':None,'tokens':[],'text_hex':'','done':None}
            if self.current['done'] is not None:raise ValueError('duplicate DONE')
            if integer(info,'generated')!=len(self.current['tokens']):raise ValueError('generated count mismatch')
            if info.get('status')=='ok':
                begin=self.current['begin'];inputs=integer(info,'input_tokens');generated=integer(info,'generated')
                if (begin is None or inputs!=integer(begin,'input_tokens') or generated<1 or
                        integer(info,'position')!=inputs+generated-1):
                    raise ValueError('completed response position differs from consumed tokens')
            if (integer(info,'generated')>integer(self.ready,'max_new_tokens') or
                    (info.get('status')=='ok' and integer(info,'input_tokens')+integer(info,'generated')>integer(self.ready,'context'))):
                raise ValueError('generated response exceeds context or token limit')
            if integer(info,'live_bytes')!=integer(self.ready,'live_bytes'):raise ValueError('request allocation was not released')
            self.current['done']=info
        elif line.startswith('BOOT_ERROR '):raise ValueError(line)

    def report(self):
        errors=list(self.errors)
        if self.current is not None:errors.append('incomplete DONE/READY cycle')
        if not self.responses:errors.append('no completed response')
        return {'responses':self.responses,'errors':errors,'valid':not errors}


def decode(text):
    parser=Decoder()
    for line in text.splitlines():parser.feed(line)
    return parser.report()


def asset_header(model,tokenizer):
    for path,magic,maximum in ((model,b'MM3INT01',0x4000000),(tokenizer,b'MM3TOK01',0x1000000)):
        data=path.read_bytes()
        if (len(data)<68 or len(data)>maximum or data[:8]!=magic or
                struct.unpack_from('<I',data,8)[0]!=1 or struct.unpack_from('<Q',data,16)[0]!=len(data)):
            raise ValueError('invalid asset layout: '+str(path))
        if zlib.crc32(data[:-4])!=struct.unpack_from('<I',data,len(data)-4)[0]:
            raise ValueError('asset CRC mismatch: '+str(path))
    data=struct.pack('<6I',0x3141334d,1,0x81000000,model.stat().st_size,0x85000000,tokenizer.stat().st_size)
    return data+struct.pack('<I',zlib.crc32(data))


def chat(args):
    try:import serial
    except ImportError as error:raise RuntimeError('live UART requires pyserial') from error
    parser=Decoder();pending=bytearray();sent=0;deadline=time.monotonic()+args.timeout
    with serial.Serial(args.port,args.baud,timeout=.2) as connection,args.raw_log.open('wb') as raw:
        while len(parser.responses)<len(args.prompt):
            if time.monotonic()>deadline:raise TimeoutError('MiniMind request timed out; UART transcript saved')
            data=connection.read(1024)
            if not data:continue
            raw.write(data);raw.flush();pending.extend(data)
            if len(pending)>8192:raise ValueError('UART line too long')
            while b'\n' in pending:
                line,_,pending=pending.partition(b'\n');text=line.decode('ascii').rstrip('\r')
                parser.feed(text)
                if parser.errors:raise ValueError('; '.join(parser.errors))
                if text.startswith('READY ') and sent<len(args.prompt):
                    payload=args.prompt[sent].encode('utf8')
                    if not payload or len(payload)>512 or any(c in payload for c in (0,10,13)):
                        raise ValueError('prompt must be one nonempty UTF-8 line up to 512 bytes')
                    connection.write(payload+b'\r');connection.flush();sent+=1;deadline=time.monotonic()+args.timeout
                elif text.startswith('TOKEN '):
                    print(bytes.fromhex(fields(text)['hex']).decode('utf8'),end='',flush=True)
                elif text.startswith('DONE '):print(flush=True)
    return parser.report()


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    commands=parser.add_subparsers(dest='command',required=True)
    header=commands.add_parser('asset-header');header.add_argument('--model',type=Path,required=True)
    header.add_argument('--tokenizer',type=Path,required=True);header.add_argument('--output',type=Path,required=True)
    offline=commands.add_parser('decode');offline.add_argument('--input',type=Path,required=True)
    offline.add_argument('--output',type=Path,required=True)
    live=commands.add_parser('chat');live.add_argument('--port',required=True);live.add_argument('--baud',type=int,default=115200)
    live.add_argument('--prompt',action='append',required=True);live.add_argument('--timeout',type=float,default=600)
    live.add_argument('--output',type=Path,required=True);live.add_argument('--raw-log',type=Path,required=True)
    args=parser.parse_args()
    if args.command=='asset-header':
        args.output.write_bytes(asset_header(args.model,args.tokenizer))
        print('DDR preload: header@0x80400000 model@0x81000000 tokenizer@0x85000000; no TF/UART asset loader supplied')
        return
    report=decode(args.input.read_text()) if args.command=='decode' else chat(args)
    report['transcript_sha256']=hashlib.sha256((args.input if args.command=='decode' else args.raw_log).read_bytes()).hexdigest()
    args.output.write_text(json.dumps(report,indent=2,ensure_ascii=False)+'\n')
    for response in report['responses']:
        print('status='+response['done']['status']+' text='+response['text'])
    if not report['valid'] or any(r['done']['status']!='ok' for r in report['responses']):raise SystemExit(1)


if __name__=='__main__':main()
