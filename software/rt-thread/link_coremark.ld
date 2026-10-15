OUTPUT_ARCH("riscv")
ENTRY(_start)
MEMORY
{
    ITCM (rx) : ORIGIN = 0x01000000, LENGTH = 56K
    HOT (rx)  : ORIGIN = 0x0100e000, LENGTH = 8K
    DTCM (rw) : ORIGIN = 0x01100000, LENGTH = 48K
    LOAD (r)  : ORIGIN = 0x0110c000, LENGTH = 8K
    DDR (rw)  : ORIGIN = 0x80000000, LENGTH = 64K
}
SECTIONS
{
    .hot : ALIGN(64) {
        __hot_start = .;
        KEEP(*(.hot.entry))
        *context_gcc.o(.text .text.*)
        *(.hot .hot.*)
        . = ALIGN(8);
        __hot_end = .;
    } > HOT AT> LOAD
    __hot_load = LOADADDR(.hot);
    .text : { KEEP(*(.text.init)) *(.text .text.*) } > ITCM
    .data : ALIGN(16) {
        KEEP(*(.tohost)) KEEP(*(.sim_console))
        *(.data .data.* .sdata .sdata.*)
        *(.rodata .rodata.* .srodata .srodata.*)
    } > DTCM
    PROVIDE(__global_pointer$ = ADDR(.data) + 0x800);
    .ddr_bss (NOLOAD) : ALIGN(64) {
        __ddr_start = .;
        *(.bss.static_memblk)
        . = ALIGN(64); __ddr_end = .;
    } > DDR
    .bss (NOLOAD) : ALIGN(16) {
        __bss_start = .;
        *(.bss .bss.* .sbss .sbss.*) *(COMMON)
        . = ALIGN(16); __bss_end = .;
    } > DTCM
    __heap_start = __bss_end;
    __heap_end = ORIGIN(DTCM) + LENGTH(DTCM);
    /* 最后 8 KiB 专用启动/中断栈，和 DMA 装载镜像分离。 */
    __rt_rvstack = 0x01110000;
    ASSERT(__heap_end - __heap_start >= 8192, "RT-Thread heap too small")
    ASSERT(SIZEOF(.hot) > 0 && SIZEOF(.hot) <= 8192, "hot image overflow")
    ASSERT(SIZEOF(.ddr_bss) >= 2000, "CoreMark workspace not linked into DDR")
    /DISCARD/ : { *(.eh_frame*) *(.comment) *(.note*) }
}
