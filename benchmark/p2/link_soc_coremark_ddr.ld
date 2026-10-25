OUTPUT_ARCH("riscv")
ENTRY(_start)
MEMORY {
    ITCM (rx) : ORIGIN = 0x01000000, LENGTH = 64K
    DTCM (rw) : ORIGIN = 0x01100000, LENGTH = 64K
    DDR (rwx) : ORIGIN = 0x80000000, LENGTH = 128K
}
SECTIONS {
    /* 控制胶水在 TCM，CoreMark 的程序、常量、工作区和栈均在 DDR。 */
    .text.init : { KEEP(*(.text.init)) *(.text.p2_control) } > ITCM
    .host : ALIGN(16) { KEEP(*(.tohost)) KEEP(*(.sim_console)) } > DTCM
    ASSERT(SIZEOF(.host) <= 0x100, "P2 host overlaps ROI marker")
    .p2_roi 0x01100100 : { KEEP(*(.p2_roi)) } > DTCM
    ASSERT(SIZEOF(.p2_roi) == 4, "P2 ROI marker must be one 32-bit word")
    .p2_platform 0x01100110 : { KEEP(*(.p2_platform)) } > DTCM
    ASSERT(SIZEOF(.p2_platform) == 16, "P2 platform config must be four 32-bit words")
    .p2_control : ALIGN(16) { *(.p2_control) } > DTCM
    __control_stack_top = ORIGIN(DTCM) + LENGTH(DTCM);
    __interrupt_stack_top = __control_stack_top - 4096;
    ASSERT(. < __control_stack_top - 8192, "P2 control data overlaps control stack")
    .text : ALIGN(32) { __ddr_text_start = .; *(.text .text.*) __ddr_text_end = .; } > DDR
    .rodata : ALIGN(32) { __ddr_rodata_start = .; *(.rodata .rodata.*) *(.srodata .srodata.*) __ddr_rodata_end = .; } > DDR
    .data : ALIGN(32) { __ddr_data_start = .; *(.data .data.*) *(.sdata .sdata.*) __ddr_data_end = .; } > DDR
    PROVIDE(__global_pointer$ = . + 0x800);
    .bss (NOLOAD) : ALIGN(32) {
        __bss_start = .;
        *(.sbss .sbss.*) *(.bss .bss.*) *(COMMON)
        __bss_end = .;
    } > DDR
    _end = .;
    __stack_top = ORIGIN(DDR) + LENGTH(DDR);
    __stack_limit = __stack_top - 16384;
    ASSERT(_end < __stack_limit, "P2 CoreMark data overlaps DDR stack")
    /* DMA 源 0x80020000、目的 0x80030000，每个 16 KiB，独立于 CPU 工作区。 */
}
