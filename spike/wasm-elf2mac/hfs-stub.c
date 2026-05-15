/* spike/wasm-elf2mac/hfs-stub.c — no-op libhfs replacement.
 * See hfs-stub.h for rationale. These should never be called from
 * Elf2Mac's actual code path; they exist purely to satisfy linker. */
#include "hfs-stub.h"
#include <stddef.h>

int      hfs_format(const char *p, int n, int m, const char *v,
                    unsigned int b, const unsigned long *bb) { (void)p;(void)n;(void)m;(void)v;(void)b;(void)bb; return -1; }
hfsvol  *hfs_mount(const char *p, int n, int m)              { (void)p;(void)n;(void)m; return NULL; }
hfsfile *hfs_create(hfsvol *v, const char *p, const char *t,
                    const char *c)                           { (void)v;(void)p;(void)t;(void)c; return NULL; }
int      hfs_setfork(hfsfile *f, int k)                      { (void)f;(void)k; return -1; }
long     hfs_write(hfsfile *f, const void *b, unsigned long l){ (void)f;(void)b;(void)l; return -1; }
int      hfs_close(hfsfile *f)                               { (void)f; return -1; }
int      hfs_umount(hfsvol *v)                               { (void)v; return -1; }
