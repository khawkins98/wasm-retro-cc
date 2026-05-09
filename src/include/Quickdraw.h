#ifndef QUICKDRAW_H
#define QUICKDRAW_H

#include "Types.h"

/* GrafPort — opaque; user code must not inspect internals */
typedef struct GrafPort GrafPort;
typedef GrafPort *GrafPtr;

typedef struct BitMap {
    Ptr     baseAddr;   /* 4 bytes */
    int16_t rowBytes;   /* 2 bytes */
    Rect    bounds;     /* 8 bytes */
} BitMap;               /* total: 14 bytes */

typedef struct Cursor {
    uint16_t data[16];  /* 32 bytes */
    uint16_t mask[16];  /* 32 bytes */
    Point    hotSpot;   /*  4 bytes */
} Cursor;               /* total: 68 bytes */

typedef struct Pattern {
    uint8_t pat[8];
} Pattern;              /* total: 8 bytes */

typedef struct QDGlobals {
    char    privates[76];  /*  76 bytes, offset   0 */
    int32_t randSeed;      /*   4 bytes, offset  76 -> cumulative: 80 */
    BitMap  screenBits;    /*  14 bytes, offset  80 -> cumulative: 94 */
    Cursor  arrow;         /*  68 bytes, offset  94 -> cumulative: 162 */
    Pattern dkGray;        /*   8 bytes, offset 162 -> cumulative: 170 */
    Pattern ltGray;        /*   8 bytes, offset 170 -> cumulative: 178 */
    Pattern gray;          /*   8 bytes, offset 178 -> cumulative: 186 */
    Pattern black;         /*   8 bytes, offset 186 -> cumulative: 194 */
    Pattern white;         /*   8 bytes, offset 194 -> cumulative: 202 */
    GrafPtr thePort;       /*   4 bytes, offset 202 */
} QDGlobals;               /* total: 206 bytes */

/* QuickDraw globals (A5-relative in a real Mac app; provided by crt0.o) */
extern QDGlobals qd;

extern void InitGraf(GrafPtr *thePort);
extern void OpenPort(GrafPtr port);
extern void ClosePort(GrafPtr port);
extern void SetPort(GrafPtr port);
extern void GetPort(GrafPtr *port);
extern void SetRect(Rect *r, int16_t left, int16_t top, int16_t right,
                    int16_t bottom);
extern void GetIndString(unsigned char *theString, int16_t strListID,
                         int16_t index);

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
