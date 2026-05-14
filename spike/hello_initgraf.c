/*
 * spike/hello_initgraf.c — bisect probe between hello.c and hello_toolbox.c.
 *
 * Calls InitGraf only.  Used to localise the type-3 / CHK crash:
 *   - hello.c (no Toolbox) launches and exits cleanly  (verified 2026-05-14)
 *   - hello_toolbox.c (full Toolbox sequence) crashes  (verified 2026-05-14)
 *   - hello_initgraf.c (this) tests whether InitGraf itself is the culprit.
 *
 * No Button loop, no DrawString — just call InitGraf and return.
 * Same compile + link path as hello_toolbox (libtoolbox-stubs.a linked in).
 *
 * Expected results, if InitGraf is NOT the bug:
 *   - Launch like hello.c: zoom rects, no app window, silent exit.
 * Expected results, if InitGraf IS the bug:
 *   - Same bomb / CHK / type-3 dialog as hello_toolbox.c.
 */

#include <Types.h>
#include <Quickdraw.h>

int main(void)
{
    InitGraf(&qd.thePort);
    return 0;
}
