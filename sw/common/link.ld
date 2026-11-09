OUTPUT_ARCH(riscv)
ENTRY(_start)

MEMORY {
    PROGRAM (rwx) : ORIGIN = 0x00000000, LENGTH = 52K
    SCRATCH (rw)  : ORIGIN = 0x0000D000, LENGTH = 4K
    STACK (rw)    : ORIGIN = 0x0000E000, LENGTH = 8K
}

SECTIONS {
    .text ORIGIN(PROGRAM) : {
        KEEP(*(.text.init))
        *(.text .text.*)
    } > PROGRAM
    .rodata : ALIGN(4) {
        *(.rodata .rodata.* .srodata .srodata.*)
    } > PROGRAM
    .data : ALIGN(4) {
        __data_start = .;
        *(.data .data.* .sdata .sdata.*)
        . = ALIGN(4);
        __data_end = .;
    } > PROGRAM
    __image_end = .;
    .bss (NOLOAD) : ALIGN(4) {
        __bss_start = .;
        *(.bss .bss.* .sbss .sbss.*)
        *(COMMON)
        . = ALIGN(4);
        __bss_end = .;
    } > PROGRAM
    __heap_start = ALIGN(__bss_end, 16);
    __heap_end = ORIGIN(SCRATCH);
    __scratch_start = ORIGIN(SCRATCH);
    __scratch_end = ORIGIN(SCRATCH) + LENGTH(SCRATCH);
    __stack_bottom = ORIGIN(STACK);
    __stack_top = ORIGIN(STACK) + LENGTH(STACK);
    __global_pointer$ = __data_start + 0x800;
    /DISCARD/ : { *(.comment .note.* .eh_frame .eh_frame_hdr) }

    ASSERT(_start == 0, "reset entry must be zero")
    ASSERT(__image_end <= ORIGIN(SCRATCH), "initialized image overlaps diagnostic scratch")
    ASSERT(__heap_start <= __heap_end, "program/BSS overlaps diagnostic scratch")
    ASSERT(__scratch_end == __stack_bottom, "scratch/stack boundary differs")
    ASSERT((__stack_top & 15) == 0, "stack must be 16-byte aligned")
}
