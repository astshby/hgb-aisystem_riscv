/* Module: mm3_integer_ops
 * Description: Integer command reference; original runtime math and default prompt are untouched.
 */
#include "mm3_ops.h"
#include "mm3_tables.h"
#include <string.h>
static uint64_t rne(uint64_t v,unsigned s){if(!s)return v;uint64_t q=v>>s,r=v&((UINT64_C(1)<<s)-1),h=UINT64_C(1)<<(s-1);return q+(r>h||(r==h&&(q&1)));}
IFixed mm3_rsqrt_nr(IFixed s){
 if(s.v<=0)return (IFixed){0,0};
 int E=s.e+60,p=(E%2+2)%2,k=(E-p)/2;
 unsigned index=((unsigned)((uint64_t)s.v>>(60-MM3_RSQRT_LUT_BITS)))&((1u<<MM3_RSQRT_LUT_BITS)-1);
 uint64_t t=rne((uint64_t)s.v,(unsigned)(30-p)); /* 额外位允许端点 4.0。 */
 uint64_t y=mm3_rsqrt_seed[(p<<MM3_RSQRT_LUT_BITS)+index];
 for(unsigned i=0;i<MM3_RSQRT_ITERS;i++){
  uint64_t y2=rne(y*y,31),ty2=rne(t*y2,30);
  if(ty2>=(UINT64_C(3)<<31))return (IFixed){0,0};
  uint64_t correction=rne((UINT64_C(3)<<31)-ty2,1);
  y=rne(y*correction,31);if(y>(UINT64_C(1)<<31))y=UINT64_C(1)<<31;
 }
 return if_make((int64_t)y,-31-k);
}
int mm3_norm_nr(int16_t *out,IScale *os,const int16_t *x,IScale xs,const int16_t *gamma,IScale gs,unsigned n,IScale eps,IStats *st){
 if(!n||n>MM3_NORM_MAX_LEN)return -1;
 uint64_t sum=0;for(unsigned i=0;i<n;i++)sum+=(uint64_t)((int64_t)x[i]*x[i]);
 IFixed sx=if_scale(xs),var=if_mul(if_mul(if_make((int64_t)sum,0),if_mul(sx,sx)),if_make((int64_t)mm3_length_recip[n],-48));
 IFixed inv=mm3_rsqrt_nr(if_add(var,if_scale(eps)));if(!inv.v)return -1;
 IFixed factor=if_mul(if_mul(sx,if_scale(gs)),inv);IFixed work[MM3_NORM_MAX_LEN];
 for(unsigned i=0;i<n;i++)work[i]=if_mul(if_make((int64_t)x[i]*gamma[i],0),factor);
 int_pack16(out,os,work,n,st);return 0;
}
static unsigned sigmoid(const uint16_t *lut,IFixed x,IStats *st){
 x.e+=16;int64_t q=if_integer(x,32,NULL);
 if(q<-(INT64_C(16)<<16)){st->sig_outside++;return 0;}
 if(q>(INT64_C(16)<<16)){st->sig_outside++;return 65535;}
 unsigned t=(unsigned)(q+(INT64_C(16)<<16)),i=t>>8,f=t&255;
 if(i>=8192)return lut[8192];return (unsigned)rne((uint64_t)lut[i]*(256-f)+(uint64_t)lut[i+1]*f,8);
}
int mm3_execute(MM3Memory *mem,const MM3Command *c){
 if(!mem||!mem->resolve||!c||c->magic!=MM3_CMD_MAGIC||c->op>MM3_OP_ATTENTION||!c->n||c->n>MM3_MAX_VECTOR)return -1;
 if((c->op==MM3_OP_GEMM&&(!c->m||!c->k||c->m>MM3_GEMM_MAX_M||c->n>MM3_GEMM_MAX_N||c->k>MM3_GEMM_MAX_K||(c->flags&~3u)))||
    (c->op==MM3_OP_GEMV&&(!c->k||c->k>2432))||
    (c->op==MM3_OP_SOFTMAX&&c->n>MM3_SEQ_CAP)||
    (c->op==MM3_OP_KV&&(c->flags&~3u)))return -1;
 unsigned astride=c->stride_a?c->stride_a:c->k,bstride=c->stride_b?c->stride_b:((c->flags&MM3_FLAG_TRANSPOSE_B)?c->k:c->n);
 if(c->op==MM3_OP_GEMM&&(astride>MM3_GEMM_MAX_M*MM3_GEMM_MAX_K||bstride>MM3_GEMM_MAX_K*MM3_GEMM_MAX_N))return -1;
 size_t aspan=c->op==MM3_OP_GEMM?(size_t)(c->m-1)*astride+c->k:0;
 size_t bspan=c->op==MM3_OP_GEMM?(size_t)((c->flags&MM3_FLAG_TRANSPOSE_B)?c->n-1:c->k-1)*bstride+((c->flags&MM3_FLAG_TRANSPOSE_B)?c->k:c->n):0;
 if(c->op==MM3_OP_GEMM&&(astride<c->k||bstride<((c->flags&MM3_FLAG_TRANSPOSE_B)?c->k:c->n)||aspan>MM3_GEMM_MAX_M*MM3_GEMM_MAX_K||bspan>MM3_GEMM_MAX_K*MM3_GEMM_MAX_N))return -1;
#define GET(type,name,addr,count,write) type *name=(type *)mem->resolve(mem->context,addr,(size_t)(count)*sizeof(type),write);if(!name)return -2
 GET(int16_t,a,c->a,c->op==MM3_OP_GEMM?aspan:c->op==MM3_OP_GEMV?c->k:c->n,c->op==MM3_OP_KV&&(c->flags&MM3_FLAG_KV_READ));
 if(c->op==MM3_OP_GEMM){
  if(!c->m||!c->k||c->m>MM3_GEMM_MAX_M||c->n>MM3_GEMM_MAX_N||c->k>MM3_GEMM_MAX_K)return -1;
  size_t bn=bspan;GET(unsigned char,b,c->b,bn*((c->flags&MM3_FLAG_PV)?4:2),0);GET(int64_t,y,c->out,c->m*c->n,1);
  for(unsigned i=0;i<c->m;i++)for(unsigned j=0;j<c->n;j++){
   int64_t sum=0;for(unsigned k=0;k<c->k;k++){
    unsigned bi=(c->flags&MM3_FLAG_TRANSPOSE_B)?j*bstride+k:k*bstride+j;
    int64_t av=(c->flags&MM3_FLAG_PV)?(uint16_t)a[i*astride+k]:a[i*astride+k];
    int64_t bv=(c->flags&MM3_FLAG_PV)?((int32_t *)b)[bi]:((int16_t *)b)[bi];sum+=av*bv;
   }y[i*c->n+j]=sum;
  }return 0;
 }
 if(c->op==MM3_OP_SOFTMAX){
  GET(int32_t,scores,c->a,c->n,0);GET(uint16_t,prob,c->out,c->n,1);GET(uint32_t,lut,c->aux,4097,0);
  IRuntime *r=platform_alloc(sizeof(*r));IModel m={0};if(!r)return -3;memset(r,0,sizeof(*r));
  r->scores=scores;r->prob=prob;r->remainders=platform_alloc(c->n*8);r->order=platform_alloc(c->n*4);m.exp_lut=lut;r->model=&m;
  if(!r->remainders||!r->order){platform_free(r->remainders);platform_free(r->order);platform_free(r);return -3;}
  int_softmax(r,c->n);mem->stats.exp_outside+=r->stats.exp_outside;platform_free(r->remainders);platform_free(r->order);platform_free(r);return 0;
 }
 if(c->op==MM3_OP_KV){
  if(c->n!=MM3_KV_HEADS*MM3_HEAD_DIM||c->pos>=c->capacity||c->capacity>MM3_SEQ_CAP)return -1;
  GET(int16_t,b,c->b,c->n,(c->flags&MM3_FLAG_KV_READ)!=0);GET(IScale,as,c->as,MM3_KV_HEADS,(c->flags&MM3_FLAG_KV_READ)!=0);GET(IScale,bs,c->bs,(c->flags&MM3_FLAG_KV_V_BROADCAST)&&!(c->flags&MM3_FLAG_KV_READ)?1:MM3_KV_HEADS,(c->flags&MM3_FLAG_KV_READ)!=0);
  GET(int16_t,keys,c->keys+c->pos*c->n*2,c->n,1);GET(int16_t,values,c->values+c->pos*c->n*2,c->n,1);
  GET(IScale,ks,c->ks+c->pos*MM3_KV_HEADS*8,MM3_KV_HEADS,1);GET(IScale,vs,c->vs+c->pos*MM3_KV_HEADS*8,MM3_KV_HEADS,1);
  if(c->flags&MM3_FLAG_KV_READ){memcpy(a,keys,c->n*2);memcpy(b,values,c->n*2);memcpy(as,ks,MM3_KV_HEADS*8);memcpy(bs,vs,MM3_KV_HEADS*8);}
  else{memcpy(keys,a,c->n*2);memcpy(values,b,c->n*2);memcpy(ks,as,MM3_KV_HEADS*8);if(c->flags&MM3_FLAG_KV_V_BROADCAST)for(unsigned h=0;h<MM3_KV_HEADS;h++)vs[h]=bs[0];else memcpy(vs,bs,MM3_KV_HEADS*8);}return 0;
 }
 GET(int16_t,y,c->out,c->n,1);GET(IScale,as,c->as,c->op==MM3_OP_ATTENTION?MM3_QUERY_HEADS:1,0);GET(IScale,os,c->os,1,1);
 if(c->op==MM3_OP_ATTENTION){
  if(c->n!=768||!c->length||c->length>c->capacity||c->capacity>MM3_SEQ_CAP)return -1;
  GET(int16_t,keys,c->keys,c->capacity*384,0);GET(int16_t,values,c->values,c->capacity*384,0);
  GET(IScale,ks,c->ks,c->capacity*4,0);GET(IScale,vs,c->vs,c->capacity*4,0);GET(uint32_t,exp,c->aux,4097,0);
  IRuntime *r=platform_alloc(sizeof(*r));IModel m={0};if(!r)return -3;memset(r,0,sizeof(*r));r->model=&m;
  r->keys=keys;r->values=values;r->ks=ks;r->vs=vs;r->capacity=c->capacity;r->pos=c->length-1;
  memcpy(r->q,a,1536);memcpy(r->qh,as,64);m.invsqrt96=(IScale){c->inv_m,(int32_t)c->inv_e};m.exp_lut=exp;
  r->scores=platform_alloc(c->length*4);r->prob=platform_alloc(c->length*2);r->remainders=platform_alloc(c->length*8);r->order=platform_alloc(c->length*4);
  if(!r->scores||!r->prob||!r->remainders||!r->order){platform_free(r->scores);platform_free(r->prob);platform_free(r->remainders);platform_free(r->order);platform_free(r);return -3;}
  int_attention(r,0);memcpy(y,r->a,1536);*os=r->as;mem->stats.saturated+=r->stats.saturated;mem->stats.underflow+=r->stats.underflow;mem->stats.exp_outside+=r->stats.exp_outside;
  platform_free(r->scores);platform_free(r->prob);platform_free(r->remainders);platform_free(r->order);platform_free(r);return 0;
 }
 GET(IScale,bs,c->bs,c->op==MM3_OP_GEMV?c->n:1,0);
 if(c->op==MM3_OP_NORM){GET(int16_t,g,c->b,c->n,0);return mm3_norm_nr(y,os,a,*as,g,*bs,c->n,(IScale){c->eps_m,(int32_t)c->eps_e},&mem->stats);}
 /* 在分配临时向量前校验后续输入，错误路径不会泄漏 work。 */
 size_t bbytes=c->op==MM3_OP_GEMV?(size_t)c->n*c->k:(size_t)c->n*2;
 if(!mem->resolve(mem->context,c->b,bbytes,0))return -2;
 IFixed *work=platform_alloc(c->n*sizeof(*work));if(!work)return -3;
 int rc=0;
 if(c->op==MM3_OP_GEMV){GET(int8_t,w,c->b,c->n*c->k,0);for(unsigned row=0;row<c->n;row++){int64_t sum=0;for(unsigned j=0;j<c->k;j++)sum+=(int64_t)w[row*c->k+j]*a[j];work[row]=if_mul(if_mul(if_make(sum,0),if_scale(*as)),if_scale(bs[row]));}}
 else if(c->op==MM3_OP_ROPE){
  if(c->n!=96){platform_free(work);return -1;}GET(int16_t,t,c->b,c->n,0);IFixed f=if_scale(*as);f.e-=15;
  for(unsigned i=0;i<48;i++){work[i]=if_mul(if_make((int64_t)a[i]*t[2*i]-(int64_t)a[i+48]*t[2*i+1],0),f);work[i+48]=if_mul(if_make((int64_t)a[i+48]*t[2*i]+(int64_t)a[i]*t[2*i+1],0),f);}
 }else{
  GET(int16_t,b,c->b,c->n,0);IFixed factor=if_mul(if_scale(*as),if_scale(*bs));
  if(c->op==MM3_OP_SWIGLU)factor=if_div(factor,if_make(65535,0));
  const uint16_t *lut=NULL;if(c->op==MM3_OP_SWIGLU){lut=mem->resolve(mem->context,c->aux,8193*2,0);if(!lut){platform_free(work);return -2;}}
  for(unsigned i=0;i<c->n;i++){
   if(c->op==MM3_OP_ADD)work[i]=if_add(if_value(a[i],*as),if_value(b[i],*bs));
   else if(c->op==MM3_OP_MUL||c->op==MM3_OP_SWIGLU){int64_t product=(int64_t)a[i]*b[i];if(lut)product*=sigmoid(lut,if_value(a[i],*as),&mem->stats);work[i]=if_mul(if_make(product,0),factor);}
   else{rc=-1;break;}
  }
 }
 if(!rc)int_pack16(y,os,work,c->n,&mem->stats);platform_free(work);return rc;
#undef GET
}
int mm3_run_program(MM3Backend *b,const MM3Command *cmd,size_t count){if(!b||!b->submit)return -1;for(size_t i=0;i<count;i++){int rc=b->submit(b->context,cmd+i);if(rc)return rc;}return 0;}
