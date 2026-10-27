/* SPDX-License-Identifier: Apache-2.0 */
#include "protocol.h"
#define REG(a) (*(volatile uint32_t *)(__UINTPTR_TYPE__)(a))
#define UART 0x10000000u
#define INFO 0x10040000u
#ifndef LOADER_BAUD
#define LOADER_BAUD 115200u
#endif
#ifndef LOADER_QUIET_MS
#define LOADER_QUIET_MS 100u
#endif
/* 四域 SoC 的 UART/mtime 使用外设时钟，旧单时钟入口保留 ABI 回退。 */
static uint32_t peripheral_hz(void)
{ return (REG(INFO+0x3c)&0x100u) ? REG(INFO+0x60) : REG(INFO+4); }
static uint64_t time_now(void)
{
    uint32_t high, low, check;
    do { high=REG(0x0200bffc); low=REG(0x0200bff8); check=REG(0x0200bffc); }
    while (high!=check);
    return ((uint64_t)high<<32)|low;
}
int loader_get(uint8_t *value)
{
    uint64_t start=time_now();
    for (;;) {
        uint32_t status=REG(UART+8);
        if (status&12u) return HGB_UART;
        if (status&2u) { *value=REG(UART+4); return HGB_OK; }
        if (time_now()-start>(uint64_t)peripheral_hz()*2u) return HGB_TIMEOUT;
    }
}
void loader_put(uint8_t value)
{
    while (!(REG(UART+8)&1u)) { }
    REG(UART)=value;
}
void loader_store(uint32_t address, uint8_t value)
{ *(volatile uint8_t *)(__UINTPTR_TYPE__)address=value; }
uint8_t loader_load(uint32_t address)
{ return *(volatile uint8_t *)(__UINTPTR_TYPE__)address; }
int loader_flush(void)
{
    REG(INFO+0x20)=3;
    while (REG(INFO+0x30)&1u) { }
    return (REG(INFO+0x30)&6u)!=0;
}
static void text(const char *s) { while (*s) loader_put(*s++); }
void loader_fault(void)
{
    /* 异常日志常驻 TCM，不调用尚未装载的 RT-Thread 热函数。 */
    text("LOADER TRAP; reset required\n");
    for (;;) { }
}
static int ddr_check(void)
{
    for (unsigned i=0; i<64; i++) loader_store(0x8003f000u+i,(uint8_t)(i^0xa5));
    if (loader_flush()) return 1;
    for (unsigned i=0; i<64; i++)
        if (loader_load(0x8003f000u+i)!=(uint8_t)(i^0xa5)) return 1;
    return 0;
}
void loader_main(void)
{
    REG(UART+16)=0;
    REG(UART+12)=peripheral_hz()/LOADER_BAUD;
    REG(UART+8)=12;
    if (ddr_check()) { text("LOADER DDR FAIL; reset required\n"); for (;;) { } }
    for (;;) {
        uint32_t entry;
        /* 失败后丢弃残留字节，等待 100 ms 静默再进入下一次事务。 */
        uint64_t quiet=time_now();
        while (time_now()-quiet<(peripheral_hz()/1000u)*LOADER_QUIET_MS) {
            if (REG(UART+8)&2u) { (void)REG(UART+4); quiet=time_now(); }
        }
        REG(UART+8)=12;
        text("LOADER READY v1 m0d1\n");
        int error=hgb_receive(HGB_CONFIG(__riscv_xlen),&entry);
        if (error) { loader_put(0x15); loader_put((uint8_t)error); continue; }
        loader_put(0x07);
        while (!(REG(UART+8)&1u)) { }
        __asm__ volatile("fence.i\n\tjr %0" :: "r"((__UINTPTR_TYPE__)entry) : "memory");
        __builtin_unreachable();
    }
}
