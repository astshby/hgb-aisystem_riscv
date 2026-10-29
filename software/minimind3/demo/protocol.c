/* Module: mm3_demo_protocol
 * Description: Hex-framed decoded token bytes keep arbitrary UTF-8 separate from control lines.
 */
#include "demo.h"
static unsigned char captured[1024];
static unsigned capture_size;
static int capture_token, capturing, capture_error;
void mm3_demo_puts(const char *text) { while (*text) mm3_demo_putbyte((unsigned char)*text++); }
void mm3_demo_u64(uint64_t value) {
    char digits[20]; unsigned n=0;
    do { digits[n++]=(char)('0'+value%10);value/=10; } while(value);
    while(n) mm3_demo_putbyte((unsigned char)digits[--n]);
}
void platform_write(const unsigned char *bytes,size_t size) {
    if(!capturing) { for(size_t i=0;i<size;i++)mm3_demo_putbyte(bytes[i]);return; }
    if(size>sizeof(captured)-capture_size) {capture_error=1;return;}
    for(size_t i=0;i<size;i++)captured[capture_size++]=bytes[i];
}
void mm3_demo_capture(int token) {capture_token=token;capture_size=0;capture_error=0;capturing=1;}
int mm3_demo_emit(void) {
    static const char hex[]="0123456789abcdef";
    capturing=0;
    if(capture_error)return -1;
    mm3_demo_puts("TOKEN id=");mm3_demo_u64((unsigned)capture_token);
    mm3_demo_puts(" bytes=");mm3_demo_u64(capture_size);mm3_demo_puts(" hex=");
    for(unsigned i=0;i<capture_size;i++) {mm3_demo_putbyte(hex[captured[i]>>4]);mm3_demo_putbyte(hex[captured[i]&15]);}
    mm3_demo_puts("\n");return 0;
}
