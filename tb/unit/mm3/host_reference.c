/* Module: mm3_host_reference
 * Description: Independent host execution of the integer model for DUT state/token/trace comparison.
 */
#include "integer.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#ifndef MM3_SIM_NEW_TOKENS
#define MM3_SIM_NEW_TOKENS 2
#endif
static uint32_t checksum(const void *p,size_t n,uint32_t h){const uint8_t *a=p;for(size_t i=0;i<n;i++)h=(h^a[i])*16777619u;return h;}
static uint32_t state_hash(const IRuntime *r,unsigned layers){
 uint32_t h=2166136261u;h=checksum(r->x,sizeof(r->x),h);h=checksum(&r->xs,sizeof(r->xs),h);h=checksum(r->logits,sizeof(r->logits),h);h=checksum(&r->ls,sizeof(r->ls),h);
 for(unsigned l=0;l<layers;l++)for(unsigned t=0;t<r->pos;t++){size_t off=((size_t)l*r->capacity+t)*384,sc=((size_t)l*r->capacity+t)*4;h=checksum(r->keys+off,768,h);h=checksum(r->values+off,768,h);h=checksum(r->ks+sc,32,h);h=checksum(r->vs+sc,32,h);}return h;
}
static int dump_values(const char *path,const void *p,size_t n,IScale scale){
 char *name=malloc(strlen(path)+8);if(!name)return -1;sprintf(name,"%s.values",path);
 FILE *f=fopen(name,"wb");free(name);if(!f)return -1;
 int rc=fwrite(p,1,n,f)!=n||fwrite(&scale,1,8,f)!=8;return fclose(f)||rc?-1:0;
}
int main(int argc,char **argv){
 if(argc!=7)return 2;
 unsigned mode=(unsigned)strtoul(argv[3],NULL,10),index=(unsigned)strtoul(argv[4],NULL,10);
 IModel m={0};IRuntime *r=calloc(1,sizeof(*r));uint32_t result[128]={0};if(!r)return 3;
 FILE *trace=NULL;if(strcmp(argv[6],"-")){trace=fopen(argv[6],"wb");if(!trace||fwrite("MM3ITR01",1,8,trace)!=8)return 4;}
 unsigned inputs=0,generated=0,steps=0,value_bytes=0;IScale saved_scale={0};uint32_t hash;
 if(mode==0||mode==4){
  int8_t w[17*33];int16_t x[33],y[17];IScale s[17],ys;
  for(unsigned i=0;i<17*33;i++)w[i]=(int8_t)((int)(i%255)-127);
  for(unsigned i=0;i<33;i++)x[i]=(int16_t)((int)(i*997)-16000);
  for(unsigned i=0;i<17;i++)s[i]=(IScale){0x45678901u+i*12345u,-12+(int)(i%3)};
  m.linear[0]=(ITensor){w,NULL,s,17,33};r->model=&m;
  if(int_linear_cpu(r,0,y,&ys,x,(IScale){0x56789abc,-11},0))return 5;
  hash=checksum(y,sizeof(y),2166136261u);hash=checksum(&ys,8,hash);value_bytes=sizeof(y);saved_scale=ys;if(dump_values(argv[5],y,value_bytes,ys))return 20;
 }else{
  if(imodel_open(&m,argv[1])||iruntime_init(r,&m,MAX_SEQ_LEN))return 6;r->trace=trace;
  if(mode==1){
   if(index>7)return 7;unsigned id=index==7?56:index;const ITensor *w=&m.linear[id];
   int16_t *x=malloc(w->cols*2),*y=malloc(w->rows*2);IScale ys;if(!x||!y)return 8;
   for(unsigned i=0;i<w->cols;i++)x[i]=(int16_t)((int)((i*997u)%65535)-32767);
   if(int_linear_cpu(r,(int)id,y,&ys,x,(IScale){0x56789abc,-11},index==7))return 9;
   hash=checksum(index==7?(const void *)r->logits:y,w->rows*(index==7?4:2),2166136261u);hash=checksum(index==7?&r->ls:&ys,8,hash);value_bytes=w->rows*(index==7?4:2);saved_scale=index==7?r->ls:ys;if(dump_values(argv[5],index==7?(const void *)r->logits:y,value_bytes,saved_scale))return 20;free(x);free(y);
  }else if(mode==2){if(iruntime_step_prefix(r,1,1,0))return 10;hash=state_hash(r,1);value_bytes=sizeof(r->x);saved_scale=r->xs;if(dump_values(argv[5],r->x,value_bytes,saved_scale))return 20;}
  else if(mode==3){
   Tokenizer tok={0};TokenIds ids={0};if(index>1||tokenizer_open(&tok,argv[2]))return 11;
   char *rendered=chat_prompt(index==0?"你好":"Hi");if(!rendered||tokenizer_encode(&tok,rendered,&ids))return 12;
   inputs=(unsigned)ids.count;
   if(trace){uint32_t meta[4]={195,inputs,32,1};IScale unit={UINT32_C(1)<<30,1};
    if(fwrite(meta,4,4,trace)!=4||fwrite(&unit,8,1,trace)!=1||fwrite(ids.ids,4,inputs,trace)!=inputs)return 21;
   }
   if(!inputs||inputs>=MAX_SEQ_LEN)return 13;
   for(unsigned i=0;i<inputs;i++)if(iruntime_step(r,ids.ids[i]))return 14;
   for(unsigned i=0;i<MM3_SIM_NEW_TOKENS&&i<64;i++){
    int next=iargmax(r->logits,6400);result[16+generated++]=(uint32_t)next;if(next==2)break;
    if(i+1==MM3_SIM_NEW_TOKENS||r->pos>=r->capacity)break;
    if(iruntime_step(r,next))return 15;steps++;
   }
   if(r->pos<r->capacity&&iruntime_step(r,1))return 16;
   hash=state_hash(r,8);value_bytes=sizeof(r->logits);saved_scale=r->ls;if(dump_values(argv[5],r->logits,value_bytes,saved_scale))return 20;token_ids_free(&ids);tokenizer_close(&tok);platform_free(rendered);
  }else return 17;
 }
 result[0]=0x4d335253;result[1]=2;result[2]=mode;result[3]=index;result[4]=hash;result[5]=inputs;result[6]=generated;result[7]=steps;result[8]=r->pos;result[15]=3;result[9]=saved_scale.m;result[10]=(uint32_t)saved_scale.e;result[12]=value_bytes;
 const uint64_t stats[]={r->stats.saturated,r->stats.underflow,r->stats.exp_outside,r->stats.sig_outside};
 for(unsigned i=0;i<4;i++){result[112+2*i]=(uint32_t)stats[i];result[113+2*i]=(uint32_t)(stats[i]>>32);}
 FILE *out=fopen(argv[5],"wb");if(!out||fwrite(result,1,sizeof(result),out)!=sizeof(result)||fclose(out))return 18;
 if(trace&&fclose(trace))return 19;
 if(mode!=0&&mode!=4) {iruntime_close(r);imodel_close(&m);}free(r);return 0;
}
