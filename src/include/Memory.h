#ifndef MEMORY_H
#define MEMORY_H

#include "Types.h"

/* Zone initialisation */
extern void InitApplZone(void);
extern void MaxApplZone(void);
extern void MoreMasters(void);

/* Heap statistics */
extern int32_t FreeMem(void);
extern int32_t MaxMem(int32_t *grow);
extern int32_t CompactMem(int32_t cbNeeded);
extern void    PurgeMem(int32_t cbNeeded);

/* Pointer allocation */
extern Ptr     NewPtr(int32_t byteCount);
extern Ptr     NewPtrClear(int32_t byteCount);
extern void    DisposePtr(Ptr p);
extern int32_t GetPtrSize(Ptr p);
extern void    SetPtrSize(Ptr p, int32_t newSize);
extern OSErr   MemError(void);

/* Handle allocation */
extern Handle  NewHandle(int32_t byteCount);
extern Handle  NewHandleClear(int32_t byteCount);
extern void    DisposeHandle(Handle h);
extern int32_t GetHandleSize(Handle h);
extern void    SetHandleSize(Handle h, int32_t newSize);
extern void    HLock(Handle h);
extern void    HUnlock(Handle h);
extern void    HPurge(Handle h);
extern void    HNoPurge(Handle h);
extern void    MoveHHi(Handle h);
extern void    EmptyHandle(Handle h);

#endif /* MEMORY_H */
