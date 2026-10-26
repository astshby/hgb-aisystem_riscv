OUTPUT_ARCH("riscv")
ENTRY(_start)
MEMORY {
    ITCM (rx) : ORIGIN = 0x01000000, LENGTH = 64K
    DTCM (rw) : ORIGIN = 0x01100000, LENGTH = 64K
    DATA (rw) : ORIGIN = 0x80000000, LENGTH = 4M
}
SECTIONS {
    .text : {KEEP(*(.text.init)) *(.text .text.*)} > ITCM
    .host : ALIGN(64) {KEEP(*(.tohost)) KEEP(*(.sim_console))} > DTCM
    .data : ALIGN(64) {*(.data .data.*) *(.rodata .rodata.*) *(.sdata .sdata.*) *(.srodata .srodata.*)} > DATA
    PROVIDE(__global_pointer$ = . + 0x800);
    .bss (NOLOAD) : ALIGN(64) {__bss_start = .; *(.bss .bss.*) *(.sbss .sbss.*) *(COMMON) __bss_end = .;} > DATA
    __stack_top = ORIGIN(DTCM)+LENGTH(DTCM);
    __stack_limit = __stack_top-32768;
    mm3_model_start = 0x81000000;
    mm3_tokenizer_start = 0x85000000;
    ASSERT(SIZEOF(.host)<32768,"host symbols overlap stack")
}
