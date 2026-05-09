#ifndef TYPES_H
#define TYPES_H

#include <stdint.h>
#include <stddef.h>

/* Calling convention — pascal is a GCC m68k extension; treat as no-op here.
   Calling convention differences are handled by libretro68.a stubs. */
#define pascal

/* Boolean constants */
#define TRUE  1
#define FALSE 0
#define nil   NULL

/* Error codes */
#define noErr       0
#define memFullErr  (-108)
#define paramErr    (-50)

/* Fundamental Mac types */
typedef uint8_t   Byte;
typedef int16_t   Integer;
typedef int32_t   LongInt;
typedef uint32_t  ULongInt;
typedef int32_t   Fixed;        /* 16.16 fixed-point */
typedef uint8_t   Boolean;
typedef int16_t   OSErr;
typedef uint32_t  OSType;       /* four-char code, stored big-endian */
typedef uint32_t  ResType;
typedef void     *Ptr;
typedef void    **Handle;
typedef int32_t   Size;
typedef int16_t   ScriptCode;

/* Geometry */
typedef struct {
    int16_t v;
    int16_t h;
} Point;

typedef struct {
    int16_t top;
    int16_t left;
    int16_t bottom;
    int16_t right;
} Rect;

/* Event record */
typedef struct {
    int16_t  what;
    uint32_t message;
    uint32_t when;
    Point    where;
    uint16_t modifiers;
} EventRecord;

#endif /* TYPES_H */
