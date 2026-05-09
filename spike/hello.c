/*
 * spike/hello.c — minimal Classic Mac windowed "Hello World"
 *
 * This is the Phase 0 test program. It must compile with PCC's m68k backend
 * using only our shim headers (no A-trap syntax anywhere in user code).
 *
 * What it tests:
 *   - Basic Mac toolbox initialization sequence
 *   - Window creation and drawing
 *   - Simple event loop (quit on any click)
 *   - Standard C function call ABI to Toolbox stubs
 *
 * What it deliberately avoids:
 *   - pascal keyword (ABI validation deferred)
 *   - Any GCC extensions
 *   - C99 features beyond basic types (test C89 compat first)
 *   - Floating point
 *   - malloc/free (use Mac Memory Manager instead)
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

static const unsigned char kWindowTitle[] = "\013Hello, Mac!";
static const unsigned char kHelloLine1[] = "\031Hello from wasm-retro-cc!";
static const unsigned char kHelloLine2[] =
    "\062This was compiled by PCC -> m68k, not Retro68 GCC.";

int main(void)
{
    WindowPtr  win;
    EventRecord ev;
    Rect       bounds;

    /* Standard Mac initialization sequence */
    InitGraf(&qd.thePort);
    InitFonts();
    InitWindows();
    InitMenus();
    TEInit();
    InitDialogs(0L);
    FlushEvents(everyEvent, 0);

    /* Create a simple document window */
    SetRect(&bounds, 60, 60, 420, 240);
    win = NewWindow(
        0L,             /* storage — 0 means NewWindow allocates */
        &bounds,
        kWindowTitle,
        TRUE,           /* visible */
        documentProc,   /* window type */
        (WindowPtr)-1L, /* in front of all windows */
        FALSE,          /* no go-away box */
        0L              /* refCon */
    );
    SetPort(win);

    /* Draw some text */
    MoveTo(20, 40);
    DrawString(kHelloLine1);

    MoveTo(20, 60);
    DrawString(kHelloLine2);

    /* Wait for a mouse click, then quit */
    while (!Button()) {
        WaitNextEvent(everyEvent, &ev, 1L, 0L);
    }

    return 0;
}
