/*
 * spike/demos/lines.c — line drawing demo.
 *
 * Draws a fan of lines radiating from a central point, then waits for a
 * mouse click before exiting. Demonstrates QuickDraw MoveTo + LineTo
 * primitives without needing a window (draws directly to the screen
 * port that InitGraf sets up).
 *
 * Toolbox APIs used:
 *   InitGraf, InitFonts, InitWindows, InitMenus, TEInit, InitDialogs,
 *   FlushEvents, MoveTo, LineTo, Button.
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

int main(void)
{
    short i;

    InitGraf(&qd.thePort);
    InitFonts();
    InitWindows();
    InitMenus();
    TEInit();
    InitDialogs(0);
    FlushEvents(everyEvent, 0);

    /* Fan of 8 lines radiating from (200, 150), each 100px long.
     * Hand-rolled trig table because the standard Math library isn't
     * available without floating-point support (which would pull in
     * libm and bloat the binary for a demo). Pre-computed deltas for
     * 8 evenly-spaced angles around 360°. */
    {
        static const short dx[8] = {  100,   71,    0,  -71, -100,  -71,    0,   71 };
        static const short dy[8] = {    0,   71,  100,   71,    0,  -71, -100,  -71 };
        const short cx = 200, cy = 150;
        for (i = 0; i < 8; i++) {
            MoveTo(cx, cy);
            LineTo(cx + dx[i], cy + dy[i]);
        }
    }

    /* Bounding box around the fan for visual framing. */
    MoveTo(100, 50);  LineTo(300, 50);
    LineTo(300, 250); LineTo(100, 250); LineTo(100, 50);

    while (!Button())
        ;
    return 0;
}
