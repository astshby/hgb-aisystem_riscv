/* Module: mm3_baremetal_platform
 * Description: DDR allocator, integer console, mapped assets and bounded trace output.
 */
#include "integer.h"
#include <string.h>
#include <stdarg.h>
#include "benchmark_runtime.h"
static FILE console;
FILE *stdout=&console,*stderr=&console;
static uintptr_t heap=0x86000000u;
static unsigned allocation_count;
void *platform_alloc(size_t n){
 unsigned fail=((volatile const uint32_t *)(uintptr_t)0x80400000u)[4];
 if(fail && ++allocation_count>=fail)return NULL;
 if(!n||n>0x01800000u||heap>0x87e00000u-n-64)return NULL;
 uintptr_t p=(heap+63u)&~(uintptr_t)63u;heap=p+n;return (void *)p;
}
void platform_free(void *p){(void)p;}
int platform_read(const char *path,Blob *b){(void)path;(void)b;return -1;}
void platform_write(const unsigned char *p,size_t n){for(size_t i=0;i<n;i++)benchmark_putchar((char)p[i]);}
uint64_t platform_nanoseconds(void){
 uint32_t hz=*(volatile const uint32_t *)(uintptr_t)0x10040004u;
 if(!hz)return 0;
 uint64_t cycles=benchmark_read_cycle(),seconds=cycles/hz,part=((cycles%hz)*UINT64_C(1000000000))/hz;
 if(seconds>(UINT64_MAX-part)/UINT64_C(1000000000))return UINT64_MAX;
 return seconds*UINT64_C(1000000000)+part;
}
size_t strlen(const char *p){size_t n=0;while(p[n])n++;return n;}
int strcmp(const char *a,const char *b){while(*a&&*a==*b){a++;b++;}return (unsigned char)*a-(unsigned char)*b;}
int memcmp(const void *a,const void *b,size_t n){const unsigned char *x=a,*y=b;while(n--){if(*x!=*y)return *x-*y;x++;y++;}return 0;}
void *memchr(const void *p,int c,size_t n){const unsigned char *a=p;while(n--){if(*a==(unsigned char)c)return (void *)a;a++;}return NULL;}
void *memmove(void *d,const void *s,size_t n){unsigned char *a=d;const unsigned char *b=s;if((uintptr_t)a<(uintptr_t)b)return memcpy(d,s,n);while(n){n--;a[n]=b[n];}return d;}
size_t fwrite(const void *p,size_t size,size_t count,FILE *f){
 if(!size||!count||count>SIZE_MAX/size)return 0;
 size_t n=size*count;
 if(f&&f->data){if(n>f->size-f->used){f->error=1;return 0;}memcpy(f->data+f->used,p,n);f->used+=n;}
 else platform_write(p,n);
 return count;
}
/* Only the integer formats used by this runtime are supported; no float formatter is linked. */
static int format(char *dst,size_t cap,const char *fmt,va_list ap){
 size_t n=0;
#define EMIT(c) do{if(n+1<cap)dst[n]=(char)(c);n++;}while(0)
 while(*fmt){if(*fmt!='%'){EMIT(*fmt++);continue;}fmt++;
  int longs=0;while(*fmt=='l'){longs++;fmt++;}
  if(*fmt=='s'){const char *s=va_arg(ap,const char *);while(*s)EMIT(*s++);}
  else if(*fmt=='u'||*fmt=='d'){uint64_t v;int neg=0;if(*fmt=='d'){int x=va_arg(ap,int);neg=x<0;v=neg?(uint64_t)(-(int64_t)x):(uint64_t)x;}else v=longs>=2?va_arg(ap,unsigned long long):va_arg(ap,unsigned int);
   char digits[24];unsigned k=0;do{digits[k++]=(char)('0'+v%10);v/=10;}while(v);if(neg)EMIT('-');while(k)EMIT(digits[--k]);}
  else {EMIT('?');}if(*fmt)fmt++;
 }if(cap)dst[n<cap?n:cap-1]=0;return (int)n;
#undef EMIT
}
int snprintf(char *d,size_t n,const char *fmt,...){va_list a;va_start(a,fmt);int k=format(d,n,fmt,a);va_end(a);return k;}
int fprintf(FILE *f,const char *fmt,...){char text[320];va_list a;va_start(a,fmt);int n=format(text,sizeof(text),fmt,a);va_end(a);if(n<0||n>=(int)sizeof(text))return -1;return fwrite(text,1,(size_t)n,f)==(size_t)n?n:-1;}
