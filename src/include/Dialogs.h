#ifndef DIALOGS_H
#define DIALOGS_H

#include "Types.h"
#include "Windows.h"

typedef void *DialogPtr;   /* opaque — DialogRecord pointer */
typedef void *DialogHandle;

/* InitDialogs takes a "resume procedure" pointer; user code passes NULL (0L) */
typedef void (*ResumeProcPtr)(void);

extern void      InitDialogs(ResumeProcPtr resumeProc);
extern DialogPtr NewDialog(void *dStorage, const Rect *boundsRect,
                           const unsigned char *title, Boolean visible,
                           int16_t procID, WindowPtr behind, Boolean goAwayFlag,
                           int32_t refCon, Handle items);
extern DialogPtr GetNewDialog(int16_t dialogID, void *dStorage, WindowPtr behind);
extern void      DisposeDialog(DialogPtr theDialog);
extern void      ModalDialog(void *filterProc, int16_t *itemHit);
extern void      CloseDialog(DialogPtr theDialog);

#endif /* DIALOGS_H */
