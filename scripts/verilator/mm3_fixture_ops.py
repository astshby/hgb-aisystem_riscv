#!/usr/bin/env python3
"""Prepare small operator/layer programs and independent Python expected results.

Only explicit mm3-ref/test targets invoke this file. Static checks must not import or execute it.
"""
import argparse,hashlib,json,pathlib,struct
from mm3_integer_reference import Memory,execute,pack,value
ROOT=pathlib.Path(__file__).resolve().parents[2]
BASE=0x81000000;CMD_BASE=0x80410000;RANGE_BASE=0x80420000
FIELDS={'magic':0,'op':1,'n':2,'m':3,'k':4,'flags':5,'a':6,'b':7,'out':8,'as_':9,'bs':10,'os':11,'aux':12,'aux_scale':13,'pos':14,'length':15,'eps_m':16,'eps_e':17,'keys':18,'values':19,'ks':20,'vs':21,'capacity':22,'inv_m':23,'inv_e':24,'stride_a':25,'stride_b':26}
class Fixture:
    def __init__(self):self.data=bytearray();self.commands=[];self.ranges=[]
    def alloc(self,size,data=None):
        self.data.extend(b'\0'*((-len(self.data))%64));p=BASE+len(self.data)
        self.data.extend(data if data is not None else b'\xa5'*size)
        if data is not None and len(data)!=size:raise ValueError('allocation size')
        self.data.extend(b'\0'*((-len(self.data))%64))
        return p
    def arr(self,values,fmt):return self.alloc(len(values)*struct.calcsize('<'+fmt),struct.pack('<'+str(len(values))+fmt,*values))
    def sc(self,m=1<<30,e=-10):return self.alloc(8,struct.pack('<Ii',m,e))
    def cmd(self,op,**kw):
        c=[0]*32;c[0]=0x334f5031;c[1]=op
        for k,v in kw.items():c[FIELDS[k]]=v&0xffffffff
        self.commands.append(c);return c
    def check(self,name,address,size):self.ranges.append({'name':name,'address':address,'bytes':size})

def build(kind,cfg):
    f=Fixture();assets=ROOT/'software/minimind3/c_runtime/assets';meta=json.loads((assets/'integer_manifest.json').read_text())
    raw=(assets/'model_w8a16_int.bin').read_bytes()
    if hashlib.sha256(raw).hexdigest()!=meta['sha256'] or len(raw)!=meta['bytes']:raise ValueError('locked model SHA/length mismatch')
    tensors={t['name']:t for t in meta['tensors']};cached={}
    def tensor(name):
        if name not in cached:
            t=tensors[name];num=t['shape'][0]*t['shape'][1];unit={2:1,3:2,4:4,5:2}[t['dtype']]
            p=f.alloc(num*unit,raw[t['offset']:t['offset']+num*unit]);s=0
            if t['scale_count']:s=f.alloc(t['scale_count']*8,raw[t['scale_offset']:t['scale_offset']+t['scale_count']*8])
            cached[name]=(p,s)
        return cached[name]
    eps=struct.unpack_from('<Ii',raw,104);inv=struct.unpack_from('<Ii',raw,112)
    exp=tensor('__exp')[0];sig=tensor('__sigmoid')[0];rope=f.alloc(192,raw[tensors['__rope']['offset']:tensors['__rope']['offset']+192])
    def out(n):return f.alloc(n*2),f.sc()
    def norm_cmd(a,ass,g,gs,n,name):
        y,ys=out(n);f.cmd(3,n=n,a=a,b=g,out=y,as_=ass,bs=gs,os=ys,eps_m=eps[0],eps_e=eps[1]);return y,ys
    def attn(q,qs,T,name):
        cap=cfg['MM3_SEQ_CAP'];keys=f.arr([0]*(cap*384),'h');vals=f.arr([0]*(cap*384),'h')
        ks=f.alloc(cap*32,struct.pack('<Ii',1<<30,-10)*(cap*4));vs=f.alloc(cap*32,struct.pack('<Ii',1<<30,-10)*(cap*4))
        y,ys=out(768)
        f.cmd(9,n=768,a=q,out=y,as_=qs,os=ys,aux=exp,keys=keys,values=vals,ks=ks,vs=vs,length=T,capacity=cap,inv_m=inv[0],inv_e=inv[1]);return y,ys,keys,vals,ks,vs
    if kind=='layer':
        t=tensors['model.embed_tokens.weight'];token=cfg['MM3_TEST_TOKEN_ID'];offset=t['offset']+token*768
        embedding=struct.unpack_from('<768b',raw,offset);ss=struct.unpack_from('<Ii',raw,t['scale_offset']+token*8)
        xv,xs=pack([value(v,ss) for v in embedding]);x=f.arr(xv,'h');xsc=f.sc(*xs)
        def norm_model(a,ass,suffix):
            g,gs=tensor('model.layers.0.'+suffix+'.weight');return norm_cmd(a,ass,g,gs,768,suffix)
        def linear(a,ass,suffix,rows,cols):
            w,ws=tensor('model.layers.0.'+suffix+'.weight');y,ys=out(rows)
            f.cmd(0,n=rows,k=cols,a=a,b=w,out=y,as_=ass,bs=ws,os=ys);return y,ys
        z,zs=norm_model(x,xsc,'input_layernorm')
        q,qs=linear(z,zs,'self_attn.q_proj',768,768);k,ks0=linear(z,zs,'self_attn.k_proj',384,768);v,vs0=linear(z,zs,'self_attn.v_proj',384,768)
        qn=f.alloc(1536);kn=f.alloc(768);qh=f.alloc(64);kh=f.alloc(32)
        for src,sc,dest,heads,scales,suffix in [(q,qs,qn,8,qh,'self_attn.q_norm'),(k,ks0,kn,4,kh,'self_attn.k_norm')]:
            g,gs=tensor('model.layers.0.'+suffix+'.weight')
            for h in range(heads):
                f.cmd(3,n=96,a=src+h*192,b=g,out=dest+h*192,as_=sc,bs=gs,os=scales+h*8,eps_m=eps[0],eps_e=eps[1])
                f.cmd(4,n=96,a=dest+h*192,b=rope,out=dest+h*192,as_=scales+h*8,bs=scales+h*8,os=scales+h*8)
        cap=cfg['MM3_SEQ_CAP'];keys=f.arr([0]*(cap*384),'h');vals=f.arr([0]*(cap*384),'h')
        ksc=f.alloc(cap*32,struct.pack('<Ii',1<<30,1)*(cap*4));vsc=f.alloc(cap*32,struct.pack('<Ii',1<<30,1)*(cap*4))
        # KV supports a scalar V scale broadcast flag, implemented in all three backends.
        f.cmd(8,n=384,a=kn,b=v,as_=kh,bs=vs0,keys=keys,values=vals,ks=ksc,vs=vsc,pos=0,capacity=cap,flags=2)
        av,avs=out(768);f.cmd(9,n=768,a=qn,out=av,as_=qh,os=avs,aux=exp,keys=keys,values=vals,ks=ksc,vs=vsc,length=1,capacity=cap,inv_m=inv[0],inv_e=inv[1])
        o,oss=linear(av,avs,'self_attn.o_proj',768,768)
        residual,rss=out(768);f.cmd(1,n=768,a=x,b=o,out=residual,as_=xsc,bs=oss,os=rss)
        z,zs=norm_model(residual,rss,'post_attention_layernorm')
        gate,gss=linear(z,zs,'mlp.gate_proj',2432,768);up,uss=linear(z,zs,'mlp.up_proj',2432,768)
        g,gsc=out(2432);f.cmd(6,n=2432,a=gate,b=up,out=g,as_=gss,bs=uss,os=gsc,aux=sig)
        down,dss=linear(g,gsc,'mlp.down_proj',768,2432)
        y,ys=out(768);f.cmd(1,n=768,a=residual,b=down,out=y,as_=rss,bs=dss,os=ys)
        for name,p,size in [('hidden',y,1536),('hidden_scale',ys,8),('K',keys,768),('V',vals,768),('K_scale',ksc,32),('V_scale',vsc,32)]:f.check(name,p,size)
    elif kind in ('attention','attn'):
        T=cfg['MM3_TEST_ATTN_LEN'];q=f.arr([((i*17)%23-11)*503 for i in range(768)],'h');qs=f.alloc(64,b''.join(struct.pack('<Ii',(1<<30)+h*12345,-10) for h in range(8)))
        y,ys,keys,vals,ks,vs=attn(q,qs,T,'attention')
        for t in range(T):
            kb=[((i*19+t*31)%29-14)*127 for i in range(384)];vb=[((i*13+t*17)%31-15)*211 for i in range(384)]
            f.data[keys-BASE+t*768:keys-BASE+(t+1)*768]=struct.pack('<384h',*kb)
            f.data[vals-BASE+t*768:vals-BASE+(t+1)*768]=struct.pack('<384h',*vb)
            for h in range(4):
                struct.pack_into('<Ii',f.data,ks-BASE+(t*4+h)*8,(1<<30)+t*98765,-10+t%2)
                struct.pack_into('<Ii',f.data,vs-BASE+(t*4+h)*8,(1<<30)+h*12345,-9-t%3)
        f.check('attention',y,1536);f.check('scale',ys,8)
    elif kind=='gemm':
        for pv,m,n,k in [(0,min(11,cfg['MM3_GEMM_MAX_M']),13,9),(1,min(3,cfg['MM3_GEMM_MAX_M']),5,7)]:
            if m>cfg['MM3_GEMM_MAX_M'] or n>cfg['MM3_GEMM_MAX_N'] or k>cfg['MM3_GEMM_MAX_K']:raise ValueError('test exceeds GEMM capacity')
            astride=k+2;bstride=(n if pv else k)+1
            a=f.arr([((i*701)%65536) if pv else i%17-8 for i in range((m-1)*astride+k)],'H' if pv else 'h')
            b=f.arr([(i%13-6)*(1000003 if pv else 1) for i in range(((k-1)*bstride+n) if pv else ((n-1)*bstride+k))],'i' if pv else 'h');y=f.alloc(m*n*8)
            f.cmd(7,n=n,m=m,k=k,flags=1 if pv else 2,a=a,b=b,out=y,stride_a=astride,stride_b=bstride);f.check('gemm_pv' if pv else 'gemm_qk',y,m*n*8)
    elif kind=='softmax':
        for scores in ([0],[0,0,0,0],[65536,-32768,16384,8192]):
            n=len(scores);a=f.arr(scores,'i');y=f.alloc(n*2);f.cmd(5,n=n,a=a,out=y,aux=exp);f.check('probability',y,n*2)
    elif kind in ('kv','kv_cache'):
        cap=cfg['MM3_SEQ_CAP'];keys=f.arr([0]*(cap*384),'h');vals=f.arr([0]*(cap*384),'h');ks=f.alloc(cap*32);vs=f.alloc(cap*32)
        a=f.arr([i-192 for i in range(384)],'h');b=f.arr([i*3-511 for i in range(384)],'h');ass=f.alloc(32,struct.pack('<Ii',1<<30,-10)*4);bs=f.alloc(32,struct.pack('<Ii',1<<30,-11)*4)
        f.cmd(8,n=384,a=a,b=b,as_=ass,bs=bs,keys=keys,values=vals,ks=ks,vs=vs,pos=cap-1,capacity=cap)
        y=f.alloc(768);z=f.alloc(768);ys=f.alloc(32);zs=f.alloc(32)
        f.cmd(8,n=384,a=y,b=z,as_=ys,bs=zs,keys=keys,values=vals,ks=ks,vs=vs,pos=cap-1,capacity=cap,flags=1)
        for name,p,size in [('K',y,768),('V',z,768),('KS',ys,32),('VS',zs,32)]:f.check(name,p,size)
    else:
        ops={'add':1,'ew_add':1,'mul':2,'ew_mul':2,'rmsnorm':3,'norm':3,'rope':4,'swiglu':6};op=ops[kind]
        for case in range(3):
            n=96 if op==4 else 13 if case==0 else 97
            a=f.arr([0 if case==0 else ((-32767 if i%2 else 32767) if case==1 else i*31-500) for i in range(n)],'h')
            b=rope if op==4 else f.arr([257 if op==3 else i*17-300 for i in range(n)],'h')
            ass=f.sc(1<<30,-10-case);bs=f.sc(1<<30,-8);y,ys=out(n)
            f.cmd(op,n=n,a=a,b=b,out=y,as_=ass,bs=bs,os=ys,aux=sig if op==6 else 0,eps_m=eps[0],eps_e=eps[1]);f.check(kind,y,n*2);f.check(kind+'_scale',ys,8)
    return f,meta

def result_regions(c):
    if c[1]==8:
        if c[5]&1:return [(c[6],c[2]*2),(c[7],c[2]*2),(c[9],32),(c[10],32)]
        return [(c[18]+c[14]*c[2]*2,c[2]*2),(c[19]+c[14]*c[2]*2,c[2]*2),(c[20]+c[14]*32,32),(c[21]+c[14]*32,32)]
    regions=[(c[8],c[3]*c[2]*8 if c[1]==7 else c[2]*2)]
    if c[1] not in (5,7):regions.append((c[11],8))
    return regions

def main():
    p=argparse.ArgumentParser();p.add_argument('--case',default='layer');p.add_argument('--trace',action='store_true');p.add_argument('--out',type=pathlib.Path,required=True);args=p.parse_args()
    cfg=json.loads((ROOT/'build/mm3-ops/config/config.json').read_text())['config'];f,source=build(args.case,cfg);out=args.out;out.mkdir(parents=True,exist_ok=True)
    for stale in list(out.glob('expected-op-*.bin'))+list((out/'c-trace').glob('op-*.bin')):stale.unlink()
    # 记录输出所在分配块的尾部填充，检查 DMA 字节使能没有破坏邻接字节。
    for i,c in enumerate(f.commands):
        for address,size in result_regions(c):
            endpoint=address+size
            if endpoint%64:f.check(f'tail_guard_{i}_{address:x}',endpoint,64-endpoint%64)
    if len(f.commands)>cfg['MM3_MAX_COMMANDS'] or len(f.ranges)>cfg['MM3_MAX_COMMANDS']:raise ValueError('command/range capacity')
    (out/'image.bin').write_bytes(f.data);commands=b''.join(struct.pack('<32I',*c) for c in f.commands);(out/'commands.bin').write_bytes(commands)
    (out/'ranges.bin').write_bytes(b''.join(struct.pack('<II',r['address'],r['bytes']) for r in f.ranges))
    control=[0x4d334f50,len(f.commands),CMD_BASE,BASE,len(f.data),len(f.ranges),RANGE_BASE]+[0]*9
    (out/'control.bin').write_bytes(struct.pack('<16I',*control))
    mem=Memory(f.data);metrics=[]
    for i,c in enumerate(f.commands):
        m=execute(mem,c,cfg)
        if args.trace:(out/f'expected-op-{i:03d}.bin').write_bytes(b''.join(mem.bytes(p,n) for p,n in result_regions(c)))
        if m:metrics.append({'command':i,**m})
    expected=b''.join(mem.bytes(r['address'],r['bytes']) for r in f.ranges);(out/'expected.bin').write_bytes(expected)
    manifest={'case':args.case,'config':cfg,'source_sha256':source['sha256'],'source_revision':source.get('source'),'commands':len(f.commands),'trace':args.trace,'image_base':BASE,'image_bytes':len(f.data),'ranges':f.ranges,'norm_vs_legacy':metrics,'expected_sha256':hashlib.sha256(expected).hexdigest(),'files':{name:hashlib.sha256((out/name).read_bytes()).hexdigest() for name in ('image.bin','commands.bin','ranges.bin','control.bin')}}
    (out/'fixture.json').write_text(json.dumps(manifest,ensure_ascii=False,indent=2)+'\n');print('REFERENCE_READY',args.case,len(f.commands),'commands')
if __name__=='__main__':main()
