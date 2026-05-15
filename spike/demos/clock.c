/*
 * spike/demos/clock.c — real-time clock display.
 *
 * Continuously redraws the current Mac time (HH:MM:SS) until the user
 * clicks. Demonstrates the date/time Toolbox APIs and a polling
 * redraw loop that doesn't spin the CPU too hot.
 *
 * Toolbox APIs used:
 *   InitGraf, InitFonts, InitWindows, InitMenus, TEInit, InitDialogs,
 *   FlushEvents, MoveTo, DrawString, GetDateTime, IUTimeString,
 *   Button, TickCount, EraseRect.
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
/* GetDateTime + IUTimeString live in Multiverse.h (pulled in transitively
 * by <Types.h>). Retro68 does not ship separate DateTimeUtils.h /
 * OSUtils.h with these declarations. */

static const unsigned char kLabel[] = {
    6, 'T', 'i', 'm', 'e', ':', ' '
};

int main(void)
{
    Rect timeRect;
    Str255 timeStr;
    unsigned long secs;
    unsigned long lastTick = 0;

    InitGraf(&qd.thePort);
    InitFonts();
    InitWindows();
    InitMenus();
    TEInit();
    InitDialogs(0);
    FlushEvents(everyEvent, 0);

    /* The "Time: " label + erase-rect for the time string redraw. */
    SetRect(&timeRect, 150, 88, 320, 110);
    MoveTo(100, 105);
    DrawString(kLabel);

    /* Update loop. Throttle to once every ~30 ticks (0.5 sec) via
     * TickCount; otherwise the redraw fights the OS for cycles and
     * the display flickers. Exit on mouse click. */
    while (!Button()) {
        unsigned long now = TickCount();
        if (now - lastTick >= 30) {
            lastTick = now;
            GetDateTime(&secs);
            IUTimeString(secs, false, timeStr);
            EraseRect(&timeRect);
            MoveTo(150, 105);
            DrawString(timeStr);
        }
    }

    return 0;
}
