/* Module: mm3_stdio
 * Description: Integer-only bare-metal console and bounded diagnostic trace stream.
 */
#ifndef MM3_BAREMETAL_STDIO_H
#define MM3_BAREMETAL_STDIO_H
#include <stddef.h>
#include <stdarg.h>
typedef struct mm3_file {unsigned char *data;size_t size,used;int error;} FILE;
extern FILE *stdout,*stderr;
size_t fwrite(const void *,size_t,size_t,FILE *);
int fprintf(FILE *,const char *,...);
int snprintf(char *,size_t,const char *,...);
#endif
