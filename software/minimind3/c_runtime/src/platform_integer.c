#define _POSIX_C_SOURCE 200809L
#include "mm3.h"
#include <stdlib.h>
#include <time.h>
#include <errno.h>
#include <string.h>
static long allocation_count;
void *platform_alloc(size_t n) {
    const char *fail=getenv("MM3_ALLOC_FAIL_AFTER");
    if(fail && allocation_count++>=strtol(fail,NULL,10)) return NULL;
    if(!n || n>SIZE_MAX-63) return NULL;
    return aligned_alloc(64,(n+63)&~(size_t)63);
}
void platform_free(void *p) { free(p); }
int platform_read(const char *path, Blob *b) {
    FILE *f=fopen(path,"rb");
    if(!f) { fprintf(stderr,"Cannot open %s: %s\n",path,strerror(errno)); return -1; }
    if(fseek(f,0,SEEK_END)) { fclose(f); return -1; }
    long len=ftell(f);
    if(len<0 || fseek(f,0,SEEK_SET)) { fclose(f); return -1; }
    b->owned=platform_alloc((size_t)len);
    if(!b->owned) { fprintf(stderr,"Allocation failed loading %s\n",path); fclose(f); return -1; }
    b->size=(size_t)len; b->data=b->owned;
    size_t got=fread(b->owned,1,b->size,f); int failed=ferror(f); fclose(f);
    if(got!=b->size || failed) { blob_release(b); return -1; }
    return 0;
}
void platform_write(const unsigned char *p,size_t n) { fwrite(p,1,n,stdout); }
uint64_t platform_nanoseconds(void) { struct timespec t; if(clock_gettime(CLOCK_MONOTONIC,&t))return 0;return (uint64_t)t.tv_sec*1000000000u+(uint64_t)t.tv_nsec; }
