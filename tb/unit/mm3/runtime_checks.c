/* Module: mm3_runtime_checks
 * Description: Host checks of loader corruption, token bounds, allocation and backend error propagation.
 */
#define _POSIX_C_SOURCE 200809L
#include "integer.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
static unsigned calls;
static int fail_linear(IRuntime *r,int id,int16_t *out,IScale *os,const int16_t *x,IScale xs,int head){
 (void)r;(void)id;(void)out;(void)os;(void)x;(void)xs;(void)head;calls++;return -99;
}
static int save(const char *path,const void *p,size_t n){FILE *f=fopen(path,"wb");if(!f)return -1;int rc=fwrite(p,1,n,f)!=n;return fclose(f)||rc?-1:0;}
static void put32(unsigned char *p,uint32_t v){for(unsigned i=0;i<4;i++)p[i]=(unsigned char)(v>>(8*i));}
int main(int argc,char **argv){
 if(argc!=3)return 2;IModel m={0},bad={0};IRuntime *r=calloc(1,sizeof(*r));if(!r||imodel_open(&m,argv[1]))return 3;
 if(iruntime_init(r,&m,2))return 4;
 if(iruntime_step(r,-1)!=-1||iruntime_step(r,6400)!=-1||iruntime_step_prefix(r,1,0,0)!=-1||iruntime_step_prefix(r,1,9,0)!=-1)return 5;
 r->pos=2;if(iruntime_step(r,1)!=-1)return 6;r->pos=0;r->linear_backend=fail_linear;
 if(iruntime_step(r,1)!=-1||calls!=1||r->pos!=0)return 7;
 iruntime_close(r);
 if(setenv("MM3_ALLOC_FAIL_AFTER","0",1)||iruntime_init(r,&m,2)!=-1)return 8;
 unsetenv("MM3_ALLOC_FAIL_AFTER");iruntime_close(r);
 if(save(argv[2],m.blob.data,64)||imodel_open(&bad,argv[2])!=-1)return 9;
 unsigned char *p=m.blob.owned;if(!p)return 10;
 p[15040]^=1;if(save(argv[2],p,m.blob.size)||imodel_open(&bad,argv[2])!=-1)return 11;p[15040]^=1;
 size_t scale=(size_t)read_u64(p+128+128);put32(p+scale,0);put32(p+m.blob.size-4,crc32_bytes(p,m.blob.size-4));
 if(save(argv[2],p,m.blob.size)||imodel_open(&bad,argv[2])!=-1)return 12;
 imodel_close(&m);free(r);if(remove(argv[2]))return 13;
 puts("PASS MM3_RUNTIME token/context bounds, backend error propagation, allocation failure, truncated/checksum/CRC-valid corrupt scales");return 0;
}
