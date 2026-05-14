/* spike/crt0_minimal.s — minimal Phase 0 startup
 *
 * Provides _start → main → ExitToShell for Phase 0 ELF link validation.
 * Phase 1 will use the full Retro68 libretrocrt.a startup instead.
 *
 * A-trap 0xA9F4 = ExitToShell (returns to Mac OS / Finder).
 */
	.text
	.globl _start
_start:
	jsr	main
	.word	0xA9F4		/* ExitToShell */
