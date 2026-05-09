/*
 * spike/hello_toolbox.c — Phase 2 Toolbox pipeline validation
 *
 * A minimal Mac hello world that calls real Toolbox managers.
 * Compiled with PCC, linked with libtoolbox-stubs.a + libretrocrt.a + libc.a.
 *
 * This validates:
 *   - Our shim headers are accepted by PCC
 *   - Our libtoolbox-stubs.a correctly bridges C cdecl → Mac ROM A-traps
 *   - The resulting MacBinary boots in BasiliskII / classic-vibe-mac
 *
 * Deliberately avoids NewWindow (complex 8-arg stub deferred to Phase 3).
 * Drawing to the screen port (qd.thePort) without an explicit window is
 * valid Classic Mac OS behaviour — the ROM initialises a screen port in
 * InitGraf, and all QuickDraw calls default to it.
 *
 * Pascal string note: Classic Mac DrawString expects a Pascal string
 * (first byte = length, no NUL terminator).  We cannot use GCC's "\p..."
 * extension because PCC doesn't implement it.  Use an explicit byte array.
 */

#include <Types.h>
#include <Quickdraw.h>
#include <Fonts.h>
#include <Windows.h>
#include <Menus.h>
#include <TextEdit.h>
#include <Dialogs.h>
#include <Events.h>
#include <Memory.h>

/* "Hello, World!" as a Pascal string: byte 0 = length (13), then chars */
static const unsigned char kHelloStr[] = {
    13, 'H','e','l','l','o',',',' ','W','o','r','l','d','!'
};

int main(void)
{
    /* ── Toolbox initialisation ──────────────────────────────────────────
     * Order matters: InitGraf MUST be first; everything else follows the
     * standard Inside Mac sequence. */

    InitGraf(&qd.thePort);  /* init QuickDraw globals; must be first */
    InitFonts();
    InitWindows();
    InitMenus();
    TEInit();
    InitDialogs(0);         /* 0 == NULL resume proc */
    FlushEvents(everyEvent, 0);

    /* ── Draw hello world to screen port ────────────────────────────────
     * The screen port is active after InitGraf.  Drawing here lands on
     * the desktop (screen) — visible without creating a window.
     * Coordinates are in pixels from the top-left of the screen. */

    MoveTo(100, 100);
    DrawString(kHelloStr);

    /* ── Wait for mouse click before exit ───────────────────────────────
     * Classic Mac apps loop forever; we exit on the first click to keep
     * the spike simple. */
    while (!Button())
        ;   /* spin until mouse button pressed */

    return 0;
}
