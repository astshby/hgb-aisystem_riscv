OUTPUT_ARCH("riscv")
ENTRY(_start)
MEMORY
{
    ITCM (rx) : ORIGIN = 0x01000000, LENGTH = 56K
    HOT (rx)  : ORIGIN = 0x0100e000, LENGTH = 8K
    DTCM (rw) : ORIGIN = 0x01100000, LENGTH = 48K
    LOAD (r)  : ORIGIN = 0x0110c000, LENGTH = 8K
    DDR (rwx) : ORIGIN = 0x80000000, LENGTH = 128K
    WORK (rw) : ORIGIN = 0x80020000, LENGTH = 64K
}
SECTIONS
{
    /* 当前为预装外存模型验证；真实 UART loader 将独立占用常驻 I-TCM。 */
    .init : { KEEP(*(.loader.init)) } > ITCM
    .hot : ALIGN(64) {
        __hot_start = .;
        KEEP(*(.hot.entry))
        *context_gcc.o(.text .text.*)
        *(.hot .hot.*)
        . = ALIGN(8); __hot_end = .;
    } > HOT AT> LOAD
    __hot_load = LOADADDR(.hot);
    .observe : ALIGN(8) { KEEP(*(.tohost)) KEEP(*(.sim_console)) } > DTCM
    .text : { KEEP(*(.text.init)) *(.text .text.*) } > DDR
    .data : ALIGN(16) {
        *(.data .data.* .sdata .sdata.*)
        *(.rodata .rodata.* .srodata .srodata.*)
    } > DDR
    PROVIDE(__global_pointer$ = ADDR(.data) + 0x800);
    .ddr_bss (NOLOAD) : ALIGN(64) {
        __ddr_start = .;
        *(.bss.static_memblk)
        . = ALIGN(64); __ddr_end = .;
    } > WORK
    .bss (NOLOAD) : ALIGN(16) {
        __bss_start = .;
        *(.bss .bss.* .sbss .sbss.*) *(COMMON)
        . = ALIGN(16); __bss_end = .;
    } > DDR
    __heap_start = __bss_end;
    __heap_end = ORIGIN(DDR) + LENGTH(DDR);
    __rt_rvstack = 0x01110000;
    ASSERT(__heap_end - __heap_start >= 8192, "RT-Thread DDR heap too small")
    ASSERT(SIZEOF(.hot) > 0 && SIZEOF(.hot) <= 8192, "hot image overflow")
    ASSERT(SIZEOF(.ddr_bss) >= 2000, "CoreMark workspace missing")
    /DISCARD/ : { *(.eh_frame*) *(.comment) *(.note*) }
}
