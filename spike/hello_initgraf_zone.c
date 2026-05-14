/*
 * spike/hello_initgraf_zone.c — H2 probe.
 *
 * H1 (qd pointer relocation) was ruled out 2026-05-14: the
 * stack-local-GrafPtr variant (hello_initgraf_local.c) still crashes.
 *
 * H2: Mac heap not pre-initialised.  Standard Mac apps call
 *   MaxApplZone();
 *   MoreMasters(); MoreMasters(); MoreMasters();
 * BEFORE InitGraf, to expand the application heap to its maximum size
 * and to pre-allocate three blocks of master pointers (handles).
 *
 * If InitGraf internally calls NewPtr or NewHandle and the default
 * pre-InitGraf heap state is too small or out of master pointers, the
 * allocation fails -- on classic Mac OS, that can manifest as a CHK
 * trap or, in newer systems, type-3 (illegal instruction) when the
 * Memory Manager's error path returns into unaligned code.
 *
 * Bonus signal from 2026-05-14 boot test: SimpleText (a system app
 * outside our build chain) also crashed type-3 after our app
 * crashed.  That suggests heap-pool exhaustion / global memory
 * corruption -- consistent with H2 if libretrocrt's startup leaves
 * the System in a state where the next allocation fails.
 *
 * Expected results:
 *   - Silent exit / hangs harmlessly  → H2 confirmed; the bug is heap
 *     init.  Fix: call MaxApplZone + MoreMasters from libretrocrt
 *     startup, or from every program.
 *   - Same type-3 crash               → H2 dead.  Move on to H3 (stub
 *     mechanics) or H4 (libretrocrt corrupts system state).
 */

#include <Types.h>
#include <Quickdraw.h>

extern void MaxApplZone(void);
extern void MoreMasters(void);

int main(void)
{
    MaxApplZone();
    MoreMasters();
    MoreMasters();
    MoreMasters();
    InitGraf(&qd.thePort);
    return 0;
}
