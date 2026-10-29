/* Module: mm3_demo_native
 * Description: Native serial-pipe executable using the unchanged tokenizer and eight-layer integer runtime.
 */
#define _POSIX_C_SOURCE 200809L
#include "demo.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <errno.h>
static uint64_t live;
void *platform_alloc(size_t size) {
    if(!size||size>SIZE_MAX-127)return NULL;
    size_t total=(size+127)&~(size_t)63;
    unsigned char *memory=aligned_alloc(64,total);if(!memory)return NULL;
    *(size_t *)memory=size;live+=size;return memory+64;
}
void platform_free(void *ptr) {if(ptr){unsigned char *base=(unsigned char *)ptr-64;live-=*(size_t *)base;free(base);}}
int platform_read(const char *path,Blob *blob) {
    FILE *file=fopen(path,"rb");if(!file)return -1;
    if(fseek(file,0,SEEK_END)){fclose(file);return -1;}
    long size=ftell(file);if(size<=0||size>70000000||fseek(file,0,SEEK_SET)){fclose(file);return -1;}
    blob->owned=platform_alloc((size_t)size);blob->data=blob->owned;blob->size=(size_t)size;
    if(!blob->owned){fclose(file);return -1;}
    size_t count=fread(blob->owned,1,blob->size,file);int failed=ferror(file);fclose(file);
    if(count!=blob->size||failed){blob_release(blob);return -1;}return 0;
}
uint64_t platform_nanoseconds(void){struct timespec now;if(clock_gettime(CLOCK_MONOTONIC,&now))return 0;return (uint64_t)now.tv_sec*1000000000u+(unsigned long)now.tv_nsec;}
void mm3_demo_putbyte(unsigned char value){putchar(value);if(value=='\n')fflush(stdout);}
int mm3_demo_getbyte(void){int value=getchar();return value==EOF?-1:value;}
void mm3_demo_request_begin(void){}
void mm3_demo_request_end(void){}
uint64_t mm3_demo_live_bytes(void){return live;}
int mm3_demo_backend(IRuntime *runtime,int accelerated){(void)runtime;return accelerated?-1:0;}
int main(int argc,char **argv) {
    const char *model=NULL,*tokenizer=NULL;unsigned maximum=1;int raw=0;
    for(int i=1;i<argc;i++) {
        if(!strcmp(argv[i],"--raw")){raw=1;continue;}
        if(i+1==argc)return 2;
        const char *option=argv[i++],*value=argv[i];
        if(!strcmp(option,"--model"))model=value;
        else if(!strcmp(option,"--tokenizer"))tokenizer=value;
        else if(!strcmp(option,"--max-new-tokens")) {
            char *end;errno=0;unsigned long count=strtoul(value,&end,10);
            if(errno||!*value||*end||!count||count>MAX_SEQ_LEN)return 2;
            maximum=(unsigned)count;
        }else return 2;
    }
    if(!model||!tokenizer)return 2;
    int result=mm3_demo_session(model,tokenizer,maximum,raw,0);
    if(live){fprintf(stderr,"allocation leak bytes=%llu\n",(unsigned long long)live);return 3;}return result;
}
