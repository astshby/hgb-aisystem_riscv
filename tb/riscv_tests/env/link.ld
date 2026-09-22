OUTPUT_ARCH("riscv")
ENTRY(_start)

SECTIONS
{
    . = 0x0;
    .text : {
        KEEP(*(.text.init))
        *(.text .text.*)
    }

    . = ALIGN(0x1000);
    .tohost : {
        KEEP(*(.tohost))
    }

    .data : {
        *(.data .data.*)
        *(.rodata .rodata.*)
        *(.sdata .sdata.*)
        *(.sbss .sbss.*)
        *(.bss .bss.*)
        *(COMMON)
    }
    _end = .;
}
