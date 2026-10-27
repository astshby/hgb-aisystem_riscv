/* Module: mm3_ops_abi
 * Description: Versioned little-endian command ABI shared by C, Python and RTL.
 */
#ifndef MM3_OPS_H
#define MM3_OPS_H
#include "integer.h"
#include "../../../vsrc/soc/mm3/mm3_config.h"
enum {MM3_OP_GEMV,MM3_OP_ADD,MM3_OP_MUL,MM3_OP_NORM,MM3_OP_ROPE,
      MM3_OP_SOFTMAX,MM3_OP_SWIGLU,MM3_OP_GEMM,MM3_OP_KV,MM3_OP_ATTENTION};
enum {MM3_CMD_MAGIC=0x334f5031u,MM3_FLAG_PV=1,MM3_FLAG_TRANSPOSE_B=2,MM3_FLAG_KV_READ=1,MM3_FLAG_KV_V_BROADCAST=2};
/* 固定 128 字节；地址均为 DDR 字节地址。未使用字段必须为零。
 * n=向量长度/GEMM列数/GEMV行数；m=GEMM行数；k=内积长度。
 * GEMV 的 b 为 INT8，其余 b 按 opcode/flags 解释。
 * GEMM stride_a/b 为元素步长，零代表连续；输出固定行主序。 */
typedef struct {
 uint32_t magic,op,n,m,k,flags,a,b,out,as,bs,os,aux,aux_scale,pos,length;
 uint32_t eps_m,eps_e,keys,values,ks,vs,capacity,inv_m,inv_e,stride_a,stride_b,reserved[5];
} MM3Command;
_Static_assert(sizeof(MM3Command)==128,"command ABI");
typedef void *(*MM3Resolve)(void *,uint32_t,size_t,int);
typedef struct {MM3Resolve resolve;void *context;IStats stats;} MM3Memory;
typedef struct {int (*submit)(void *,const MM3Command *);void *context;} MM3Backend;
IFixed mm3_rsqrt_nr(IFixed);
int mm3_norm_nr(int16_t *,IScale *,const int16_t *,IScale,const int16_t *,IScale,unsigned,IScale,IStats *);
int mm3_execute(MM3Memory *,const MM3Command *);
int mm3_run_program(MM3Backend *,const MM3Command *,size_t);
int mm3_mmio_submit(void *,const MM3Command *);
#endif
