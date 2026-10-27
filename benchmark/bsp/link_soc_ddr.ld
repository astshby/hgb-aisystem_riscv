OUTPUT_ARCH("riscv")
ENTRY(_start)
MEMORY {
    ITCM (rwx) : ORIGIN = 0x01000000, LENGTH = 64K
    DTCM (rw)  : ORIGIN = 0x01100000, LENGTH = 64K
    DDR  (rwx) : ORIGIN = 0x80000000, LENGTH = 512M
}
SECTIONS {
    /* 复位入口留在 ITCM；main 与代码主体放 DDR，数据/栈仍在 DTCM。 */
    .text.init : {
        KEEP(*(.text.init))
    } > ITCM
    .text : {
        *(.text .text.*)
    } > DDR
    .host : ALIGN(16) {
        KEEP(*(.tohost))
        KEEP(*(.sim_console))
    } > DTCM
    .data : ALIGN(16) {
        *(.data .data.*)
        *(.rodata .rodata.*)
        *(.srodata .srodata.*)
        *(.sdata .sdata.*)
    } > DTCM
    PROVIDE(__global_pointer$ = . + 0x800);
    .bss (NOLOAD) : ALIGN(16) {
        __bss_start = .;
        *(.sbss .sbss.*)
        *(.bss .bss.*)
        *(COMMON)
        __bss_end = .;
    } > DTCM
    _end = .;
    __stack_top = ORIGIN(DTCM) + LENGTH(DTCM);
    __stack_limit = __stack_top - 8192;
    ASSERT(_end < __stack_limit, "SoC DDR image data overlaps reserved stack")
    ASSERT(SIZEOF(.text) < 64K, "DDR image text exceeds verification model")
}
