/*
 * spike/hello_initgraf_local.c — H1 probe.
 *
 * The hello_initgraf.c probe crashes (CHK / type-3) on the InitGraf
 * call.  Three hypotheses for why:
 *
 *   H1: The pointer passed to InitGraf is wrong.  &qd.thePort
 *       resolves to A5 + (some offset) at runtime; if that offset
 *       points outside the allocated below-A5 region (because the
 *       Retro68Relocate `displacements[bss]` base differs from what
 *       the linker stored), InitGraf writes to invalid memory and
 *       the system crashes.
 *
 *   H2: Mac heap not pre-initialised.  Standard apps call
 *       MaxApplZone + MoreMasters × 3 before InitGraf.  Without them,
 *       InitGraf's NewPtr allocations may trip a heap-bounds check.
 *
 *   H3: InitGraf stub mechanics wrong.  Our stub assumes Pascal
 *       callee-clean.  If that's not the convention for $A86E, the
 *       stack drifts.
 *
 * This probe disambiguates H1 by passing a STACK-ALLOCATED GrafPtr
 * instead of &qd.thePort.  The argument bytes pushed by PCC are:
 *   - In hello_initgraf.c:  `pea (qd + 0xca).L`  -- needs RELA fixup
 *     against the bss base.  If that base is wrong, the pointer is wrong.
 *   - In hello_initgraf_local.c:  `pea -4(%fp)` or similar -- a
 *     stack-relative address resolved at runtime from FP, no
 *     relocation needed.  Always points to valid stack memory.
 *
 * Expected behaviour:
 *   - hello_initgraf       → CHK / type-3  (confirmed by user)
 *   - hello_initgraf_local → silent exit IF H1 is correct.
 *                            Same CHK / type-3 IF H1 is wrong (and
 *                            H2 or H3 is the real bug).
 *
 * Note: InitGraf with a stack local doesn't initialise qd.thePort.
 * Any subsequent QuickDraw call would fail.  We exit immediately so
 * that's fine.
 */

#include <Types.h>
#include <Quickdraw.h>

int main(void)
{
    GrafPtr local;
    InitGraf(&local);
    return 0;
}
