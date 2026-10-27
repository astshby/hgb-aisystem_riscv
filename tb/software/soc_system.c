// Module: soc_system_software_test
// Description: CPU-driven peripheral, cache and generic DMA checks on the four-domain SoC.
#include <stdint.h>
#define REG(a) (*(volatile uint32_t *)(uintptr_t)(a))
static volatile uint8_t source[512] __attribute__((aligned(32)));
static volatile uint8_t destination[512] __attribute__((aligned(32)));
static int copy(uint32_t src, uint32_t dst, uint32_t bytes) {
    REG(0x10030000)=src; REG(0x10030004)=dst; REG(0x10030008)=bytes;
    REG(0x1003000c)=3;
    uint32_t status=0;
    for(unsigned i=0;i<50000;i++) {
        status=REG(0x10030010);
        if((status&6)!=0) break;
    }
    if((status&7)!=2 || REG(0x10030014)!=bytes) return 1;
    REG(0x10030010)=6;
    return 0;
}
static int maintain(unsigned command) {
    REG(0x10040020)=command;
    for(unsigned i=0;i<50000;i++) {
        uint32_t status=REG(0x10040030);
        if(!(status&1)) return (status&0x1e)!=0;
    }
    return 1;
}
static int flash_config(unsigned offset, unsigned value) {
    REG(0x10050000+offset)=value;
    for(unsigned i=0;i<10000;i++) if(!(REG(0x10050010)&1)) return 0;
    return 1;
}
int main(void) {
    if(REG(0x10040044)!=3 || REG(0x10040048)!=65536) return 62;
    if(REG(0x10040000)!=__riscv_xlen) return 10;
    REG(0x10020004)=0x12345678;
    if(REG(0x10020004)!=0x12345678) return 11;
    for(unsigned i=0;i<512;i++) {source[i]=(uint8_t)(i*7+3); destination[i]=0;}
    if(copy((uint32_t)(uintptr_t)source,(uint32_t)(uintptr_t)destination,384)) return 20;
    for(unsigned i=0;i<384;i++) if(source[i]!=destination[i]) return 21;
    if(copy((uint32_t)(uintptr_t)source+3,(uint32_t)(uintptr_t)destination+5,157)) return 22;
    for(unsigned i=0;i<157;i++) if(source[i+3]!=destination[i+5]) return 23;
    if(copy((uint32_t)(uintptr_t)source,0x80000fc0,384)) return 24;
    if(copy(0x80000fc0,(uint32_t)(uintptr_t)destination,384)) return 25;
    for(unsigned i=0;i<384;i++) if(source[i]!=destination[i]) return 26;
    if(copy(0x30000100,0x80002000,160)) return 30;
    if(copy(0x80002000,(uint32_t)(uintptr_t)destination,160)) return 31;
    for(unsigned i=0;i<160;i++) {
        unsigned a=i+256;
        if(destination[i]!=(uint8_t)((a*17)^(a>>8)^0xa5)) return 32;
    }
    if(copy(0x30000003,(uint32_t)(uintptr_t)destination+1,19)) return 33;
    for(unsigned i=0;i<19;i++) if(destination[i+1]!=(uint8_t)(((i+3)*17)^0xa5)) return 34;
    volatile uint32_t *ddr=(volatile uint32_t *)(uintptr_t)0x80004000;
    for(unsigned i=0;i<96;i++) ddr[i]=0xace00000+i;
    if(maintain(2)) return 40; // 清脏后 DMA 才可读取 CPU 写入的 DDR 内容。
    if(copy(0x80004000,(uint32_t)(uintptr_t)destination,384)) return 41;
    for(unsigned i=0;i<96;i++) if(((volatile uint32_t *)destination)[i]!=0xace00000+i) return 42;
    if(maintain(3)) return 43;
    if(copy((uint32_t)(uintptr_t)source,0x80004000,384)) return 44;
    if(maintain(1)) return 45;
    for(unsigned i=0;i<384;i++) if(((volatile uint8_t *)ddr)[i]!=source[i]) return 46;
#if __riscv_xlen == 64
    volatile uint64_t *compare=(volatile uint64_t *)(uintptr_t)0x02004000;
    *compare=0x123456789abcdef0ull;
    if(*compare!=0x123456789abcdef0ull) return 50;
#endif
    if(flash_config(0,0x0b) || flash_config(8,8) || flash_config(12,1)) return 53;
    if(copy(0x30000020,(uint32_t)(uintptr_t)destination,9)) return 54;
    for(unsigned i=0;i<9;i++) if(destination[i]!=(uint8_t)(((i+32)*17)^0xa5)) return 55;
    if(flash_config(0,0x13) || flash_config(4,4) || flash_config(8,0)) return 56;
    if(copy(0x30000020,(uint32_t)(uintptr_t)destination,9)) return 57;
    for(unsigned i=0;i<9;i++) if(destination[i]!=(uint8_t)(((i+32)*17)^0xa5)) return 58;
    if(copy(0x30004000,0x80008000,32)) return 51;
    __asm__ volatile(".word 0x0000100f" ::: "memory");
    if(((int (*)(void))(uintptr_t)0x80008000)()!=42) return 52;
    // Flash 只能作为源；非法目的命令在发送任何事务前拒绝。
    REG(0x10030000)=(uint32_t)(uintptr_t)source;
    REG(0x10030004)=0x30000200; REG(0x10030008)=32; REG(0x1003000c)=1;
    for(unsigned i=0;i<50000;i++) if(REG(0x10030010)&4) return REG(0x10030014)==0 ? 0 : 61;
    return 60;
}
