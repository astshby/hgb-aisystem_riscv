/* Module: mm3_accel_driver
 * Description: Synchronous MMIO backend with explicit cache/DMA ownership and no software fallback.
 */
#include "integer.h"
#include <string.h>
#include "benchmark_runtime.h"
#include "../../../tb/cache/cache_maintenance.h"
#ifndef MM3_MMIO_BASE
#define MM3_MMIO_BASE 0x20000000u
#endif
#define REG(i) (*(volatile uint32_t *)(uintptr_t)(MM3_MMIO_BASE+(i)))
static int16_t *input;
static int32_t *output;
static IScale *output_scale;
uint64_t mm3_driver_cycles,mm3_cache_cycles,mm3_submit_cycles,mm3_wait_cycles,mm3_copy_cycles;
uint64_t mm3_hardware_cycles[8];
int mm3_accel_init(int probe){input=platform_alloc(2432*2);output=platform_alloc(6400*4);output_scale=platform_alloc(64);return input&&output&&output_scale&&(!probe||REG(0)==0x4d330001u)?0:-1;}
int mm3_accel_linear(IRuntime *r,int id,int16_t *out,IScale *os,const int16_t *x,IScale xs,int logits){
 const ITensor *w=&r->model->linear[id];uint64_t begin=benchmark_read_cycle(),t=begin;
 memcpy(input,x,w->cols*2);
 output[0]=(int32_t)0xa5a5a5a5u;output_scale->m=0x40000000u;output_scale->e=1;mm3_copy_cycles+=benchmark_read_cycle()-t;
 t=benchmark_read_cycle();if(cache_maintain(CACHE_CLEAN))return -1;mm3_cache_cycles+=benchmark_read_cycle()-t;
 t=benchmark_read_cycle();REG(12)=6;
 const uint32_t cfg[]={w->rows,w->cols,(uint32_t)(uintptr_t)input,(uint32_t)(uintptr_t)w->w,(uint32_t)(uintptr_t)w->scales,(uint32_t)(uintptr_t)output,(uint32_t)(uintptr_t)output_scale,xs.m,(uint32_t)xs.e,(uint32_t)(logits!=0)};
 for(unsigned i=0;i<10;i++)REG(20+i*4)=cfg[i];
 __asm__ volatile("fence rw,rw":::"memory");REG(8)=1;mm3_submit_cycles+=benchmark_read_cycle()-t;
 t=benchmark_read_cycle();uint32_t status;
 do{status=REG(12);if(benchmark_read_cycle()-t>UINT64_C(100000000))return -1;}while(status&1u);
 mm3_wait_cycles+=benchmark_read_cycle()-t;
 if(status!=2){fprintf(stderr,"MM3 accelerator error status=%u code=%u\n",status,REG(0x10));return -1;}
 for(unsigned i=0;i<8;i++)mm3_hardware_cycles[i]+=(uint64_t)REG(0x40+i*8)|((uint64_t)REG(0x44+i*8)<<32);
 r->stats.saturated+=(uint64_t)REG(0x80)|((uint64_t)REG(0x84)<<32);
 r->stats.underflow+=(uint64_t)REG(0x88)|((uint64_t)REG(0x8c)<<32);
 t=benchmark_read_cycle();if(cache_maintain(CACHE_FLUSH))return -1;mm3_cache_cycles+=benchmark_read_cycle()-t;
 t=benchmark_read_cycle();if(logits){memcpy(r->logits,output,w->rows*4);r->ls=*output_scale;}
 else{memcpy(out,output,w->rows*2);*os=*output_scale;}
 mm3_copy_cycles+=benchmark_read_cycle()-t;mm3_driver_cycles+=benchmark_read_cycle()-begin;return 0;
}
