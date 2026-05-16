/*
 * hello.c — minimal classic Mac Toolbox app.
 *
 * Opens a window, draws "Hello from wasm-retro-cc!" centred,
 * waits for a mouse-down anywhere, exits cleanly. Designed to be
 * the smallest credible Toolbox program that exercises the full
 * cc1 -> as -> ld -> Elf2Mac pipeline in this demo.
 *
 * Try changing the string, the window size, or the font, then hit
 * Compile. The MacBinary that drops out is the same shape the
 * classic-vibe-mac playground hot-loads into BasiliskII.
 */

#include <Types.h>
#include <Quickdraw.h>
#include <Fonts.h>
#include <Windows.h>
#include <Events.h>

QDGlobals qd;

int main(void) {
    InitGraf(&qd.thePort);
    InitFonts();
    InitWindows();
    InitCursor();

    Rect r;
    r.left = 40; r.top = 60; r.right = 360; r.bottom = 180;
    WindowPtr w = NewWindow(NULL, &r, "\pwasm-retro-cc demo",
                            true, documentProc, (WindowPtr)(-1),
                            true, 0);
    if (!w) return 1;
    SetPort((GrafPtr)w);
    TextFont(0);
    TextSize(12);

    unsigned char msg[] = {
        25, 'H','e','l','l','o',' ','f','r','o','m',' ',
        'w','a','s','m','-','r','e','t','r','o','-','c','c','!'
    };
    MoveTo(40, 60);
    DrawString(msg);

    EventRecord ev;
    while (1) {
        WaitNextEvent(everyEvent, &ev, 30, NULL);
        if (ev.what == mouseDown) break;
    }
    return 0;
}
