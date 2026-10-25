OUTPUT_ARCH("riscv")
ENTRY(_start)
MEMORY {
    ITCM (rx) : ORIGIN = 0x01000000, LENGTH = 32K
    DTCM (rw) : ORIGIN = 0x01100000, LENGTH = 32K
}
SECTIONS {
    /* 两块 RAM 的高 32 KiB 留给 DMA；程序和控制栈均不与搬运区重叠。 */
    .text : { KEEP(*(.text.init)) *(.text.p2_control) *(.text .text.*) } > ITCM
    .host : ALIGN(16) { KEEP(*(.tohost)) KEEP(*(.sim_console)) } > DTCM
    ASSERT(SIZEOF(.host) <= 0x100, "host overlaps ROI")
    .p2_roi 0x01100100 : { KEEP(*(.p2_roi)) } > DTCM
    .p2_platform 0x01100110 : { KEEP(*(.p2_platform)) } > DTCM
    .p2_control : ALIGN(16) { *(.p2_control) } > DTCM
    .data : ALIGN(16) { *(.data .data.*) *(.rodata .rodata.*) *(.srodata .srodata.*) *(.sdata .sdata.*) } > DTCM
    PROVIDE(__global_pointer$ = . + 0x800);
    .bss (NOLOAD) : ALIGN(16) {
        __bss_start = .;
        *(.sbss .sbss.*) *(.bss .bss.*) *(COMMON)
        __bss_end = .;
    } > DTCM
    __control_stack_top = 0x01108000;
    __interrupt_stack_top = 0x01107000;
    __stack_top = 0x01106000;
    __stack_limit = 0x01104000;
    ASSERT(. < __stack_limit, "TCM data overlaps stacks")
}
