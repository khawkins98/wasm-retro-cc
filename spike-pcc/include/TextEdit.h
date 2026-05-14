#ifndef TEXTEDIT_H
#define TEXTEDIT_H

#include "Types.h"

typedef void *TEHandle;  /* opaque — TERec handle */

extern void     TEInit(void);
extern TEHandle TENew(const Rect *destRect, const Rect *viewRect);
extern void     TEDispose(TEHandle hTE);
extern void     TESetText(const void *text, int32_t length, TEHandle hTE);
extern void     TEKey(int16_t key, TEHandle hTE);
extern void     TEUpdate(const Rect *rUpdate, TEHandle hTE);
extern void     TEActivate(TEHandle hTE);
extern void     TEDeactivate(TEHandle hTE);
extern void     TEIdle(TEHandle hTE);
extern void     TEClick(Point pt, Boolean fExtend, TEHandle hTE);
extern void     TESetSelect(int32_t selStart, int32_t selEnd, TEHandle hTE);
extern void     TEInsert(const void *text, int32_t length, TEHandle hTE);
extern void     TEDelete(TEHandle hTE);
extern void     TECut(TEHandle hTE);
extern void     TECopy(TEHandle hTE);
extern void     TEPaste(TEHandle hTE);

#endif /* TEXTEDIT_H */
