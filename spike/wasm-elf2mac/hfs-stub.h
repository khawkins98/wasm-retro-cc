/* spike/wasm-elf2mac/hfs-stub.h
 *
 * Minimal hfs.h shim. Retro68's ResourceFile.cc has one method that
 * writes a ".dsk" HFS volume via libhfs (hfs_format / hfs_mount /
 * hfs_create / hfs_setfork / hfs_write / hfs_close / hfs_umount).
 * Elf2Mac never calls that method — it only produces MacBinary II
 * output, not disk images.
 *
 * To avoid pulling in libhfs (no -dev apt package; would have to be
 * source-built), we provide a shim that satisfies the compile-time
 * include + symbol references with no-op declarations. At link time,
 * the unused .o references resolve against the no-op definitions in
 * a sibling hfs-stub.c — or, since Elf2Mac links statically and the
 * containing function is dead-code-eliminable, the linker may strip
 * them entirely.
 *
 * If someone later needs the real HFS code path (write .dsk via the
 * wasm Elf2Mac, presumably for a download-as-disk feature), swap in
 * a real libhfs port via emcc and remove this shim.
 */
#ifndef HFS_STUB_H
#define HFS_STUB_H

#ifdef __cplusplus
extern "C" {
#endif

typedef struct hfsvol hfsvol;
typedef struct hfsfile hfsfile;

#define HFS_MODE_RDWR 2

/* Function declarations match libhfs.a's externs closely enough to
 * compile; bodies are in hfs-stub.c (return NULL / -1). */
int      hfs_format(const char *path, int partno, int mode,
                    const char *vname, unsigned int nbadblocks,
                    const unsigned long *badblocks);
hfsvol  *hfs_mount(const char *path, int partno, int mode);
hfsfile *hfs_create(hfsvol *vol, const char *path,
                    const char *type, const char *creator);
int      hfs_setfork(hfsfile *file, int fork);
long     hfs_write(hfsfile *file, const void *buf, unsigned long len);
int      hfs_close(hfsfile *file);
int      hfs_umount(hfsvol *vol);

#ifdef __cplusplus
}
#endif

#endif /* HFS_STUB_H */
