#ifndef MM3_INTEGER_H
#define MM3_INTEGER_H
#include <stdint.h>
#include <stddef.h>
#include "mm3.h"
/* real = integer * m * 2^(e-31), 2^30 <= m < 2^31. */
typedef struct { uint32_t m; int32_t e; } IScale;
/* Internal wide dyadic intermediate, normalized to 61 magnitude bits. */
typedef struct { int64_t v; int32_t e; } IFixed;
typedef struct { uint64_t saturated,underflow,exp_outside,sig_outside; } IStats;
typedef struct { const int8_t *w;const int16_t *gamma;const IScale *scales;uint32_t rows,cols; } ITensor;
typedef struct {
 Blob blob;ITensor linear[57],norm[33];const uint32_t *exp_lut;const uint16_t *sig_lut;const int16_t *rope;
 unsigned capacity;IScale epsilon,invsqrt96;
} IModel;
typedef struct IRuntime {
 const IModel *model;unsigned capacity,pos;IStats stats;
 int16_t *keys,*values;IScale *ks,*vs;
 int16_t x[768],z[768],q[768],k[384],v[384],a[768],tmp[768],g[2432],u[2432];
 IScale xs,zs,qs,ks0,vs0,as,ts,gs,us,qh[8],kh[4];
 int32_t logits[6400],*scores;IScale ls;
 uint16_t *prob;uint64_t *remainders;unsigned *order;
 IFixed work[6400];
 int (*linear_backend)(struct IRuntime *,int,int16_t *,IScale *,const int16_t *,IScale,int);
 void *backend_context;
 FILE *trace;
} IRuntime;
uint64_t platform_nanoseconds(void);
IFixed if_make(int64_t,int);IFixed if_add(IFixed,IFixed);IFixed if_mul(IFixed,IFixed);IFixed if_div(IFixed,IFixed);IFixed if_sqrt(IFixed);
IFixed if_scale(IScale);IFixed if_value(int64_t,IScale);IScale iscale_max(IFixed,uint32_t);
int64_t if_integer(IFixed,unsigned,IStats *);int64_t if_quant(IFixed,IScale,unsigned,IStats *);
uint64_t integer_sqrt64(uint64_t);
void int_pack16(int16_t *,IScale *,const IFixed *,unsigned,IStats *);
void int_pack32(int32_t *,IScale *,const IFixed *,unsigned,IStats *);
int int_linear_cpu(IRuntime *,int,int16_t *,IScale *,const int16_t *,IScale,int);
int int_linear(IRuntime *,int,int16_t *,IScale *,const int16_t *,IScale,int);
void int_norm(IRuntime *,int16_t *,IScale *,const int16_t *,IScale,const ITensor *,unsigned);
void int_rope(IRuntime *,int16_t *,IScale *);
void int_softmax(IRuntime *,unsigned);
void int_attention(IRuntime *,unsigned);
void int_swiglu(IRuntime *);
void int_residual(IRuntime *,int16_t *,IScale *,const int16_t *,IScale,const int16_t *,IScale,unsigned);
int imodel_open(IModel *,const char *);void imodel_close(IModel *);
int iruntime_init(IRuntime *,const IModel *,unsigned);void iruntime_close(IRuntime *);int iruntime_step_prefix(IRuntime *,int,unsigned,int);int iruntime_step(IRuntime *,int);int iargmax(const int32_t *,unsigned);
#endif
