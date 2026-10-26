/* Module: mm3_baremetal_main
 * Description: Same-ELF CPU/accelerator smoke, matrix, layer and complete-model benchmarks.
 */
#include "integer.h"
#include <string.h>
#include "benchmark_runtime.h"
#include "../../../tb/cache/cache_maintenance.h"
#include "mm3_fixture.h"
#ifndef MM3_SIM_NEW_TOKENS
#define MM3_SIM_NEW_TOKENS 2
#endif
extern int mm3_accel_init(int);
extern int mm3_accel_linear(IRuntime *,int,int16_t *,IScale *,const int16_t *,IScale,int);
extern uint64_t mm3_driver_cycles,mm3_cache_cycles,mm3_submit_cycles,mm3_wait_cycles,mm3_copy_cycles,mm3_hardware_cycles[8];
static volatile uint32_t *const boot=(volatile uint32_t *)(uintptr_t)0x80400000u;
static volatile uint32_t *const result=(volatile uint32_t *)(uintptr_t)0x80401000u;
static void save64(unsigned off,uint64_t x){result[off]=(uint32_t)x;result[off+1]=(uint32_t)(x>>32);}
static uint32_t checksum(const void *p,size_t n,uint32_t h){const uint8_t *a=p;for(size_t i=0;i<n;i++)h=(h^a[i])*16777619u;return h;}
static uint32_t state_hash(const IRuntime *r,unsigned layers){
 uint32_t h=2166136261u;h=checksum(r->x,sizeof(r->x),h);h=checksum(&r->xs,sizeof(r->xs),h);h=checksum(r->logits,sizeof(r->logits),h);h=checksum(&r->ls,sizeof(r->ls),h);
 for(unsigned l=0;l<layers;l++)for(unsigned t=0;t<r->pos;t++){
  size_t off=((size_t)l*r->capacity+t)*384,sc=((size_t)l*r->capacity+t)*4;
  h=checksum(r->keys+off,768,h);h=checksum(r->values+off,768,h);h=checksum(r->ks+sc,32,h);h=checksum(r->vs+sc,32,h);
 }return h;
}
int main(void){
 unsigned backend=boot[0],mode=boot[1],index=boot[2],trace=boot[3];
 if(backend>1||mode>4||trace>1)return 2;
 fprintf(stdout,"MM3 BOOT backend=%u mode=%u index=%u\n",backend,mode,index);
 uint64_t begin=benchmark_read_cycle();
 IModel *m=platform_alloc(sizeof(*m));IRuntime *r=platform_alloc(sizeof(*r));if(!m||!r)return 3;
 memset(m,0,sizeof(*m));memset(r,0,sizeof(*r));
 /* Both backends reserve identical DDR buffers; CPU mode never probes MMIO. */
 if(mm3_accel_init((int)backend))return 4;
 const void *values=NULL;unsigned value_bytes=0;IScale saved_scale={0};
 uint32_t hash=0;unsigned generated=0,inputs=0,decode_steps=0;int ids_out[64]={0};
 uint64_t prefill=0,decode=0,first_token=0,forced=0,startup=0;
 uint64_t saved_driver[13]={0};int counters_saved=0;
 uint64_t boot_begin=begin;
 FILE trace_file={(unsigned char *)(uintptr_t)0x80410000u,0x00b00000u,0,0};
 if(trace&&fwrite("MM3ITR01",1,8,&trace_file)!=8)return 27;
 if(mode==0||mode==4){
  unsigned rows=17,cols=33;int8_t *w=platform_alloc(rows*cols);IScale *s=platform_alloc(rows*8);
  int16_t *x=platform_alloc(cols*2),*y=platform_alloc(rows*2);if(!w||!s||!x||!y)return 5;
  for(unsigned i=0;i<rows*cols;i++)w[i]=(int8_t)((int)(i%255)-127);
  for(unsigned i=0;i<cols;i++)x[i]=(int16_t)((int)(i*997)-16000);
  for(unsigned i=0;i<rows;i++)s[i]=(IScale){0x45678901u+i*12345u,-12+(int)(i%3)};
  m->linear[0]=(ITensor){w,NULL,s,rows,cols};r->model=m;
  if(backend)r->linear_backend=mm3_accel_linear;
  volatile uint32_t *dma=(volatile uint32_t *)(uintptr_t)0x10030000u;
  uint32_t *copy_source=NULL,*copy_target=NULL;
  if(mode==4){
   copy_source=platform_alloc(32768+128);copy_target=platform_alloc(32768+128);if(!copy_source||!copy_target)return 20;
   for(unsigned i=0;i<(32768+128)/4;i++){copy_source[i]=i*1234567u+19u;copy_target[i]=0xa5a5a5a5u;}
   if(cache_maintain(CACHE_FLUSH))return 21;
   dma[4]=6;dma[0]=(uint32_t)(uintptr_t)(copy_source+16);dma[1]=(uint32_t)(uintptr_t)(copy_target+16);dma[2]=32768;
   __asm__ volatile("fence rw,rw":::"memory");dma[3]=1;
  }
  IScale ys;if(cache_maintain(CACHE_FLUSH))return 25;
   startup=benchmark_read_cycle()-boot_begin;begin=benchmark_read_cycle();if(int_linear(r,0,y,&ys,x,(IScale){0x56789abc,-11},0))return 6;
  prefill=benchmark_read_cycle()-begin;hash=checksum(y,rows*2,2166136261u);hash=checksum(&ys,8,hash);values=y;value_bytes=rows*2;saved_scale=ys;
  if(mode==4){
   begin=benchmark_read_cycle();while(dma[4]&1u)if(benchmark_read_cycle()-begin>10000000u)return 22;
   if(dma[4]!=2||cache_maintain(CACHE_FLUSH))return 23;
   for(unsigned i=0;i<(32768+128)/4;i++)if(copy_target[i]!=(i>=16&&i<16+8192?copy_source[i]:0xa5a5a5a5u))return 24;
  }
 }else{
  if((mode==3?imodel_open(m,NULL):mm3_fixture_bind(m))||iruntime_init(r,m,MAX_SEQ_LEN))return 7;
  fprintf(stdout,"MM3 MODEL_LOADED cycles=%llu\n",(unsigned long long)(benchmark_read_cycle()-begin));
  if(backend)r->linear_backend=mm3_accel_linear;
  if(trace)r->trace=&trace_file;
  if(mode==1){
   if(index>7)return 8;
   unsigned id=index==7?56:index;
   const ITensor *w=&m->linear[id];int16_t *x=platform_alloc(w->cols*2),*y=platform_alloc(w->rows*2);if(!x||!y)return 9;
   for(unsigned i=0;i<w->cols;i++)x[i]=(int16_t)((int)((i*997u)%65535)-32767);
   IScale ys;if(cache_maintain(CACHE_FLUSH))return 25;
   startup=benchmark_read_cycle()-boot_begin;begin=benchmark_read_cycle();if(int_linear(r,(int)id,y,&ys,x,(IScale){0x56789abc,-11},index==7))return 10;
   prefill=benchmark_read_cycle()-begin;
   hash=checksum(index==7?(const void *)r->logits:y,w->rows*(index==7?4:2),2166136261u);hash=checksum(index==7?&r->ls:&ys,8,hash);values=index==7?(const void *)r->logits:y;value_bytes=w->rows*(index==7?4:2);saved_scale=index==7?r->ls:ys;
  }else if(mode==2){
   if(cache_maintain(CACHE_FLUSH))return 25;
   startup=benchmark_read_cycle()-boot_begin;begin=benchmark_read_cycle();if(iruntime_step_prefix(r,1,1,0))return 11;prefill=benchmark_read_cycle()-begin;hash=state_hash(r,1);values=r->x;value_bytes=sizeof(r->x);saved_scale=r->xs;
  }else{
   Tokenizer tokenizer;TokenIds ids={0};const char *prompt=index==0?"你好":"Hi";
   if(index>1||tokenizer_open(&tokenizer,NULL))return 12;
   char *rendered=chat_prompt(prompt);if(!rendered||tokenizer_encode(&tokenizer,rendered,&ids)||!ids.count||ids.count>=MAX_SEQ_LEN)return 13;
   inputs=(unsigned)ids.count;
   if(trace){
    uint32_t meta[4]={195,inputs,32,1};IScale unit={UINT32_C(1)<<30,1};
    if(fwrite(meta,4,4,&trace_file)!=4||fwrite(&unit,8,1,&trace_file)!=1||fwrite(ids.ids,4,inputs,&trace_file)!=inputs)return 26;
   }
   fprintf(stdout,"MM3 INPUT tokens=%u\n",inputs);
   if(cache_maintain(CACHE_FLUSH))return 25;
   startup=benchmark_read_cycle()-boot_begin;begin=benchmark_read_cycle();
   /* One contiguous window includes loop/control overhead. Performance runs do
    * not print inside this window; trace runs have no speedup claim. */
   for(unsigned i=0;i<inputs;i++){
    if(iruntime_step(r,ids.ids[i]))return 14;
    if(trace)fprintf(stdout,"MM3 PREFILL position=%u\n",i);
   }
   prefill=benchmark_read_cycle()-begin;
   begin=benchmark_read_cycle();
   TextDecoder decoder={0};
   for(unsigned i=0;i<MM3_SIM_NEW_TOKENS&&i<64;i++){
    int next=iargmax(r->logits,6400);if(i==0)first_token=prefill+benchmark_read_cycle()-begin;ids_out[generated++]=next;if(next==2)break;

    if(i+1==MM3_SIM_NEW_TOKENS||r->pos>=r->capacity)break;
    if(iruntime_step(r,next))return 15;
    decode_steps++;
   }
   decode=benchmark_read_cycle()-begin;
   for(unsigned i=0;i<generated;i++)if(ids_out[i]!=2)tokenizer_emit(&decoder,&tokenizer,ids_out[i]);
   tokenizer_flush(&decoder);
   saved_driver[0]=mm3_driver_cycles;saved_driver[1]=mm3_cache_cycles;saved_driver[2]=mm3_submit_cycles;
   saved_driver[3]=mm3_wait_cycles;saved_driver[4]=mm3_copy_cycles;
   for(unsigned i=0;i<8;i++)saved_driver[5+i]=mm3_hardware_cycles[i];
   counters_saved=1;
   /* 固定输入再走一步，确保早停时也覆盖追加 KV 的路径；单独计数，不混入自由生成耗时。 */
   begin=benchmark_read_cycle();if(r->pos<r->capacity&&iruntime_step(r,1))return 16;forced=benchmark_read_cycle()-begin;
   hash=state_hash(r,8);values=r->logits;value_bytes=sizeof(r->logits);saved_scale=r->ls;
  }
 }
 if(!counters_saved){saved_driver[0]=mm3_driver_cycles;saved_driver[1]=mm3_cache_cycles;saved_driver[2]=mm3_submit_cycles;
  saved_driver[3]=mm3_wait_cycles;saved_driver[4]=mm3_copy_cycles;
  for(unsigned i=0;i<8;i++)saved_driver[5+i]=mm3_hardware_cycles[i];}
 result[0]=0x4d335253u;result[1]=backend;result[2]=mode;result[3]=index;result[4]=hash;
 result[5]=inputs;result[6]=generated;result[7]=decode_steps;result[8]=r->pos;result[15]=3;
 result[9]=saved_scale.m;result[10]=(uint32_t)saved_scale.e;result[11]=(uint32_t)(uintptr_t)values;result[12]=value_bytes;
 for(unsigned i=0;i<64;i++)result[16+i]=(uint32_t)ids_out[i];
 save64(80,prefill);save64(82,decode);save64(84,saved_driver[0]);save64(86,saved_driver[1]);
 save64(88,saved_driver[2]);save64(90,saved_driver[3]);save64(92,saved_driver[4]);
 for(unsigned i=0;i<8;i++)save64(96+i*2,saved_driver[5+i]);
 save64(112,r->stats.saturated);save64(114,r->stats.underflow);save64(116,r->stats.exp_outside);save64(118,r->stats.sig_outside);
 result[120]=(uint32_t)trace_file.used;result[121]=(uint32_t)trace_file.error;
 save64(122,first_token);save64(124,startup);save64(126,forced);
 if(trace_file.error)return 17;
 fprintf(stdout,"MM3 RESULT hash=%u prefill=%llu decode=%llu\n",hash,(unsigned long long)prefill,(unsigned long long)decode);
 if(cache_maintain(CACHE_FLUSH))return 18;
 return 0;
}
