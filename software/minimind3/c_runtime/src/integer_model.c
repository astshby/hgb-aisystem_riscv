#include "integer.h"
#ifndef MM3_FREESTANDING
#include <string.h>
#endif
static int emit(IRuntime *r,int node,const void *v,unsigned n,int bits,const IScale *s,unsigned groups){if(!r->trace)return 0;uint32_t meta[4]={(unsigned)node,n,(unsigned)bits,groups};if(fwrite(meta,4,4,r->trace)!=4||fwrite(s,sizeof(*s),groups,r->trace)!=groups||fwrite(v,(size_t)bits/8,n,r->trace)!=n)return -1;return 0;}
int iruntime_init(IRuntime *r,const IModel *m,unsigned capacity){memset(r,0,sizeof(*r));if(!capacity||capacity>m->capacity)return -1;r->model=m;r->capacity=capacity;size_t n=(size_t)8*capacity*384,heads=(size_t)8*capacity*4;r->keys=platform_alloc(n*2);r->values=platform_alloc(n*2);r->ks=platform_alloc(heads*sizeof(IScale));r->vs=platform_alloc(heads*sizeof(IScale));r->scores=platform_alloc((size_t)capacity*4);r->prob=platform_alloc((size_t)capacity*2);r->remainders=platform_alloc((size_t)capacity*8);r->order=platform_alloc((size_t)capacity*sizeof(unsigned));if(!r->keys||!r->values||!r->ks||!r->vs||!r->scores||!r->prob||!r->remainders||!r->order){iruntime_close(r);return -1;}return 0;}
void iruntime_close(IRuntime *r){platform_free(r->keys);platform_free(r->values);platform_free(r->ks);platform_free(r->vs);platform_free(r->scores);platform_free(r->prob);platform_free(r->remainders);platform_free(r->order);r->keys=r->values=NULL;r->ks=r->vs=NULL;r->scores=NULL;r->prob=NULL;r->remainders=NULL;r->order=NULL;}
void int_attention(IRuntime *r,unsigned layer){const unsigned T=r->pos+1;IFixed all[768];for(unsigned h=0;h<8;h++){unsigned kh=h/2;IFixed qfactor=if_mul(if_scale(r->qh[h]),if_scale(r->model->invsqrt96));for(unsigned t=0;t<T;t++){size_t off=((size_t)layer*r->capacity+t)*384+kh*96;int64_t acc=0;for(unsigned d=0;d<96;d++)acc+=(int64_t)r->q[h*96+d]*r->keys[off+d];IFixed value=if_mul(if_mul(if_make(acc,0),qfactor),if_scale(r->ks[((size_t)layer*r->capacity+t)*4+kh]));value.e+=16;r->scores[t]=(int32_t)if_integer(value,32,&r->stats);}int_softmax(r,T);
 /* Align historical V to a common scale with 14 guard bits before the weighted sum. */
 IScale base={UINT32_C(1)<<30,1};int found=0;
 for(unsigned t=0;t<T;t++){
  size_t off=((size_t)layer*r->capacity+t)*384+kh*96;int nonzero=0;
  for(unsigned d=0;d<96;d++)nonzero|=r->values[off+d]!=0;
  if(nonzero){IScale s=r->vs[((size_t)layer*r->capacity+t)*4+kh];if(!found||s.e>base.e||(s.e==base.e&&s.m>base.m))base=s;found=1;}
 }
 base.e-=14;int64_t sums[96]={0};for(unsigned t=0;t<T;t++){size_t off=((size_t)layer*r->capacity+t)*384+kh*96;IScale s=r->vs[((size_t)layer*r->capacity+t)*4+kh];IFixed ratio=if_div(if_scale(s),if_scale(base));for(unsigned d=0;d<96;d++){int64_t aligned=if_integer(if_mul(if_make(r->values[off+d],0),ratio),32,&r->stats);sums[d]+=aligned*r->prob[t];}}IFixed factor=if_div(if_scale(base),if_make(65535,0));for(unsigned d=0;d<96;d++)all[h*96+d]=if_mul(if_make(sums[d],0),factor);}int_pack16(r->a,&r->as,all,768,&r->stats);}
int iruntime_step_prefix(IRuntime *r,int token,unsigned layers,int head){if(!layers||layers>8||token<0||token>=6400||r->pos>=r->capacity)return -1;const IModel *m=r->model;const ITensor *embed=&m->linear[56];for(unsigned i=0;i<768;i++)r->work[i]=if_value(embed->w[(size_t)token*768+i],embed->scales[token]);int_pack16(r->x,&r->xs,r->work,768,&r->stats);
#define LINEAR(...) do{if(int_linear(__VA_ARGS__))return -1;}while(0)
#define OBS(node,data,n,bits,s,g) do{if(emit(r,node,data,n,bits,s,g))return -1;}while(0)
 OBS(194,r->x,768,16,&r->xs,1);
 for(unsigned l=0;l<layers;l++){unsigned n=l*24;
 int_norm(r,r->z,&r->zs,r->x,r->xs,&m->norm[l*4],768);OBS(n,r->z,768,16,&r->zs,1);
 LINEAR(r,l*7,r->q,&r->qs,r->z,r->zs,0);OBS(n+1,r->q,768,16,&r->qs,1);
 LINEAR(r,l*7+1,r->k,&r->ks0,r->z,r->zs,0);OBS(n+2,r->k,384,16,&r->ks0,1);
 LINEAR(r,l*7+2,r->v,&r->vs0,r->z,r->zs,0);OBS(n+3,r->v,384,16,&r->vs0,1);
 for(unsigned h=0;h<8;h++)int_norm(r,r->q+h*96,&r->qh[h],r->q+h*96,r->qs,&m->norm[l*4+2],96);
 for(unsigned h=0;h<4;h++)int_norm(r,r->k+h*96,&r->kh[h],r->k+h*96,r->ks0,&m->norm[l*4+3],96);
 OBS(n+4,r->q,768,16,r->qh,8);OBS(n+5,r->k,384,16,r->kh,4);
 for(unsigned h=0;h<8;h++)int_rope(r,r->q+h*96,&r->qh[h]);
 for(unsigned h=0;h<4;h++)int_rope(r,r->k+h*96,&r->kh[h]);
 OBS(n+6,r->q,768,16,r->qh,8);OBS(n+7,r->k,384,16,r->kh,4);
 size_t off=((size_t)l*r->capacity+r->pos)*384,sh=((size_t)l*r->capacity+r->pos)*4;memcpy(r->keys+off,r->k,768);memcpy(r->values+off,r->v,768);for(unsigned h=0;h<4;h++){r->ks[sh+h]=r->kh[h];r->vs[sh+h]=r->vs0;}
 int_attention(r,l);OBS(n+8,r->a,768,16,&r->as,1);
 LINEAR(r,l*7+3,r->tmp,&r->ts,r->a,r->as,0);OBS(n+9,r->tmp,768,16,&r->ts,1);
 int_residual(r,r->x,&r->xs,r->x,r->xs,r->tmp,r->ts,768);OBS(n+10,r->x,768,16,&r->xs,1);
 int_norm(r,r->z,&r->zs,r->x,r->xs,&m->norm[l*4+1],768);OBS(n+11,r->z,768,16,&r->zs,1);
 LINEAR(r,l*7+4,r->g,&r->gs,r->z,r->zs,0);OBS(n+12,r->g,2432,16,&r->gs,1);
 LINEAR(r,l*7+5,r->u,&r->us,r->z,r->zs,0);OBS(n+13,r->u,2432,16,&r->us,1);
 int_swiglu(r);OBS(n+14,r->g,2432,16,&r->gs,1);
 LINEAR(r,l*7+6,r->tmp,&r->ts,r->g,r->gs,0);OBS(n+15,r->tmp,768,16,&r->ts,1);
 int_residual(r,r->x,&r->xs,r->x,r->xs,r->tmp,r->ts,768);OBS(n+16,r->x,768,16,&r->xs,1);OBS(n+17,r->k,384,16,r->kh,4);OBS(n+18,r->v,384,16,&r->vs0,1);
 }
 if(head){int_norm(r,r->z,&r->zs,r->x,r->xs,&m->norm[32],768);OBS(192,r->z,768,16,&r->zs,1);LINEAR(r,56,NULL,NULL,r->z,r->zs,1);OBS(193,r->logits,6400,32,&r->ls,1);}
 r->pos++;return 0;
#undef LINEAR
#undef OBS
}
int iargmax(const int32_t *x,unsigned n){unsigned best=0;for(unsigned i=1;i<n;i++)if(x[i]>x[best])best=i;return (int)best;}

int iruntime_step(IRuntime *r,int token){return iruntime_step_prefix(r,token,8,1);}
