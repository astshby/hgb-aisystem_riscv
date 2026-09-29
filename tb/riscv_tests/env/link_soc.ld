OUTPUT_ARCH("riscv")
ENTRY(_start)
MEMORY { ITCM (rwx) : ORIGIN = 0x01000000, LENGTH = 64K }
SECTIONS {
    .text : {
        KEEP(*(.text.init))
        *(.text .text.*)
    } > ITCM
    .tohost : ALIGN(0x1000) { KEEP(*(.tohost)) } > ITCM
    /* fence_i 会执行 .data 中的代码；专用 ISA 镜像整体置于可执行 I-TCM。 */
    .data : {
        *(.data .data.*)
        *(.rodata .rodata.*)
        *(.sdata .sdata.*)
        *(.sbss .sbss.*)
        *(.bss .bss.*)
        *(COMMON)
    } > ITCM
    _end = .;
}
