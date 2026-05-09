/*
 * spike/hello.c — Phase 0 pipeline validation
 *
 * Includes all shim headers to validate PCC can parse them.
 * Uses only integer arithmetic — no Toolbox calls.
 *
 * Phase 0 goal: prove PCC m68k compilation + linking works end-to-end.
 * Phase 1 will add Toolbox A-trap stubs and real Mac initialization.
 *
 * Deliberately avoids:
 *   - Toolbox calls (require A-trap stubs, deferred to Phase 1)
 *   - GCC extensions
 *   - Floating point
 *   - C99 features beyond basic types (test C89 compat first)
 */

#include <Types.h>
#include <Quickdraw.h>
#include <Windows.h>
#include <Menus.h>
#include <TextEdit.h>
#include <Dialogs.h>
#include <Events.h>
#include <Fonts.h>
#include <Memory.h>

int main(void)
{
    /* Integer loop — exercises PCC m68k code generation.
     * Sum of squares 1..10 = 385; return low byte (1). */
    int i;
    long sum = 0L;
    for (i = 1; i <= 10; i++) {
        sum += (long)i * (long)i;
    }
    return (int)(sum & 0x7F);
}
