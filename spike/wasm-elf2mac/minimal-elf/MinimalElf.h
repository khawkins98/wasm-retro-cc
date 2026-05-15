/* MinimalElf.h — drop-in libelf replacement for Elf2Mac wasm build.
 *
 * Implements just the libelf / gelf API surface Elf2Mac actually
 * touches (10 functions, ~5 types). Designed to be linked instead of
 * libelf.a — the headers ship the same type names (Elf, Elf_Scn,
 * GElf_*, etc.) and the function signatures match.
 *
 * Why not vendor real libelf?  See LEARNINGS.md "Phase 2.3 —
 * landmines": elfutils requires argp_parse (glibc-only), zlib via
 * a configure probe, and other glibc-isms.  Replacing 10 well-
 * defined functions over 6 opaque types is a 200-LOC bounded
 * exercise; chasing elfutils' build tree is unbounded.
 *
 * Scope:
 *  - Read-only ELF parsing (Elf2Mac never writes ELF).
 *  - Elf32 only — m68k targets are 32-bit.  GElf_* structs are
 *    still 64-bit-shaped (per gelf convention) but populated from
 *    Elf32_* source data with zero-extension.
 *  - Big-endian source bytes.  m68k ELF is BE; the wasm host is
 *    LE; this header takes care of byteswapping on read.
 *  - elf_begin reads via mmap/file-handle (ELF_C_READ).
 *
 * Out of scope:
 *  - Elf64 source bytes (would require runtime byteswap dispatch).
 *  - Writing ELF (elf_update, elf_*_new*, etc.).
 *  - ELF_C_RDWR, ELF_C_WRITE, RDWR_MMAP, etc.
 */

#ifndef MINIMAL_ELF_H
#define MINIMAL_ELF_H

#include <elf.h>      // emscripten ships this (kernel ELF struct defs)
#include <stddef.h>
#include <stdint.h>

/* libelf compatibility — public macros + enums Elf2Mac references. */
#ifndef EV_CURRENT
#define EV_CURRENT 1
#define EV_NONE    0
#endif

typedef enum {
  ELF_C_NULL = 0,
  ELF_C_READ,
  ELF_C_RDWR,
  ELF_C_WRITE,
} Elf_Cmd;

typedef enum {
  ELF_K_NONE = 0,
  ELF_K_AR,
  ELF_K_COFF,
  ELF_K_ELF,
  ELF_K_NUM,
} Elf_Kind;

typedef enum {
  ELF_T_BYTE = 0,
  ELF_T_ADDR,
  ELF_T_DYN,
  ELF_T_EHDR,
  ELF_T_HALF,
  ELF_T_OFF,
  ELF_T_PHDR,
  ELF_T_RELA,
  ELF_T_REL,
  ELF_T_RELR,
  ELF_T_SHDR,
  ELF_T_SWORD,
  ELF_T_SYM,
  ELF_T_WORD,
  ELF_T_XWORD,
  ELF_T_SXWORD,
  ELF_T_VDEF,
  ELF_T_VDAUX,
  ELF_T_VNEED,
  ELF_T_VNAUX,
  ELF_T_NHDR,
  ELF_T_SYMINFO,
  ELF_T_MOVE,
  ELF_T_LIB,
  ELF_T_GNUHASH,
  ELF_T_AUXV,
  ELF_T_CHDR,
  ELF_T_NHDR8,
  ELF_T_NUM,
} Elf_Type;

/* Opaque types per libelf — Elf2Mac only sees pointers. */
struct Elf_struct;
typedef struct Elf_struct Elf;

struct Elf_Scn_struct;
typedef struct Elf_Scn_struct Elf_Scn;

/* Elf_Data: a buffer-and-metadata view of a section's bytes.  Layout
 * matches libelf so existing field accesses (d_buf, d_size, ...) keep
 * compiling unmodified. */
typedef struct {
  void *d_buf;
  Elf_Type d_type;
  unsigned int d_version;
  size_t d_size;
  int64_t d_off;
  size_t d_align;
} Elf_Data;

/* GElf_* — "generic" types large enough for either Elf32 or Elf64.
 * libelf defines them as Elf64_* under the hood; we follow that
 * convention so Elf2Mac's code (which reads things like ehdr.e_shstrndx
 * directly) keeps working. */
typedef Elf64_Ehdr  GElf_Ehdr;
typedef Elf64_Phdr  GElf_Phdr;
typedef Elf64_Shdr  GElf_Shdr;
typedef Elf64_Sym   GElf_Sym;
typedef Elf64_Rela  GElf_Rela;
typedef Elf64_Rel   GElf_Rel;

/* Relocation info extraction. gelf_getrela encodes r_info as
 * (sym << 32) | type — matching ELF64 convention — so these are
 * just the standard ELF64 macros. */
#ifndef GELF_R_SYM
#define GELF_R_SYM(info)   ELF64_R_SYM(info)
#define GELF_R_TYPE(info)  ELF64_R_TYPE(info)
#define GELF_R_INFO(sym, type) ELF64_R_INFO(sym, type)
#endif

/* Symbol info extraction (ST_BIND / ST_TYPE on the 8-bit st_info). */
#ifndef GELF_ST_BIND
#define GELF_ST_BIND(info)  ELF64_ST_BIND(info)
#define GELF_ST_TYPE(info)  ELF64_ST_TYPE(info)
#define GELF_ST_INFO(b, t)  ELF64_ST_INFO(b, t)
#endif

#ifdef __cplusplus
extern "C" {
#endif

/* Library init / error reporting. */
unsigned int elf_version(unsigned int version);
const char  *elf_errmsg(int err);

/* Open + close. */
Elf      *elf_begin(int fildes, Elf_Cmd cmd, Elf *ref);
int       elf_end(Elf *elf);

/* Header navigation. */
int       elf_getshdrstrndx(Elf *elf, size_t *dst);

/* Section iteration + data. */
Elf_Scn  *elf_nextscn(Elf *elf, Elf_Scn *scn);
Elf_Data *elf_getdata(Elf_Scn *scn, Elf_Data *data);

/* String table read. */
char     *elf_strptr(Elf *elf, size_t section_index, size_t offset);

/* GElf converters — read class-specific header into the wider
 * GElf_* (class-independent) form. */
GElf_Ehdr *gelf_getehdr(Elf *elf, GElf_Ehdr *dst);
GElf_Shdr *gelf_getshdr(Elf_Scn *scn, GElf_Shdr *dst);
GElf_Sym  *gelf_getsym (Elf_Data *data, int idx, GElf_Sym  *dst);
GElf_Rela *gelf_getrela(Elf_Data *data, int idx, GElf_Rela *dst);

#ifdef __cplusplus
}
#endif

#endif /* MINIMAL_ELF_H */
