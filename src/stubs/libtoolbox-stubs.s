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

/* -- 2-arg (two SHORT) void trap: MoveTo --------------------------------
 *
 * 2026-05-14 correction: PCC's m68k codegen pushes `short` arguments as
 * 4-byte longwords (`movel #100, %sp@-`), not 2-byte words.  Empirically
 * confirmed against PCC's emitted .s.  The earlier draft of this stub
 * assumed 2-byte short args, which read the WRONG half of each 4-byte
 * slot — MoveTo(100, 100) ended up calling ROM with (h=0, v=100).
 *
 * Stack at stub entry (PCC pushed v=4B, then h=4B, then JSR=4B ret):
 *   %sp+0..3 : ret_addr (4B)
 *   %sp+4..7 : h_long  (4B, real h in low word at sp+6..7)
 *   %sp+8..11: v_long  (4B, real v in low word at sp+10..11)
 *
 * MoveTo is Pascal/Toolbox callee-clean: ROM cleans its 4 bytes of args.
 * PCC then does add.l #8, %sp to clean its 8-byte push.  Stub must
 * arrange for total SP delta across the call to be 0. */

	.globl MoveTo
MoveTo:
	/* void MoveTo(short h, short v)  trap 0xA893 */
	movl	%sp@+, %a0	/* pop ret addr; %sp -> [h_long][v_long] (8B) */
	movw	%sp@(2), %d0	/* D0.w = real h (low word of h_long) */
	movw	%sp@(6), %d1	/* D1.w = real v (low word of v_long) */
	movw	%d1, %sp@	/* write v as a word at sp+0 (Pascal: v on top) */
	movw	%d0, %sp@(2)	/* write h as a word at sp+2 (Pascal: h below) */
	/* %sp -> [v_short][h_short][v_long_4B] — ROM will consume first 4B */
	.word	0xA893		/* ROM reads v (top), h (below), cleans 4 bytes */
	/* After ROM: %sp advanced by 4 -> points at remnant of v_long (4B). */
	/* PCC will add.l #8 to %sp after we return; for balance we must leave
	 * SP 8 bytes BELOW the pre-stub-entry post-pop point.  We popped 4
	 * (ret), ROM cleaned 4 -> net -4 from post-pop, so SP is 4 above where
	 * we need to be.  subq.l #4 brings it back. */
	subql	#4, %sp
	jmp	%a0@

/* -- FlushEvents: register-based (D0-packed), PCC 4-byte arg slots ------
 *
 * 2026-05-14 correction: same root cause as MoveTo.  PCC pushes the two
 * `short` args as 4-byte longwords; previous version of this stub read
 * sp@(4) as a longword and tried to swap halves to repack — which would
 * have been correct ONLY if PCC pushed 2-byte shorts.  Empirically:
 *
 *   PCC emits:  movel #stopmask, %sp@-;  movel #evmask, %sp@-;  jsr ...
 *   Stack: %sp+0..3 = ret, %sp+4..7 = evmask_long, %sp+8..11 = stopmask_long
 *   Real evmask in low word (sp+6..7); real stopmask in low word (sp+10..11)
 *
 * ROM expects D0[31:16]=stopmask, D0[15:0]=evmask.  Build that by
 * reading each low word and assembling D0 explicitly. */

	.globl FlushEvents
FlushEvents:
	/* void FlushEvents(short evmask, short stopmask)  trap 0xA032 */
	moveq	#0, %d0		/* clear D0 */
	movw	%sp@(10), %d0	/* D0[15:0] = stopmask, D0[31:16] still 0 */
	swap	%d0		/* D0[31:16] = stopmask, D0[15:0] = 0 */
	movw	%sp@(6), %d0	/* D0[15:0] = evmask  (high half unchanged) */
	.word	0xA032		/* FlushEvents: reads D0; no stack delta */
	rts			/* PCC does add.l #8 to clean its 2×4B args */

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

/* -- Memory Manager init traps (added 2026-05-14 for H2 probe) ----------
 * Standard Mac apps call these at startup BEFORE InitGraf to expand the
 * application heap and pre-allocate master pointers.  hello_toolbox.c
 * skips them on the assumption that the System sets up a default heap
 * good enough for a trivial app -- but that may be the bug causing
 * InitGraf's internal allocation to trip.
 *
 * MaxApplZone (trap $A063): expand application heap to its max.  No args.
 *   Bit 11=0 (OS trap), bit 9=0 (no A0 preserve), bit 8=0.  Trashes A0-A2,
 *   D0-D2.  Our stub doesn't use any of those across the call, so the
 *   register conventions are irrelevant for us.
 * MoreMasters (trap $A036): allocate another master pointer block.  No
 *   args, no return.  Same convention as MaxApplZone.
 */

	.globl MaxApplZone
MaxApplZone:
	.word	0xA063		/* _MaxApplZone */
	rts

	.globl MoreMasters
MoreMasters:
	.word	0xA036		/* _MoreMasters */
	rts
