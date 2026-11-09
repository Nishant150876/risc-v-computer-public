/* Test programs: everything in the 64 KB RAM, starting at address 0. */
OUTPUT_ARCH(riscv)
ENTRY(_start)

MEMORY
{
    RAM (rwx) : ORIGIN = 0x00000000, LENGTH = 64K
}

SECTIONS
{
    .text : {
        *(.text.init)
        *(.text .text.*)
    } > RAM

    /* Data and zero-initialized data are kept in the image so that the
       .mem file fully describes the RAM contents the test relies on. */
    .data : ALIGN(16) {
        *(.rodata .rodata.*)
        *(.data .data.*)
        *(.sdata .sdata.*)
        *(.sbss .sbss.*)
        *(.bss .bss.*)
        *(COMMON)
    } > RAM
}
