#include "integer.h"
#include <limits.h>
/* Explicit 128-bit product in four 32-bit limbs; no compiler wide integer type. */
typedef struct { uint32_t w[4]; } U128;
static unsigned bits64(uint64_t x){unsigned b=0;while(x){b++;x>>=1;}return b;}
static uint64_t mag(int64_t x){return x<0?(uint64_t)(-(x+1))+1:(uint64_t)x;}
static U128 umul(uint64_t a,uint64_t b){U128 r={{0}};uint32_t av[2]={(uint32_t)a,(uint32_t)(a>>32)},bv[2]={(uint32_t)b,(uint32_t)(b>>32)};for(unsigned i=0;i<2;i++){uint64_t carry=0;for(unsigned j=0;j<2;j++){uint64_t v=(uint64_t)av[i]*bv[j]+r.w[i+j]+carry;r.w[i+j]=(uint32_t)v;carry=v>>32;}r.w[i+2]=(uint32_t)carry;}return r;}
static unsigned ubits(U128 a){for(int i=3;i>=0;i--)if(a.w[i])return (unsigned)i*32+bits64(a.w[i]);return 0;}
static unsigned ubit(U128 a,unsigned bit){return bit<128?((a.w[bit/32]>>(bit%32))&1u):0;}
static uint64_t uround(U128 a,unsigned shift){uint64_t out=0;for(unsigned i=0;i<64;i++)if(i+shift<128&&ubit(a,i+shift))out|=UINT64_C(1)<<i;if(shift){unsigned guard=ubit(a,shift-1),sticky=0;for(unsigned i=0;i+1<shift&&i<128;i++)sticky|=ubit(a,i);if(guard&&(sticky||(out&1)))out++;}return out;}
static U128 ushift(uint64_t a,unsigned shift){U128 r={{0}};for(unsigned i=0;i<64;i++)if((a>>i)&1u)if(i+shift<128)r.w[(i+shift)/32]|=1u<<((i+shift)%32);return r;}
static uint64_t udiv(U128 a,uint64_t b){uint64_t rem=0,q=0;for(int i=127;i>=0;i--){/* b is at most 61 bits, so the remainder shift cannot overflow. */rem=(rem<<1)|ubit(a,(unsigned)i);if(rem>=b){rem-=b;if(i<64)q|=UINT64_C(1)<<i;}}if(rem>b-rem||(rem==b-rem&&(q&1)))q++;return q;}
static uint64_t rshift(uint64_t v,unsigned s){if(!s)return v;if(s>64)return 0;if(s==64)return v>UINT64_C(0x8000000000000000);uint64_t q=v>>s,rem=v&((UINT64_C(1)<<s)-1),half=UINT64_C(1)<<(s-1);return q+(rem>half||(rem==half&&(q&1)));}
IFixed if_make(int64_t v,int e){if(!v)return (IFixed){0,0};uint64_t a=mag(v);unsigned b=bits64(a);if(b>61){a=rshift(a,b-61);e+=(int)b-61;if(a==(UINT64_C(1)<<61)){a>>=1;e++;}}else{a<<=61-b;e-=(int)(61-b);}return (IFixed){v<0?-(int64_t)a:(int64_t)a,e};}
IFixed if_add(IFixed a,IFixed b){if(!a.v)return b;if(!b.v)return a;int e=a.e>b.e?a.e:b.e;unsigned sa=(unsigned)(e-a.e),sb=(unsigned)(e-b.e);uint64_t av=rshift(mag(a.v),sa),bv=rshift(mag(b.v),sb);int64_t x=a.v<0?-(int64_t)av:(int64_t)av,y=b.v<0?-(int64_t)bv:(int64_t)bv;return if_make(x+y,e);}
IFixed if_mul(IFixed a,IFixed b){if(!a.v||!b.v)return (IFixed){0,0};U128 p=umul(mag(a.v),mag(b.v));unsigned bits=ubits(p),s=bits>61?bits-61:0;uint64_t v=uround(p,s);return if_make((a.v<0)!=(b.v<0)?-(int64_t)v:(int64_t)v,a.e+b.e+(int)s);}
IFixed if_div(IFixed a,IFixed b){if(!a.v||!b.v)return (IFixed){0,0};uint64_t v=udiv(ushift(mag(a.v),60),mag(b.v));return if_make((a.v<0)!=(b.v<0)?-(int64_t)v:(int64_t)v,a.e-b.e-60);}
uint64_t integer_sqrt64(uint64_t n){uint64_t res=0,bit=UINT64_C(1)<<62;while(bit>n)bit>>=2;while(bit){if(n>=res+bit){n-=res+bit;res=(res>>1)+bit;}else res>>=1;bit>>=2;}return res;}
IFixed if_sqrt(IFixed a){if(a.v<=0)return (IFixed){0,0};uint64_t v=(uint64_t)a.v;int e=a.e;if(e%2){v<<=1;e--;}U128 n=ushift(v,60);uint64_t lo=0,hi=UINT64_C(1)<<62;while(lo+1<hi){uint64_t m=lo+(hi-lo)/2;U128 p=umul(m,m);int cmp=0;for(int i=3;i>=0;i--)if(p.w[i]!=n.w[i]){cmp=p.w[i]<n.w[i]?-1:1;break;}if(cmp<=0)lo=m;else hi=m;}return if_make((int64_t)lo,(e-60)/2);}
IFixed if_scale(IScale s){return if_make(s.m,s.e-31);}
IFixed if_value(int64_t v,IScale s){return if_mul(if_make(v,0),if_scale(s));}
IScale iscale_max(IFixed maximum,uint32_t limit){if(!maximum.v)return (IScale){UINT32_C(1)<<30,1};maximum.v=(int64_t)mag(maximum.v);IFixed s=if_div(maximum,if_make(limit,0));uint64_t v=(uint64_t)s.v,m=(v+((UINT64_C(1)<<30)-1))>>30;int e=s.e+61;if(m>=(UINT64_C(1)<<31)){m=(m+1)>>1;e++;}return (IScale){(uint32_t)m,e};}
int64_t if_integer(IFixed a,unsigned bits,IStats *st){if(!a.v)return 0;uint64_t limit=(UINT64_C(1)<<(bits-1))-1,v=mag(a.v);if(a.e>=0){if(a.e>=63||v>(limit>>(unsigned)a.e)){if(st)st->saturated++;return a.v<0?-(int64_t)limit:(int64_t)limit;}v<<=(unsigned)a.e;}else v=rshift(v,(unsigned)(-a.e));if(v>limit){v=limit;if(st)st->saturated++;}if(!v&&st)st->underflow++;return a.v<0?-(int64_t)v:(int64_t)v;}
int64_t if_quant(IFixed v,IScale s,unsigned bits,IStats *st){return if_integer(if_div(v,if_scale(s)),bits,st);}
void int_pack16(int16_t *out,IScale *s,const IFixed *v,unsigned n,IStats *st){IFixed max={0,0};for(unsigned i=0;i<n;i++){IFixed a=v[i];if(a.v<0)a.v=-a.v;if(a.v&&(max.v==0||a.e>max.e||(a.e==max.e&&a.v>max.v)))max=a;}*s=iscale_max(max,32767);for(unsigned i=0;i<n;i++)out[i]=(int16_t)if_quant(v[i],*s,16,st);}
void int_pack32(int32_t *out,IScale *s,const IFixed *v,unsigned n,IStats *st){IFixed max={0,0};for(unsigned i=0;i<n;i++){IFixed a=v[i];if(a.v<0)a.v=-a.v;if(a.v&&(max.v==0||a.e>max.e||(a.e==max.e&&a.v>max.v)))max=a;}*s=iscale_max(max,INT32_MAX);for(unsigned i=0;i<n;i++)out[i]=(int32_t)if_quant(v[i],*s,32,st);}
