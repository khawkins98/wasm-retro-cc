/*
 * spike/demos/counter.c — click counter demo.
 *
 * Increments a counter on each mouse click, redraws the count. Exits
 * after 10 clicks (so the demo terminates cleanly for screenshots).
 * Demonstrates an interactive event loop using EventAvail / GetMouse /
 * StillDown, plus NumToString for int → Pascal-string conversion.
 *
 * Toolbox APIs used:
 *   InitGraf, InitFonts, InitWindows, InitMenus, TEInit, InitDialogs,
 *   FlushEvents, MoveTo, DrawString, NumToString, Button, StillDown,
 *   EraseRect.
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
#include <Strings.h>

/* "Clicks: " label as Pascal string (length 8, then 8 chars). */
static const unsigned char kLabel[] = {
    8, 'C', 'l', 'i', 'c', 'k', 's', ':', ' '
};

int main(void)
{
    short count = 0;
    Rect counterRect;
    Str255 numStr;

    InitGraf(&qd.thePort);
    InitFonts();
    InitWindows();
    InitMenus();
    TEInit();
    InitDialogs(0);
    FlushEvents(everyEvent, 0);

    /* Rect we erase before redrawing the count, so the previous value
     * disappears cleanly. ~100px wide, ~20px tall, just right of the
     * "Clicks: " label. */
    SetRect(&counterRect, 170, 88, 280, 110);

    /* Initial draw: "Clicks: 0" at (100, 105). */
    MoveTo(100, 105);
    DrawString(kLabel);
    NumToString(count, numStr);
    DrawString(numStr);

    /* Event loop — count clicks, exit after 10. */
    while (count < 10) {
        /* Wait for press. */
        while (!Button() && count < 10)
            ;
        if (count >= 10) break;
        count++;

        /* Wait for release so a single press doesn't double-count. */
        while (StillDown())
            ;

        /* Erase old number, redraw with new value. */
        EraseRect(&counterRect);
        MoveTo(170, 105);
        NumToString(count, numStr);
        DrawString(numStr);
    }

    /* Linger after final click so the "10" is visible in screenshots. */
    MoveTo(100, 140);
    {
        static const unsigned char kDone[] = {
            18, 'D', 'o', 'n', 'e', '.', ' ', 'C', 'l', 'i', 'c', 'k',
            ' ', 't', 'o', ' ', 'e', 'x', 'i', 't'
        };
        DrawString(kDone);
    }
    while (!Button())
        ;
    return 0;
}
