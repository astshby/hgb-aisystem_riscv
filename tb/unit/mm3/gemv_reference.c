/* Module: gemv_reference
 * Description: Generates real-size GEMV fixtures using the original integer C execution order.
 */
#include "integer.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
static uint32_t seed=0x4d3301;
static uint32_t random32(void){seed^=seed<<13;seed^=seed>>17;seed^=seed<<5;return seed;}
static void u32(FILE *f,uint32_t x){for(unsigned i=0;i<4;i++)fputc((int)((x>>(8*i))&255),f);}
static void u64(FILE *f,uint64_t x){u32(f,(uint32_t)x);u32(f,(uint32_t)(x>>32));}
int main(int argc,char **argv){
 if(argc!=2)return 2;FILE *f=fopen(argv[1],"wb");if(!f)return 2;
 static const unsigned shapes[][3]={{1,1,0},{3,17,0},{17,33,1},{33,2432,0},{5,19,0},{7,31,1},{768,768,0},{384,768,0},{2432,768,0},{768,2432,0},{6400,768,1},{2,2432,1},{2,1,0}};
 u32(f,sizeof(shapes)/sizeof(shapes[0]));
 for(unsigned c=0;c<sizeof(shapes)/sizeof(shapes[0]);c++){
  unsigned rows=shapes[c][0],cols=shapes[c][1],head=shapes[c][2];
  int8_t *w=malloc((size_t)rows*cols);int16_t *x=malloc(cols*2),*out=malloc(rows*2);IScale *s=malloc(rows*sizeof(*s));
  IRuntime *r=calloc(1,sizeof(*r));IModel *m=calloc(1,sizeof(*m));if(!w||!x||!out||!s||!r||!m)return 3;
  for(unsigned i=0;i<rows*cols;i++)w[i]=c==4?0:(int8_t)((int)(random32()%255)-127);
  for(unsigned i=0;i<cols;i++)x[i]=c==0?0:(int16_t)((int)(random32()%65535)-32767);
  for(unsigned i=0;i<rows;i++)s[i]=(IScale){0x40000000u+random32()%0x40000000u,c==5?(int32_t)(random32()%481)-240:(int32_t)(random32()%11)-20};
  if(c==11){memset(w,0x80,(size_t)rows*cols);for(unsigned i=0;i<cols;i++)x[i]=INT16_MIN;}
  if(c==12){w[0]=127;w[1]=-127;x[0]=INT16_MAX;}
  IScale xs={0x65432101,c==5?200:-16},os;
  m->linear[0]=(ITensor){w,NULL,s,rows,cols};r->model=m;
  int_linear(r,0,out,&os,x,xs,(int)head);if(head)os=r->ls;
  uint32_t cfg[]={rows,cols,0x80000000,0x80002000,0x80600000,0x80610000,0x80620000,xs.m,(uint32_t)xs.e,head};
  for(unsigned i=0;i<10;i++)u32(f,cfg[i]);
  fwrite(w,1,(size_t)rows*cols,f);fwrite(x,2,cols,f);fwrite(s,8,rows,f);
  u32(f,os.m);u32(f,(uint32_t)os.e);u64(f,r->stats.saturated);u64(f,r->stats.underflow);
  for(unsigned j=0;j<rows;j++){
   int64_t acc=0;for(unsigned i=0;i<cols;i++)acc+=(int64_t)w[(size_t)j*cols+i]*x[i];
   u64(f,(uint64_t)acc);u64(f,(uint64_t)r->work[j].v);u32(f,(uint32_t)r->work[j].e);
   u32(f,head?(uint32_t)r->logits[j]:(uint32_t)(int32_t)out[j]);
  }
  free(w);free(x);free(out);free(s);free(r);free(m);
 }
 return fclose(f)!=0;
}
