#ifndef QUICKDRAW_H
#define QUICKDRAW_H

#include "Types.h"

/* GrafPort — opaque; user code should not inspect internals */
typedef void GrafPort;
typedef GrafPort *GrafPtr;

/* QuickDraw globals (A5-relative in a real Mac app; provided by crt0.o) */
extern GrafPtr thePort;

extern void InitGraf(void *thePort);
extern void OpenPort(GrafPtr port);
extern void ClosePort(GrafPtr port);
extern void SetPort(GrafPtr port);
extern void GetPort(GrafPtr *port);

/* Drawing primitives */
extern void MoveTo(int16_t h, int16_t v);
extern void Move(int16_t dh, int16_t dv);
extern void LineTo(int16_t h, int16_t v);
extern void Line(int16_t dh, int16_t dv);

/* Text */
extern void DrawString(const unsigned char *s);
extern void DrawChar(int16_t ch);
extern void TextFont(int16_t font);
extern void TextSize(int16_t size);
extern void TextFace(int16_t face);

/* Region fill */
extern void PaintRect(const Rect *r);
extern void EraseRect(const Rect *r);
extern void FrameRect(const Rect *r);

#endif /* QUICKDRAW_H */
