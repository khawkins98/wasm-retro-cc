_MULTISEG_APP = 1;
/* ld script for Elf2Mac */
ENTRY( _start )
SECTIONS
{
	.code00001 : {
		FILL(0x4E71);

        _stext = .;
        FILL(0x4E71);
        PROVIDE(_rsrc_start = .);
        . = ALIGN (2);
        _entry_trampoline = .;
        SHORT(DEFINED(__break_on_entry) ? 0xA9FF : 0x4e71);
        LONG(0x61000002);    /* bsr *+2 */
        SHORT(0x0697); /* addi.l #_, (a7) */
        LONG(_start - _entry_trampoline - 6);
        /* cv-mac patch: PROVIDE(_start = .) removed -- pre-empts libretrocrt _start */
        SHORT(0x4e75); /* rts */

        FILL(0);
        *(.relocvars)
        FILL(0x4E71);
        */libretrocrt.a:start.c.obj(.text)
        */libretrocrt.a:start.c.obj(.text.*)
        */libretrocrt.a:relocate.c.obj(.text)
        */libretrocrt.a:relocate.c.obj(.text.*)
        */libretrocrt.a:MultiSegApp.c.obj(.text)
        */libretrocrt.a:MultiSegApp.c.obj(.text.*)
        */libretrocrt.a:LoadSeg.s.obj(.text)
        */libretrocrt.a:LoadSeg.s.obj(.text.*)
        *(.text._start)
        *(.text._start.*)
        */libretrocrt.a:*(.text)
        */libretrocrt.a:*(.text.*)
        */libInterface.a:*(.text)
        */libInterface.a:*(.text.*)
        */libgcc.a:*(.text)
        */libgcc.a:*(.text.*)
        */libc.a:*(.text)
        */libc.a:*(.text.*)

        . = ALIGN (4) ;
        __init_section = .;
        KEEP (*(.init))
        __init_section_end = .;
        __fini_section = .;
        KEEP (*(.fini))
        __fini_section_end = .;
		. = ALIGN (4);
		__EH_FRAME_BEGIN__ = .;
		KEEP(*/libretrocrt.a:start.c.obj(.eh_frame))
		KEEP(*/libretrocrt.a:start.c.obj(.eh_frame.*))
		KEEP(*/libretrocrt.a:relocate.c.obj(.eh_frame))
		KEEP(*/libretrocrt.a:relocate.c.obj(.eh_frame.*))
		KEEP(*/libretrocrt.a:MultiSegApp.c.obj(.eh_frame))
		KEEP(*/libretrocrt.a:MultiSegApp.c.obj(.eh_frame.*))
		KEEP(*/libretrocrt.a:LoadSeg.s.obj(.eh_frame))
		KEEP(*/libretrocrt.a:LoadSeg.s.obj(.eh_frame.*))
		KEEP(*/libretrocrt.a:*(.eh_frame))
		KEEP(*/libretrocrt.a:*(.eh_frame.*))
		KEEP(*/libInterface.a:*(.eh_frame))
		KEEP(*/libInterface.a:*(.eh_frame.*))
		KEEP(*/libgcc.a:*(.eh_frame))
		KEEP(*/libgcc.a:*(.eh_frame.*))
		KEEP(*/libc.a:*(.eh_frame))
		KEEP(*/libc.a:*(.eh_frame.*))
		LONG(0);
		KEEP(*/libretrocrt.a:start.c.obj(.gcc_except_table))
		KEEP(*/libretrocrt.a:start.c.obj(.gcc_except_table.*))
		KEEP(*/libretrocrt.a:relocate.c.obj(.gcc_except_table))
		KEEP(*/libretrocrt.a:relocate.c.obj(.gcc_except_table.*))
		KEEP(*/libretrocrt.a:MultiSegApp.c.obj(.gcc_except_table))
		KEEP(*/libretrocrt.a:MultiSegApp.c.obj(.gcc_except_table.*))
		KEEP(*/libretrocrt.a:LoadSeg.s.obj(.gcc_except_table))
		KEEP(*/libretrocrt.a:LoadSeg.s.obj(.gcc_except_table.*))
		KEEP(*/libretrocrt.a:*(.gcc_except_table))
		KEEP(*/libretrocrt.a:*(.gcc_except_table.*))
		KEEP(*/libInterface.a:*(.gcc_except_table))
		KEEP(*/libInterface.a:*(.gcc_except_table.*))
		KEEP(*/libgcc.a:*(.gcc_except_table))
		KEEP(*/libgcc.a:*(.gcc_except_table.*))
		KEEP(*/libc.a:*(.gcc_except_table))
		KEEP(*/libc.a:*(.gcc_except_table.*))

        . = ALIGN(0x4) ;
        _etext = . ;
	}
	.code00005 : {
		FILL(0x4E71);
        */libstdc++.a:locale.o(.text)
        */libstdc++.a:locale.o(.text.*)
        */libstdc++.a:locale_faces.o(.text)
        */libstdc++.a:locale_faces.o(.text.*)
        */libstdc++.a:locale_init.o(.text)
        */libstdc++.a:locale_init.o(.text.*)
		. = ALIGN (4);
		__EH_FRAME_BEGIN__00005 = .;
		KEEP(*/libstdc++.a:locale.o(.eh_frame))
		KEEP(*/libstdc++.a:locale.o(.eh_frame.*))
		KEEP(*/libstdc++.a:locale_faces.o(.eh_frame))
		KEEP(*/libstdc++.a:locale_faces.o(.eh_frame.*))
		KEEP(*/libstdc++.a:locale_init.o(.eh_frame))
		KEEP(*/libstdc++.a:locale_init.o(.eh_frame.*))
		LONG(0);
		KEEP(*/libstdc++.a:locale.o(.gcc_except_table))
		KEEP(*/libstdc++.a:locale.o(.gcc_except_table.*))
		KEEP(*/libstdc++.a:locale_faces.o(.gcc_except_table))
		KEEP(*/libstdc++.a:locale_faces.o(.gcc_except_table.*))
		KEEP(*/libstdc++.a:locale_init.o(.gcc_except_table))
		KEEP(*/libstdc++.a:locale_init.o(.gcc_except_table.*))

        . = ALIGN(0x4);
        FILL(0);
        . += 32;
        LONG(__EH_FRAME_BEGIN__00005 - .);
	}
	.code00007 : {
		FILL(0x4E71);
        */libstdc++.a:locale-inst.o(.text)
        */libstdc++.a:locale-inst.o(.text.*)
		. = ALIGN (4);
		__EH_FRAME_BEGIN__00007 = .;
		KEEP(*/libstdc++.a:locale-inst.o(.eh_frame))
		KEEP(*/libstdc++.a:locale-inst.o(.eh_frame.*))
		LONG(0);
		KEEP(*/libstdc++.a:locale-inst.o(.gcc_except_table))
		KEEP(*/libstdc++.a:locale-inst.o(.gcc_except_table.*))

        . = ALIGN(0x4);
        FILL(0);
        . += 32;
        LONG(__EH_FRAME_BEGIN__00007 - .);
	}
	.code00008 : {
		FILL(0x4E71);
        */libstdc++.a:wlocale-inst.o(.text)
        */libstdc++.a:wlocale-inst.o(.text.*)
		. = ALIGN (4);
		__EH_FRAME_BEGIN__00008 = .;
		KEEP(*/libstdc++.a:wlocale-inst.o(.eh_frame))
		KEEP(*/libstdc++.a:wlocale-inst.o(.eh_frame.*))
		LONG(0);
		KEEP(*/libstdc++.a:wlocale-inst.o(.gcc_except_table))
		KEEP(*/libstdc++.a:wlocale-inst.o(.gcc_except_table.*))

        . = ALIGN(0x4);
        FILL(0);
        . += 32;
        LONG(__EH_FRAME_BEGIN__00008 - .);
	}
	.code00006 : {
		FILL(0x4E71);
        */libstdc++.a:cp-demangle.o(.text)
        */libstdc++.a:cp-demangle.o(.text.*)
		. = ALIGN (4);
		__EH_FRAME_BEGIN__00006 = .;
		KEEP(*/libstdc++.a:cp-demangle.o(.eh_frame))
		KEEP(*/libstdc++.a:cp-demangle.o(.eh_frame.*))
		LONG(0);
		KEEP(*/libstdc++.a:cp-demangle.o(.gcc_except_table))
		KEEP(*/libstdc++.a:cp-demangle.o(.gcc_except_table.*))

        . = ALIGN(0x4);
        FILL(0);
        . += 32;
        LONG(__EH_FRAME_BEGIN__00006 - .);
	}
	.code00003 : {
		FILL(0x4E71);
        */libstdc++.a:*(.text)
        */libstdc++.a:*(.text.*)
		. = ALIGN (4);
		__EH_FRAME_BEGIN__00003 = .;
		KEEP(*/libstdc++.a:*(.eh_frame))
		KEEP(*/libstdc++.a:*(.eh_frame.*))
		LONG(0);
		KEEP(*/libstdc++.a:*(.gcc_except_table))
		KEEP(*/libstdc++.a:*(.gcc_except_table.*))

        . = ALIGN(0x4);
        FILL(0);
        . += 32;
        LONG(__EH_FRAME_BEGIN__00003 - .);
	}
	.code00004 : {
		FILL(0x4E71);
        */libRetroConsole.a:*(.text)
        */libRetroConsole.a:*(.text.*)
		. = ALIGN (4);
		__EH_FRAME_BEGIN__00004 = .;
		KEEP(*/libRetroConsole.a:*(.eh_frame))
		KEEP(*/libRetroConsole.a:*(.eh_frame.*))
		LONG(0);
		KEEP(*/libRetroConsole.a:*(.gcc_except_table))
		KEEP(*/libRetroConsole.a:*(.gcc_except_table.*))

        . = ALIGN(0x4);
        FILL(0);
        . += 32;
        LONG(__EH_FRAME_BEGIN__00004 - .);
	}
	.code00002 : {
		FILL(0x4E71);
        *(.text)
        *(.text.*)
		*(.gnu.linkonce.t*)
		. = ALIGN (4);
		__EH_FRAME_BEGIN__00002 = .;
		KEEP(*(.eh_frame))
		KEEP(*(.eh_frame.*))
		LONG(0);
		KEEP(*(.gcc_except_table))
		KEEP(*(.gcc_except_table.*))

        . = ALIGN(0x4);
        FILL(0);
        . += 32;
        LONG(__EH_FRAME_BEGIN__00002 - .);
	}

    .data : {
        _sdata = . ;
        *(.got.plt)
        *(.got)
        FILL(0) ;
        . = ALIGN(0x20) ;
        LONG(-1)
        . = ALIGN(0x20) ;
        *(.rodata)
        *(.rodata1)
        *(.rodata.*)
        *(.gnu.linkonce.r*)
        *(.data)
        *(.data1)
        *(.data.*)
        *(.gnu.linkonce.d*)

        . = ALIGN(4) ;
        __CTOR_LIST__ = .;
        KEEP (*(.ctors))
        KEEP (*(SORT(.ctors.*)))
        __CTOR_END__ = .;
        LONG(0);

        . = ALIGN(0x4);
        __DTOR_LIST__ = .;
        KEEP (*(.dtors))
        KEEP (*(SORT(.dtors.*)))
        __DTOR_END__ = .;
        LONG(0);

        . = ALIGN(0x4);
        _edata = . ;
    }
    .bss ALIGN(0x4) : {
        _sbss = .;
        *(.dynsbss)
        *(.sbss)
        *(.sbss.*)
        *(.scommon)
        *(.dynbss)
        *(.bss)
        *(.bss.*)
        *(.bss*)
        *(.gnu.linkonce.b*)
        *(COMMON)
        . = ALIGN(0x10) ;
        _ebss = . ;
    }


    /* **** Debugging information sections.
     * Keep them for now, they are discarded by Elf2Mac. */

    /DISCARD/ : { *(.note.GNU-stack) }
    /* Stabs debugging sections.    */
    .stab 0 : { *(.stab) }
    .stabstr 0 : { *(.stabstr) }
    .stab.excl 0 : { *(.stab.excl) }
    .stab.exclstr 0 : { *(.stab.exclstr) }
    .stab.index 0 : { *(.stab.index) }
    .stab.indexstr 0 : { *(.stab.indexstr) }
    .comment 0 : { *(.comment) }
    /* DWARF debug sections.
      Symbols in the DWARF debugging sections are relative to the beginning
      of the section so we begin them at 0.  */
    /* DWARF 1 */
    .debug 0 : { *(.debug) }
    .line 0 : { *(.line) }
    /* GNU DWARF 1 extensions */
    .debug_srcinfo 0 : { *(.debug_srcinfo) }
    .debug_sfnames 0 : { *(.debug_sfnames) }
    /* DWARF 1.1 and DWARF 2 */
    .debug_aranges 0 : { *(.debug_aranges) }
    .debug_pubnames 0 : { *(.debug_pubnames) }
    /* DWARF 2 */
    .debug_info 0 : { *(.debug_info .gnu.linkonce.wi.*) }
    .debug_abbrev 0 : { *(.debug_abbrev) }
    .debug_line 0 : { *(.debug_line) }
    .debug_frame 0 : { *(.debug_frame) }
    .debug_str 0 : { *(.debug_str) }
    .debug_loc 0 : { *(.debug_loc) }
    .debug_macinfo 0 : { *(.debug_macinfo) }
    /* SGI/MIPS DWARF 2 extensions */
    .debug_weaknames 0 : { *(.debug_weaknames) }
    .debug_funcnames 0 : { *(.debug_funcnames) }
    .debug_typenames 0 : { *(.debug_typenames) }
    .debug_varnames 0 : { *(.debug_varnames) }

    /DISCARD/ : { *(*) }
}

