OUTPUT_ARCH("riscv")
ENTRY(_start)
MEMORY {
    ITCM (rx) : ORIGIN = 0x01000000, LENGTH = 56K
    DTCM (rw) : ORIGIN = 0x01101000, LENGTH = 40K
}
SECTIONS {
    .text : { KEEP(*(.text.init)) *(.text .text.*) } > ITCM
    .data : ALIGN(16) { *(.data .data.* .sdata .sdata.*) *(.rodata .rodata.*) } > DTCM
    PROVIDE(__global_pointer$ = ADDR(.data)+0x800);
    .bss (NOLOAD) : ALIGN(16) {
        __bss_start = .; *(.bss .bss.* .sbss .sbss.*) *(COMMON) __bss_end = .;
    } > DTCM
    __stack_top = 0x0110b000;
    ASSERT(__bss_end+4096<=__stack_top, "loader stack overlaps data")
    /DISCARD/ : { *(.eh_frame*) *(.comment) *(.note*) }
}
