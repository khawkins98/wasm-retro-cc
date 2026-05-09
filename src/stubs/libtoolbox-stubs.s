/* src/stubs/libtoolbox-stubs.s -- Mac Toolbox A-trap bridge stubs
 *
 * Purpose: Bridge C cdecl calls (from PCC-compiled code) to Mac ROM traps.
 *
 * Syntax: GNU AS MIT style for m68k (m68k-linux-gnu-as default).
 *   Registers:    %d0-%d7 (data), %a0-%a7 (address), %sp = %a7
 *   Indirect:     %a0@ (= (%a0) in Motorola), %sp@+ (post-increment)
 *   Displacement: %sp@(N) (= N(sp) in Motorola)
 *   Sizes:        movl (long), movw (word), subql, subal, etc.
 *
 * Calling convention background:
 *   PCC (C cdecl):    args pushed right-to-left; CALLER cleans stack after return.
 *   Mac ROM (Pascal): args pushed left-to-right; ROM/callee cleans stack.
 *
 * Bridge pattern for stack-based Pascal traps (N args, void return):
 *   At stub entry: %sp -> [ret_to_PCC] [argN] ... [arg1]  (C order, right-to-left)
 *   We need trap to see: %sp -> [argN] ... [arg1]  (Pascal top = last arg pushed)
 *
 *   Because Pascal is callee-clean: ROM will pop all N arg bytes after returning.
 *   But PCC (caller-clean) will ALSO try to clean N bytes via addq/lea.
 *   Double-clean corrupts the stack.
 *
 *   Solution per arg byte size N:
 *     1. Pop [ret_to_PCC] into %an via movl %sp@+, %an.
 *     2. Execute trap (ROM sees arg(s) at top; ROM cleans them -> %sp += N).
 *     3. Push N bytes of padding back (subql #N, %sp).
 *     4. jmp %an@  -- return to PCC; PCC then adds N bytes -> balanced.
 *
 * Bridge pattern for register-based traps (args loaded into registers):
 *   Load arg from stack (above ret addr) into the required register.
 *   Execute trap (ROM reads register, not stack).
 *   RTS -- PCC cleans the arg slot.
 *
 * Assembled with: m68k-linux-gnu-as -m68020 libtoolbox-stubs.s -o libtoolbox-stubs.o
 * Archived with:  m68k-linux-gnu-ar rcs libtoolbox-stubs.a libtoolbox-stubs.o
 */

	.text

/* -- No-arg void traps --------------------------------------------------
 * Stack at entry: %sp -> [ret_to_PCC]
 * ROM takes no args; just execute trap and return. */

	.globl InitFonts
InitFonts:
	.word	0xA8FE		/* _InitFonts */
	rts

	.globl InitWindows
InitWindows:
	.word	0xA912		/* _InitWindows */
	rts

	.globl InitMenus
InitMenus:
	.word	0xA930		/* _InitMenus */
	rts

	.globl TEInit
TEInit:
	.word	0xA9CC		/* _TEInit */
	rts

/* -- 1-arg (4-byte pointer) void traps ----------------------------------
 * C cdecl entry:  %sp -> [ret_to_PCC] [ptr (4B)]
 * Pascal at trap: %sp -> [ptr]
 * ROM cleans 4 bytes; PCC cleans 4 bytes -> push 4 back before returning. */

	.globl InitGraf
InitGraf:
	/* void InitGraf(GrafPtr *thePort)  trap 0xA86E */
	movl	%sp@+, %a0	/* pop ret addr; %sp -> [thePort] */
	.word	0xA86E		/* ROM reads thePort from stack, cleans 4 bytes */
	subql	#4, %sp		/* restore 4 bytes so PCC's addq #4 balances */
	jmp	%a0@

	.globl InitDialogs
InitDialogs:
	/* void InitDialogs(ProcPtr resumeProc)  trap 0xA97B */
	movl	%sp@+, %a0	/* pop ret addr; %sp -> [resumeProc] */
	.word	0xA97B		/* ROM reads resumeProc, cleans 4 bytes */
	subql	#4, %sp
	jmp	%a0@

	.globl SetPort
SetPort:
	/* void SetPort(GrafPtr port)  trap 0xA873 */
	movl	%sp@+, %a0	/* pop ret addr; %sp -> [port] */
	.word	0xA873		/* ROM reads port, cleans 4 bytes */
	subql	#4, %sp
	jmp	%a0@

	.globl DrawString
DrawString:
	/* void DrawString(const unsigned char *s)  trap 0xA884 */
	movl	%sp@+, %a0	/* pop ret addr; %sp -> [s] */
	.word	0xA884		/* ROM reads s (Pascal string ptr), cleans 4 bytes */
	subql	#4, %sp
	jmp	%a0@

/* -- 2-arg (two 2-byte INTEGER) void trap: MoveTo -----------------------
 * MoveTo(h, v) -- C cdecl right-to-left push: v pushed first (deepest), h on top.
 * At stub entry: %sp -> [ret_to_PCC] [h (2B)] [v (2B)]
 * After popping ret addr: %sp -> [h (2B)] [v (2B)]  (h at top, v below)
 *
 * Pascal left-to-right: h pushed first (deepest), v pushed last (on top).
 * ROM expects: %sp -> [v (2B)] [h (2B)]  (v at top, h below)
 *
 * C has h at top, Pascal wants v at top -> must swap the two 16-bit words.
 * ROM cleans 4 bytes (callee-clean); PCC cleans 4 bytes -> push 4 back. */

	.globl MoveTo
MoveTo:
	/* void MoveTo(short h, short v)  trap 0xA893 */
	movl	%sp@+, %a0	/* pop ret addr; %sp -> [h (2B)] [v (2B)] */
	movw	%sp@, %d0	/* save h (word at sp+0) */
	movw	%sp@(2), %d1	/* save v (word at sp+2) */
	movw	%d1, %sp@	/* put v at top (Pascal wants v on top) */
	movw	%d0, %sp@(2)	/* put h below (Pascal wants h below v) */
	.word	0xA893		/* ROM reads v (top), h (below), cleans 4 bytes */
	subql	#4, %sp		/* restore 4 bytes for PCC cleanup */
	jmp	%a0@

/* -- FlushEvents: register-based (D0-packed) ----------------------------
 * Both 16-bit args are packed into D0: D0[31:16]=stopmask, D0[15:0]=evmask.
 *
 * C cdecl for FlushEvents(short evmask, short stopmask):
 *   Right-to-left push: stopmask pushed first (deepest), evmask pushed last.
 *   %sp -> [ret_to_PCC] [evmask (2B)] [stopmask (2B)]
 *   sp+4 = evmask (high 16 bits), sp+6 = stopmask (low 16 bits) when read as long.
 *   movl %sp@(4), %d0  ->  D0[31:16]=evmask, D0[15:0]=stopmask  (wrong order)
 *   swap %d0           ->  D0[31:16]=stopmask, D0[15:0]=evmask  (correct for ROM)
 *
 * Register-based: ROM reads D0 only, no stack args consumed.
 * Simple RTS without popping ret -- PCC cleans the 4 bytes of stack args normally. */

	.globl FlushEvents
FlushEvents:
	/* void FlushEvents(short evmask, short stopmask)  trap 0xA032 */
	/* %sp -> [ret] [evmask (2B)] [stopmask (2B)] */
	movl	%sp@(4), %d0	/* D0[31:16]=evmask, D0[15:0]=stopmask */
	swap	%d0		/* D0[31:16]=stopmask, D0[15:0]=evmask (ROM order) */
	.word	0xA032		/* FlushEvents: reads D0, no stack delta */
	rts			/* return; PCC does addq.l #4 to clean args */

/* -- Button: no args, returns Boolean in D0 -----------------------------
 * Stack at entry: %sp -> [ret_to_PCC]
 * ROM sets D0.w = 1 (true) or 0 (false); no args, no stack delta.
 * C return value in D0 -- already there. */

	.globl Button
Button:
	/* Boolean Button(void)  trap 0xA974 */
	.word	0xA974		/* ROM sets D0 = mouse button state */
	rts

/* -- NewWindow: 8 args, returns WindowPtr in A0 -------------------------
 * Pascal left-to-right push order (first arg deepest, last arg at %sp):
 *   wStorage (4B), r (4B), title (4B), visible (2B), procID (2B),
 *   behind (4B), goAwayFlag (2B), refCon (4B)  -> total 26 bytes
 *
 * C cdecl and Pascal push args in OPPOSITE order.
 * Reversing 26 bytes requires complex assembly -- deferred to a future phase.
 * Returns NULL (in %a0) so accidental calls fail visibly rather than crashing. */

	.globl NewWindow
NewWindow:
	/* WindowPtr NewWindow(void*, Rect*, char*, Boolean, short, WindowPtr, Boolean, long)
	 * trap 0xA913 -- complex 8-arg stub (26 bytes total), future TODO.
	 * Returns NULL (%a0 = 0). */
	subal	%a0, %a0	/* %a0 = NULL (Mac uses %a0 for pointer returns) */
	rts
