/* Module: mm3_reference_main
 * Description: Hosted C oracle for operator programs; invoked only by explicit user test targets.
 */
#include "mm3_ops.h"
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
typedef struct {unsigned char *data;size_t size;uint32_t base;} Image;
static void *resolve(void *ctx,uint32_t addr,size_t n,int write){
 (void)write;Image *m=ctx;if(addr<m->base||(uint64_t)addr+n>(uint64_t)m->base+m->size)return NULL;return m->data+(addr-m->base);
}
static unsigned char *load(const char *path,size_t *size){
 FILE *f=fopen(path,"rb");if(!f)return NULL;if(fseek(f,0,SEEK_END)||ftell(f)<0){fclose(f);return NULL;}*size=(size_t)ftell(f);rewind(f);
 unsigned char *p=malloc(*size?*size:1);if(!p||fread(p,1,*size,f)!=*size){free(p);fclose(f);return NULL;}fclose(f);return p;
}
static int submit(void *ctx,const MM3Command *c){return mm3_execute(ctx,c);}
static int trace_command(Image *image,const MM3Command *c,size_t index,const char *directory){
 char path[4096];if(snprintf(path,sizeof(path),"%s/op-%03zu.bin",directory,index)>=(int)sizeof(path))return -1;
 FILE *file=fopen(path,"wb");if(!file)return -1;
 uint32_t addresses[4]={c->out,c->os,0,0},sizes[4]={c->op==MM3_OP_GEMM?c->m*c->n*8:c->n*2,8,0,0};
 unsigned count=(c->op==MM3_OP_GEMM||c->op==MM3_OP_SOFTMAX)?1:2;
 if(c->op==MM3_OP_KV){
  count=4;sizes[0]=sizes[1]=c->n*2;sizes[2]=sizes[3]=32;
  addresses[0]=(c->flags&MM3_FLAG_KV_READ)?c->a:c->keys+c->pos*c->n*2;
  addresses[1]=(c->flags&MM3_FLAG_KV_READ)?c->b:c->values+c->pos*c->n*2;
  addresses[2]=(c->flags&MM3_FLAG_KV_READ)?c->as:c->ks+c->pos*32;
  addresses[3]=(c->flags&MM3_FLAG_KV_READ)?c->bs:c->vs+c->pos*32;
 }
 for(unsigned i=0;i<count;i++){void *data=resolve(image,addresses[i],sizes[i],0);if(!data||fwrite(data,1,sizes[i],file)!=sizes[i]){fclose(file);return -1;}}
 return fclose(file);
}
int main(int argc,char **argv){
 if(argc!=5&&argc!=6){fprintf(stderr,"usage: reference IMAGE COMMANDS RANGES OUTPUT [TRACE_DIRECTORY]\n");return 2;}
 Image image={0};size_t cb,rb;image.base=0x81000000u;image.data=load(argv[1],&image.size);
 unsigned char *commands=load(argv[2],&cb),*ranges=load(argv[3],&rb);
 if(!image.data||!commands||!ranges||cb%128||rb%8)return 3;
 MM3Memory mem={resolve,&image,{0}};MM3Backend backend={submit,&mem};
 int rc=0;for(size_t i=0;i<cb/128;i++){
  const MM3Command *cmd=(const MM3Command *)(commands+i*128);
  rc=mm3_run_program(&backend,cmd,1);
  if(rc){fprintf(stderr,"C command %zu failure: %d\n",i,rc);return 4;}
  if(argc==6&&trace_command(&image,cmd,i,argv[5]))return 8;
 }
 FILE *out=fopen(argv[4],"wb");if(!out)return 5;
 for(size_t i=0;i<rb;i+=8){uint32_t address=read_u32(ranges+i),n=read_u32(ranges+i+4);void *p=resolve(&image,address,n,0);if(!p||fwrite(p,1,n,out)!=n)return 6;}
 if(fclose(out))return 7;
 free(image.data);free(commands);free(ranges);printf("C_REFERENCE_READY saturation=%llu underflow=%llu exp_outside=%llu sigmoid_outside=%llu\n",(unsigned long long)mem.stats.saturated,(unsigned long long)mem.stats.underflow,(unsigned long long)mem.stats.exp_outside,(unsigned long long)mem.stats.sig_outside);return 0;
}
