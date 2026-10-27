/* Module: mm3_operator_driver
 * Description: Explicit cache ownership and one in-flight command; errors never fall back to C.
 */
#include "mm3_ops.h"
#ifdef __riscv
#include "benchmark_runtime.h"
#include "../../../tb/cache/cache_maintenance.h"
#ifndef MM3_MMIO_BASE
#define MM3_MMIO_BASE 0x20000000u
#endif
#define REG(o) (*(volatile uint32_t *)(uintptr_t)(MM3_MMIO_BASE+(o)))
int mm3_mmio_submit(void *context,const MM3Command *c){
 (void)context;
 if(!c||c->magic!=MM3_CMD_MAGIC||((uintptr_t)c&63)||c->op>MM3_OP_ATTENTION)return -1;
 if(REG(0)!=0x4d330001u)return -2;
 if(REG(12)&1u)return -3;
 if(cache_maintain(CACHE_CLEAN))return -4;
 REG(12)=6;
 if(c->op==MM3_OP_GEMV){
  IScale xs=*(volatile const IScale *)(uintptr_t)c->as;
  const uint32_t cfg[]={c->n,c->k,c->a,c->b,c->bs,c->out,c->os,xs.m,(uint32_t)xs.e,0};
  for(unsigned i=0;i<10;i++)REG(20+4*i)=cfg[i];
 }else{
  if(REG(0x98)!=0x00010000u)return -5;
  REG(0x90)=c->op;REG(0x94)=(uint32_t)(uintptr_t)c;
 }
 __asm__ volatile("fence rw,rw":::"memory");REG(8)=1;
 uint64_t start=benchmark_read_cycle();uint32_t status;
 do{status=REG(12);if(benchmark_read_cycle()-start>MM3_TIMEOUT_CYCLES)return -6;}while(status&1u);
 if(status!=2)return -7;
 if(cache_maintain(CACHE_FLUSH))return -8;
 __asm__ volatile("fence rw,rw":::"memory");return 0;
}
#else
int mm3_mmio_submit(void *context,const MM3Command *c){(void)context;(void)c;return -99;}
#endif
