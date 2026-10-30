/* Module: mm3_demo_board
 * Description: Real UART, mapped DDR asset validation and request-scoped DDR arena.
 */
#include "demo.h"
#include "soc_clocks.h"
#include "benchmark_runtime.h"
#include <string.h>
/* 原平台的整数格式化与内存函数保留；新入口替换其一次性堆和无实现的文件读取。 */
#define platform_alloc mm3_unused_original_alloc
#define platform_free mm3_unused_original_free
#define platform_read mm3_unused_original_read
#define platform_write mm3_original_console_write
#define platform_nanoseconds mm3_unused_original_nanoseconds
#include "../baremetal/platform.c"
#undef platform_alloc
#undef platform_free
#undef platform_read
#undef platform_write
#undef platform_nanoseconds
#define REG32(address) (*(volatile uint32_t *)(uintptr_t)(address))
static uintptr_t request_mark;
static struct hgb_soc_clocks clocks;
static int uart_ready;
void benchmark_putchar(char value) {
    if(!uart_ready)return;
    while(!(REG32(0x10000008u)&1u)){}
    REG32(0x10000000u)=(unsigned char)value;
}
void mm3_demo_putbyte(unsigned char value){benchmark_putchar((char)value);}
int mm3_demo_getbyte(void) {
    for(;;){uint32_t status=REG32(0x10000008u);
        if(status&12u){if(status&2u)(void)REG32(0x10000004u);REG32(0x10000008u)=12u;return -2;}
        if(status&2u)return (unsigned char)REG32(0x10000004u);
    }
}
void *platform_alloc(size_t size) {
    if(!size||size>0x01800000u)return NULL;
    uintptr_t address=(heap+63u)&~(uintptr_t)63u;
    if(address>0x87e00000u||size>0x87e00000u-address)return NULL;
    heap=address+size;return (void *)address;
}
void platform_free(void *address){(void)address;}
void mm3_demo_request_begin(void){request_mark=heap;}
void mm3_demo_request_end(void){if(request_mark>=0x86000000u&&request_mark<=heap)heap=request_mark;}
uint64_t mm3_demo_live_bytes(void){return heap-0x86000000u;}
uint64_t platform_nanoseconds(void){uint64_t cycles=benchmark_read_cycle();return cycles/clocks.core_hz*1000000000u+(cycles%clocks.core_hz)*1000000000u/clocks.core_hz;}
int platform_read(const char *path,Blob *blob) {
    const unsigned char *header=(const unsigned char *)(uintptr_t)0x80400000u;
    uint32_t magic=read_u32(header),version=read_u32(header+4),model=read_u32(header+8);
    uint32_t model_bytes=read_u32(header+12),tokenizer=read_u32(header+16),tokenizer_bytes=read_u32(header+20);
    if(magic!=0x3141334du||version!=1||crc32_bytes(header,24)!=read_u32(header+24)||
       model!=0x81000000u||tokenizer!=0x85000000u||!model_bytes||model_bytes>0x04000000u||
       !tokenizer_bytes||tokenizer_bytes>0x01000000u)return -1;
    if(!strcmp(path,"assets/model_w8a16_int.bin")){blob->data=(const unsigned char *)(uintptr_t)model;blob->size=model_bytes;}
    else if(!strcmp(path,"assets/tokenizer.bin")){blob->data=(const unsigned char *)(uintptr_t)tokenizer;blob->size=tokenizer_bytes;}
    else return -1;
    blob->owned=NULL;return 0;
}
extern int mm3_accel_init(int);
extern int mm3_accel_linear(IRuntime *,int,int16_t *,IScale *,const int16_t *,IScale,int);
int mm3_demo_backend(IRuntime *runtime,int accelerated) {
    if(!accelerated)return 0;
    if(mm3_accel_init(1))return -1;
    runtime->linear_backend=mm3_accel_linear;return 0;
}
int main(void) {
    uint32_t discovery=REG32(0x10040000u+HGB_SOC_DISCOVERY_OFFSET);
    if(hgb_soc_read_clocks(0x10040000u,discovery,&clocks))return 1;
    uint32_t divisor=hgb_soc_uart_divisor(clocks.periph_hz,115200u);if(!divisor)return 1;
    REG32(0x10000010u)=0;REG32(0x1000000cu)=divisor;REG32(0x10000008u)=12u;uart_ready=1;
    uint32_t presence=REG32(0x10040000u+HGB_SOC_PRESENCE_OFFSET);
    if(!hgb_soc_discovery_valid(presence,discovery)||!hgb_soc_has(presence,HGB_TARGET_MM3)||!hgb_soc_has(presence,HGB_TARGET_DDR)){
        mm3_demo_puts("BOOT_ERROR reason=hardware\n");return 2;
    }
    return mm3_demo_session("assets/model_w8a16_int.bin","assets/tokenizer.bin",16,0,1);
}
