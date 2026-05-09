/* spike/mac.ld — minimal linker script for Phase 0 ELF validation
 *
 * Produces a flat elf32-m68k binary suitable for symbol and instruction
 * validation. NOT a bootable Mac image — that is Phase 1+ territory.
 */
OUTPUT_FORMAT(elf32-m68k)
OUTPUT_ARCH(m68k:68000)
ENTRY(_start)

SECTIONS
{
    . = 0x0;

    .text :
    {
        *(.text .text.*)
        *(.rodata .rodata.*)
    }

    .data :
    {
        *(.data .data.*)
    }

    .bss :
    {
        *(.bss .bss.*)
        *(COMMON)
    }
}
