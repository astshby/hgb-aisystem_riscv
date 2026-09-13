OUTPUT_ARCH("riscv")
ENTRY(_start)

SECTIONS
{
    . = 0x0;
    .text : {
        KEEP(*(.text.init))
        *(.text .text.*)
    }

    . = ALIGN(16);
    .host : {
        KEEP(*(.tohost))
        KEEP(*(.sim_console))
    }

    . = ALIGN(16);
    .data : {
        *(.data .data.*)
        *(.rodata .rodata.*)
        *(.srodata .srodata.*)
        *(.sdata .sdata.*)
    }
    PROVIDE(__global_pointer$ = . + 0x800);

    . = ALIGN(16);
    __bss_start = .;
    .bss (NOLOAD) : {
        *(.sbss .sbss.*)
        *(.bss .bss.*)
        *(COMMON)
    }
    __bss_end = .;
    _end = .;

    __stack_limit = 0x0001e000;
    __stack_top = 0x00020000;
    ASSERT(_end < __stack_limit, "benchmark data overlaps the reserved stack")
}
