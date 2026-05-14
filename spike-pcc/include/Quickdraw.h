#ifndef QUICKDRAW_H
#define QUICKDRAW_H

#include "Types.h"

/* GrafPort — opaque; user code must not inspect internals */
typedef struct GrafPort GrafPort;
typedef GrafPort *GrafPtr;

/* Classic Mac OS uses mac68k-style struct packing: 2-byte alignment, no
 * tail padding on structs.  Retro68's GCC honors this via the multiversal
 * interfaces' `#pragma options align=mac68k`, so libretrocrt's `qd`
 * symbol places `thePort` at byte offset 202.  Without pack(2), PCC's
 * default alignment would force `Ptr baseAddr` inside `BitMap` to 4
 * bytes — which gives BitMap a 2-byte tail pad (14 → 16), shifting
 * `thePort` to offset 204 and producing a struct that doesn't match
 * libretrocrt's `qd` layout.
 *
 * Discovered 2026-05-14 from a type-3 boot crash: the readelf -r dump
 * of hello_toolbox.o showed `R_68K_32 qd + cc` (0xcc = 204), proving
 * the ABI mismatch.  Wrapping the structs in pack(2) brings BitMap
 * back to 14 bytes and lands thePort at offset 202.  See
 * `LEARNINGS.md` "Boot test (2026-05-14)" for the full diagnostic
 * chain. */
#pragma pack(push, 2)

typedef struct BitMap {
    Ptr     baseAddr;   /* 4 bytes */
    int16_t rowBytes;   /* 2 bytes */
    Rect    bounds;     /* 8 bytes */
} BitMap;               /* total: 14 bytes (with pack(2) — no tail pad) */

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

#pragma pack(pop)

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
