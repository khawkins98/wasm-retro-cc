#ifndef EVENTS_H
#define EVENTS_H

#include "Types.h"

/* Event types */
#define nullEvent    0
#define mouseDown    1
#define mouseUp      2
#define keyDown      3
#define keyUp        4
#define autoKey      5
#define updateEvt    6
#define diskEvt      7
#define activateEvt  8
#define osEvt        15

/* Event mask bits */
#define nullEvtMask     0x0001
#define mDownMask       0x0002
#define mUpMask         0x0004
#define keyDownMask     0x0008
#define keyUpMask       0x0010
#define autoKeyMask     0x0020
#define updateMask      0x0040
#define diskMask        0x0080
#define activMask       0x0100
#define osMask          0x8000
#define everyEvent      0xFFFF

/* WaitNextEvent / GetNextEvent */
extern Boolean WaitNextEvent(uint16_t eventMask, EventRecord *theEvent,
                              uint32_t sleep, void *mouseRgn);
extern Boolean GetNextEvent(uint16_t eventMask, EventRecord *theEvent);
extern Boolean EventAvail(uint16_t eventMask, EventRecord *theEvent);

/* Mouse */
extern Boolean Button(void);
extern Boolean StillDown(void);
extern void    GetMouse(Point *mouseLoc);

/* Keyboard */
extern void    FlushEvents(uint16_t eventMask, uint16_t stopMask);

#endif /* EVENTS_H */
