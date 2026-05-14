/* spike/mac.ld — Phase 0 linker script for ELF pipeline validation
 *
 * Produces an elf32-m68k binary suitable for symbol and instruction
 * validation. NOT a bootable Mac image — that is Phase 1+ territory.
 *
 * Provides linker-defined section boundary symbols expected by the
 * Retro68 runtime (libretrocrt.a) when it is linked in future phases.
 */
OUTPUT_FORMAT(elf32-m68k)
OUTPUT_ARCH(m68k:68020)
ENTRY(_start)

SECTIONS
{
    . = 0x0;

    .text :
    {
        *(.text .text.*)
        *(.rodata .rodata.*)
    }
    _etext = .;
    PROVIDE(__etext = .);

    .init :
    {
        PROVIDE(__init_section = .);
        KEEP(*(.init))
        PROVIDE(__init_section_end = .);
    }

    .fini :
    {
        PROVIDE(__fini_section = .);
        KEEP(*(.fini))
        PROVIDE(__fini_section_end = .);
    }

    .ctors :
    {
        PROVIDE(__CTOR_LIST__ = .);
        KEEP(*(SORT(.ctors.*)))
        KEEP(*(.ctors))
        LONG(0)
        PROVIDE(__CTOR_END__ = .);
    }

    .dtors :
    {
        PROVIDE(__DTOR_LIST__ = .);
        KEEP(*(SORT(.dtors.*)))
        KEEP(*(.dtors))
        LONG(0)
        PROVIDE(__DTOR_END__ = .);
    }

    .eh_frame :
    {
        PROVIDE(__EH_FRAME_BEGIN__ = .);
        KEEP(*(.eh_frame))
    }

    .data :
    {
        *(.data .data.*)
    }
    _edata = .;
    PROVIDE(edata = .);

    .bss :
    {
        _sbss = .;
        *(.bss .bss.*)
        *(COMMON)
        _ebss = .;
    }
}
