#!/usr/bin/env python3
"""Independent integer oracle. Invoked only by explicit reference/test targets, never static checks."""
import decimal, functools, math, struct

def rne(v, shift):
    if shift <= 0:return v << -shift
    q,r=divmod(v,1<<shift);h=1<<(shift-1)
    return q+int(r>h or (r==h and q&1))
def even_div(a,b):
    q,r=divmod(a,b);return q+int(r>b-r or (r==b-r and q&1))
def make(v,e=0):
    if not v:return (0,0)
    sign=-1 if v<0 else 1;v=abs(v);bits=v.bit_length()
    if bits>61:
        v=rne(v,bits-61);e+=bits-61
        if v==1<<61:v>>=1;e+=1
    else:v<<=61-bits;e-=61-bits
    return sign*v,e
def scale(s):return make(s[0],s[1]-31)
def add(a,b):
    if not a[0]:return b
    if not b[0]:return a
    e=max(a[1],b[1]);av=rne(abs(a[0]),e-a[1]);bv=rne(abs(b[0]),e-b[1])
    return make((-av if a[0]<0 else av)+(-bv if b[0]<0 else bv),e)
def mul(a,b):
    if not a[0] or not b[0]:return (0,0)
    v=abs(a[0]*b[0]);s=max(0,v.bit_length()-61);v=rne(v,s)
    return make(-v if (a[0]<0)!=(b[0]<0) else v,a[1]+b[1]+s)
def div(a,b):
    if not a[0] or not b[0]:return (0,0)
    v=even_div(abs(a[0])<<60,abs(b[0]));return make(-v if (a[0]<0)!=(b[0]<0) else v,a[1]-b[1]-60)
def integer(a,bits=32):
    if not a[0]:return 0
    v=rne(abs(a[0]),-a[1]);v=min(v,(1<<(bits-1))-1);return -v if a[0]<0 else v
def value(v,s):return mul(make(v),scale(s))
def maxscale(a,limit=32767):
    if not a[0]:return (1<<30,1)
    v,e=div((abs(a[0]),a[1]),make(limit));m=(v+(1<<30)-1)>>30;e+=61
    if m>=1<<31:m=(m+1)>>1;e+=1
    return m,e
def pack(a):
    largest=max(((abs(v),e) for v,e in a if v),key=lambda z:(z[1],z[0]),default=(0,0))
    s=maxscale(largest);return [integer(div(v,scale(s)),16) for v in a],s
@functools.lru_cache(None)
def seeds(bits):
    decimal.getcontext().prec=90;D=decimal.Decimal
    table=[]
    for p in range(2):
        for i in range(1<<bits):
            t=(1+(D(i)+D('0.5'))/D(1<<bits))*D(1<<p)
            table.append(int((D(1<<31)/t.sqrt()).to_integral_value(rounding=decimal.ROUND_HALF_EVEN)))
    return tuple(table)

def rsqrt(s,cfg):
    v,e=s
    if v<=0:raise ValueError('nonpositive rsqrt')
    E=e+60;p=E%2;k=(E-p)//2;bits=cfg['MM3_RSQRT_LUT_BITS']
    index=(v>>(60-bits))&((1<<bits)-1);t=rne(v,30-p);y=seeds(bits)[(p<<bits)+index]
    for _ in range(cfg['MM3_RSQRT_ITERS']):
        y2=rne(y*y,31);ty2=rne(t*y2,30)
        if ty2>=3<<31:raise ValueError('invalid Newton correction')
        y=min(1<<31,rne(y*rne((3<<31)-ty2,1),31))
    return make(y,-31-k)
def norm(x,xs,g,gs,eps,cfg,legacy=False):
    sx=scale(xs);v=mul(make(sum(a*a for a in x)),mul(sx,sx))
    if legacy:
        v=add(div(v,make(len(x))),scale(eps));z,e=v
        if e%2:z<<=1;e-=1
        inv=make(math.isqrt(z<<60),(e-60)//2);factor=div(mul(sx,scale(gs)),inv)
    else:
        v=add(mul(v,make(even_div(1<<48,len(x)),-48)),scale(eps))
        factor=mul(mul(sx,scale(gs)),rsqrt(v,cfg))
    return pack([mul(make(a*b),factor) for a,b in zip(x,g)])
def softmax(scores,lut):
    maximum=max(scores);exp=[]
    for score in scores:
        x=score-maximum
        if x < -(16<<16):y=0
        elif x>=0:y=1<<31
        else:
            t=-x;i,f=divmod(t,256)
            y=lut[4096] if i>=4096 else rne(lut[i]*(256-f)+lut[i+1]*f,8)
        exp.append(y)
    total=sum(exp);qs=[];rem=[]
    for x in exp:q,r=divmod(x*65535,total);qs.append(q);rem.append(r)
    for i in sorted(range(len(qs)),key=lambda i:(-rem[i],i))[:65535-sum(qs)]:qs[i]+=1
    return qs

class Memory:
    def __init__(self,data,base=0x81000000):self.data=bytearray(data);self.base=base
    def get(self,address,n,fmt):
        offset=address-self.base;unit=struct.calcsize('<'+fmt)
        if offset<0 or offset+n*unit>len(self.data):raise ValueError(f'address range {address:x}, {n}, {fmt}')
        return list(struct.unpack_from('<'+str(n)+fmt,self.data,offset))
    def put(self,address,values,fmt):struct.pack_into('<'+str(len(values))+fmt,self.data,address-self.base,*values)
    def sc(self,address):return tuple(self.get(address,1,'I')+self.get(address+4,1,'i'))
    def putsc(self,address,s):self.put(address,[s[0]],'I');self.put(address+4,[s[1]],'i')
    def bytes(self,address,n):return bytes(self.data[address-self.base:address-self.base+n])

def execute(mem,d,cfg):
    if d[0]!=0x334f5031:raise ValueError('bad command')
    _,op,n,m,k,flags,aa,ba,out,asa,bsa,osa,aux,_,pos,T,em,ee,ka,va,ksa,vsa,cap,im,ie,*_=d
    signed=lambda x:x-(1<<32) if x&(1<<31) else x
    if op==7:
        astride=d[25] or k;bstride=d[26] or (k if flags&2 else n)
        a=mem.get(aa,(m-1)*astride+k,'H' if flags&1 else 'h');b=mem.get(ba,((n-1)*bstride+k) if flags&2 else ((k-1)*bstride+n),'i' if flags&1 else 'h')
        y=[sum(a[i*astride+t]*b[j*bstride+t if flags&2 else t*bstride+j] for t in range(k)) for i in range(m) for j in range(n)]
        mem.put(out,y,'q');return None
    if op==5:mem.put(out,softmax(mem.get(aa,n,'i'),mem.get(aux,4097,'I')),'H');return None
    if op==8:
        for part,(src,dst,count) in enumerate([(aa,ka+pos*n*2,n*2),(ba,va+pos*n*2,n*2),(asa,ksa+pos*32,32),(bsa,vsa+pos*32,32)]):
            if flags&1:src,dst=dst,src
            data=mem.bytes(src,8)*4 if not flags&1 and flags&2 and part==3 else mem.bytes(src,count)
            mem.data[dst-mem.base:dst-mem.base+count]=data
        return None
    a=mem.get(aa,k if op==0 else n,'h');ass=mem.sc(asa);old=None
    if op==9:
        qs=[mem.sc(asa+h*8) for h in range(8)];keys=mem.get(ka,T*384,'h');values=mem.get(va,T*384,'h')
        ks=[mem.sc(ksa+i*8) for i in range(T*4)];vs=[mem.sc(vsa+i*8) for i in range(T*4)];lut=mem.get(aux,4097,'I');work=[]
        for h in range(8):
            kh=h//2;qf=mul(scale(qs[h]),scale((im,signed(ie))));scores=[]
            for t in range(T):
                acc=sum(a[h*96+j]*keys[t*384+kh*96+j] for j in range(96));v=mul(mul(make(acc),qf),scale(ks[t*4+kh]));scores.append(integer((v[0],v[1]+16)))
            p=softmax(scores,lut);base=(1<<30,1);found=False
            for t in range(T):
                if any(values[t*384+kh*96+j] for j in range(96)):
                    s=vs[t*4+kh]
                    if not found or (s[1],s[0])>(base[1],base[0]):base=s
                    found=True
            base=(base[0],base[1]-14);sums=[0]*96
            for t in range(T):
                ratio=div(scale(vs[t*4+kh]),scale(base))
                for j in range(96):sums[j]+=integer(mul(make(values[t*384+kh*96+j]),ratio))*p[t]
            factor=div(scale(base),make(65535));work.extend(mul(make(v),factor) for v in sums)
        y,s=pack(work)
    elif op==0:
        w=mem.get(ba,n*k,'b');scales=[mem.sc(bsa+i*8) for i in range(n)]
        y,s=pack([mul(mul(make(sum(w[i*k+j]*a[j] for j in range(k))),scale(ass)),scale(scales[i])) for i in range(n)])
    else:
        b=mem.get(ba,n,'h');bs=mem.sc(bsa)
        if op==3:
            y,s=norm(a,ass,b,bs,(em,signed(ee)),cfg);old=norm(a,ass,b,bs,(em,signed(ee)),cfg,True)
        elif op==1:y,s=pack([add(value(x,ass),value(z,bs)) for x,z in zip(a,b)])
        elif op==4:
            factor=scale(ass);factor=(factor[0],factor[1]-15);work=[(0,0)]*96
            for i in range(48):
                work[i]=mul(make(a[i]*b[2*i]-a[i+48]*b[2*i+1]),factor)
                work[i+48]=mul(make(a[i+48]*b[2*i]+a[i]*b[2*i+1]),factor)
            y,s=pack(work)
        elif op in (2,6):
            factor=mul(scale(ass),scale(bs));lut=mem.get(aux,8193,'H') if op==6 else None
            if lut:factor=div(factor,make(65535))
            work=[]
            for x,z in zip(a,b):
                product=x*z
                if lut:
                    vx=value(x,ass);q=integer((vx[0],vx[1]+16))
                    if q<-(16<<16):sig=0
                    elif q>16<<16:sig=65535
                    else:
                        i,f=divmod(q+(16<<16),256);sig=lut[8192] if i>=8192 else rne(lut[i]*(256-f)+lut[i+1]*f,8)
                    product*=sig
                work.append(mul(make(product),factor))
            y,s=pack(work)
        else:raise ValueError('unknown operator')
    mem.put(out,y,'h');mem.putsc(osa,s)
    if old:
        real=lambda yy,ss:[math.ldexp(v*ss[0],ss[1]-31) for v in yy]
        diff=[x-z for x,z in zip(real(y,s),real(*old))]
        return {'max_abs':max(map(abs,diff)), 'rmse':math.sqrt(sum(v*v for v in diff)/len(diff))}
    return None
