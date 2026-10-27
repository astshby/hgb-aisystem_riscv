#ifndef MM3_BAREMETAL_STRING_H
#define MM3_BAREMETAL_STRING_H
#include <stddef.h>
void *memcpy(void *,const void *,size_t);
void *memset(void *,int,size_t);
void *memmove(void *,const void *,size_t);
int memcmp(const void *,const void *,size_t);
int strcmp(const char *,const char *);
size_t strlen(const char *);
void *memchr(const void *,int,size_t);
#endif
