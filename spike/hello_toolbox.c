/*
 * spike/hello_toolbox.c — Phase 2.0 Retro68 GCC derisk
 *
 * A minimal Mac hello world that calls real Toolbox managers, built with
 * the official Retro68 GCC toolchain (via the pinned Docker image).
 *
 * The C source is functionally identical to spike-pcc/hello_toolbox.c
 * (the Phase 1 PCC bisect probe), so the boot outcome compares apples
 * to apples: same Toolbox call sequence, different compiler + crt + libs.
 *
 * Phase 1 (PCC) result: this exact program crashed on any single Toolbox
 * call after three structural bugs were fixed (see spike-pcc/ARCHIVE.md
 * and LEARNINGS.md "Boot test (2026-05-14)"). The remaining failure mode
 * was the trigger for the Phase 2 pivot.
 *
 * Phase 2.0 question: does the *same* program, compiled by Retro68 GCC
 * and linked against Retro68's own crt + libInterface, boot cleanly in
 * the same BasiliskII Quadra-650 the playground deploys? If yes,
 * Phase 2's "do we even have a viable binary?" risk collapses to zero
 * and the project's remaining work is the (known-bounded) Emscripten
 * port of GCC + binutils + Elf2Mac.
 *
 * Build (host):
 *   bash spike/build-retro68.sh
 *
 * Output: spike/build/hello-toolbox-retro68.bin — a complete MacBinary II
 * APPL (no resource splice needed), ready to be HFS-patched into the
 * classic-vibe-mac BasiliskII disk image as a prebuilt demo.
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

/* "Hello, World!" as a Pascal string: byte 0 = length (13), then chars.
 * Spelled out as a byte array (not GCC's "\pHello…" extension) so the
 * source is portable across both Retro68 GCC and PCC — useful for any
 * future side-by-side comparison work. */
static const unsigned char kHelloStr[] = {
    13, 'H','e','l','l','o',',',' ','W','o','r','l','d','!'
};

int main(void)
{
    /* Toolbox initialisation — order matters: InitGraf MUST be first. */
    InitGraf(&qd.thePort);
    InitFonts();
    InitWindows();
    InitMenus();
    TEInit();
    InitDialogs(0);
    FlushEvents(everyEvent, 0);

    /* Draw to the screen port (the desktop) — visible without a window. */
    MoveTo(100, 100);
    DrawString(kHelloStr);

    /* Spin until the user clicks, so the playground screenshot has time
     * to capture the drawn string before the app exits. */
    while (!Button())
        ;

    return 0;
}
