#ifndef WINDOWS_H
#define WINDOWS_H

#include "Types.h"
#include "Quickdraw.h"

/* Window procedure types */
#define documentProc    0
#define dBoxProc        1
#define plainDBox       2
#define altDBoxProc     3
#define noGrowDocProc   4
#define movableDBoxProc 5
#define zoomDocProc     8
#define zoomNoGrow      12

/* Magic value for "in front of all" */
#define inFront ((void *)-1L)

typedef GrafPort WindowRecord;
typedef WindowRecord *WindowPtr;

extern WindowPtr NewWindow(void *wStorage, const Rect *boundsRect,
                           const unsigned char *title, Boolean visible,
                           int16_t theProc, WindowPtr behind,
                           Boolean goAwayFlag, int32_t refCon);
extern void     DisposeWindow(WindowPtr theWindow);
extern void     SetWTitle(WindowPtr theWindow, const unsigned char *title);
extern void     ShowWindow(WindowPtr theWindow);
extern void     HideWindow(WindowPtr theWindow);
extern void     SelectWindow(WindowPtr theWindow);
extern void     BringToFront(WindowPtr theWindow);
extern void     DrawGrowIcon(WindowPtr theWindow);
extern void     InvalRect(const Rect *badRect);
extern void     BeginUpdate(WindowPtr theWindow);
extern void     EndUpdate(WindowPtr theWindow);
extern int16_t  FindWindow(Point thePt, WindowPtr *theWindow);

#endif /* WINDOWS_H */
