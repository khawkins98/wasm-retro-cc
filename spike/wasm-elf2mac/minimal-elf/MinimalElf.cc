/* MinimalElf.cc — implementation. See MinimalElf.h for rationale.
 *
 * Reads the file once at elf_begin (file → in-memory buffer); all
 * subsequent operations are zero-copy views into that buffer.
 * Byteswaps Elf32 fields from big-endian source to host-endian on
 * each read (m68k ELF is BE; our wasm host is LE).
 *
 * Assumptions enforced at elf_begin:
 *  - ELFCLASS32 (m68k targets — bail otherwise)
 *  - ELFDATA2MSB (big-endian — bail otherwise)
 *  - Valid ELF magic
 */

#include "MinimalElf.h"

#include <unistd.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <fcntl.h>
#include <string.h>
#include <stdio.h>
#include <stdlib.h>

#include <vector>
#include <string>

namespace {

/* Byteswap helpers. m68k ELF source is big-endian; wasm host is LE.
 * These read directly from the source buffer with correct endian
 * conversion. */
uint16_t be16(const uint8_t *p) {
  return (uint16_t(p[0]) << 8) | uint16_t(p[1]);
}
uint32_t be32(const uint8_t *p) {
  return (uint32_t(p[0]) << 24) | (uint32_t(p[1]) << 16) |
         (uint32_t(p[2]) <<  8) |  uint32_t(p[3]);
}

/* In-place Elf32_* swap into host byte order. Performed once on
 * Elf_begin for the file header, and lazily for section headers /
 * symbols / relas in the gelf_get*() converters. We do NOT mutate
 * the source buffer — copies-into-locals only. */
void swap_ehdr32(const Elf32_Ehdr &src, Elf32_Ehdr &dst) {
  /* e_ident is byte-array, no swap. */
  memcpy(dst.e_ident, src.e_ident, EI_NIDENT);
  dst.e_type      = be16(reinterpret_cast<const uint8_t *>(&src.e_type));
  dst.e_machine   = be16(reinterpret_cast<const uint8_t *>(&src.e_machine));
  dst.e_version   = be32(reinterpret_cast<const uint8_t *>(&src.e_version));
  dst.e_entry     = be32(reinterpret_cast<const uint8_t *>(&src.e_entry));
  dst.e_phoff     = be32(reinterpret_cast<const uint8_t *>(&src.e_phoff));
  dst.e_shoff     = be32(reinterpret_cast<const uint8_t *>(&src.e_shoff));
  dst.e_flags     = be32(reinterpret_cast<const uint8_t *>(&src.e_flags));
  dst.e_ehsize    = be16(reinterpret_cast<const uint8_t *>(&src.e_ehsize));
  dst.e_phentsize = be16(reinterpret_cast<const uint8_t *>(&src.e_phentsize));
  dst.e_phnum     = be16(reinterpret_cast<const uint8_t *>(&src.e_phnum));
  dst.e_shentsize = be16(reinterpret_cast<const uint8_t *>(&src.e_shentsize));
  dst.e_shnum     = be16(reinterpret_cast<const uint8_t *>(&src.e_shnum));
  dst.e_shstrndx  = be16(reinterpret_cast<const uint8_t *>(&src.e_shstrndx));
}

void swap_shdr32(const Elf32_Shdr &src, Elf32_Shdr &dst) {
  dst.sh_name      = be32(reinterpret_cast<const uint8_t *>(&src.sh_name));
  dst.sh_type      = be32(reinterpret_cast<const uint8_t *>(&src.sh_type));
  dst.sh_flags     = be32(reinterpret_cast<const uint8_t *>(&src.sh_flags));
  dst.sh_addr      = be32(reinterpret_cast<const uint8_t *>(&src.sh_addr));
  dst.sh_offset    = be32(reinterpret_cast<const uint8_t *>(&src.sh_offset));
  dst.sh_size      = be32(reinterpret_cast<const uint8_t *>(&src.sh_size));
  dst.sh_link      = be32(reinterpret_cast<const uint8_t *>(&src.sh_link));
  dst.sh_info      = be32(reinterpret_cast<const uint8_t *>(&src.sh_info));
  dst.sh_addralign = be32(reinterpret_cast<const uint8_t *>(&src.sh_addralign));
  dst.sh_entsize   = be32(reinterpret_cast<const uint8_t *>(&src.sh_entsize));
}

/* Promote Elf32 fields into Elf64-sized GElf_* fields. */
void shdr32_to_gelf(const Elf32_Shdr &src, GElf_Shdr &dst) {
  dst.sh_name      = src.sh_name;
  dst.sh_type      = src.sh_type;
  dst.sh_flags     = src.sh_flags;
  dst.sh_addr      = src.sh_addr;
  dst.sh_offset    = src.sh_offset;
  dst.sh_size      = src.sh_size;
  dst.sh_link      = src.sh_link;
  dst.sh_info      = src.sh_info;
  dst.sh_addralign = src.sh_addralign;
  dst.sh_entsize   = src.sh_entsize;
}

void ehdr32_to_gelf(const Elf32_Ehdr &src, GElf_Ehdr &dst) {
  memcpy(dst.e_ident, src.e_ident, EI_NIDENT);
  dst.e_type      = src.e_type;
  dst.e_machine   = src.e_machine;
  dst.e_version   = src.e_version;
  dst.e_entry     = src.e_entry;
  dst.e_phoff     = src.e_phoff;
  dst.e_shoff     = src.e_shoff;
  dst.e_flags     = src.e_flags;
  dst.e_ehsize    = src.e_ehsize;
  dst.e_phentsize = src.e_phentsize;
  dst.e_phnum     = src.e_phnum;
  dst.e_shentsize = src.e_shentsize;
  dst.e_shnum     = src.e_shnum;
  dst.e_shstrndx  = src.e_shstrndx;
}

void sym32_to_gelf(const Elf32_Sym &src, GElf_Sym &dst) {
  dst.st_name  = be32(reinterpret_cast<const uint8_t *>(&src.st_name));
  dst.st_value = be32(reinterpret_cast<const uint8_t *>(&src.st_value));
  dst.st_size  = be32(reinterpret_cast<const uint8_t *>(&src.st_size));
  dst.st_info  = src.st_info;    /* single byte */
  dst.st_other = src.st_other;   /* single byte */
  dst.st_shndx = be16(reinterpret_cast<const uint8_t *>(&src.st_shndx));
}

void rela32_to_gelf(const Elf32_Rela &src, GElf_Rela &dst) {
  dst.r_offset = be32(reinterpret_cast<const uint8_t *>(&src.r_offset));
  dst.r_info   = be32(reinterpret_cast<const uint8_t *>(&src.r_info));
  dst.r_addend = static_cast<int32_t>(be32(reinterpret_cast<const uint8_t *>(&src.r_addend)));
  /* GElf_Rela.r_info is 64-bit; ELF32 r_info is 32-bit. Re-encode
   * the symbol/type split so ELF64-style ELF64_R_SYM/_TYPE macros
   * give the right answers. */
  uint32_t info32 = dst.r_info;
  uint32_t sym = info32 >> 8;
  uint32_t type = info32 & 0xff;
  dst.r_info = (uint64_t(sym) << 32) | uint64_t(type);
}

} // anonymous namespace

/* ── Opaque type definitions ───────────────────────────────────── */

struct Elf_Scn_struct {
  Elf *parent;
  size_t index;            // 0-based section index
  Elf32_Shdr shdr;         // host-byte-order copy of section header
  Elf32_Shdr shdr_be;      // raw big-endian copy (for sym/rela conversion)
  std::vector<uint8_t> data_buf_cache;  // unused; we point into source buffer
  Elf_Data data;           // cached Elf_Data for elf_getdata
  bool data_valid = false;
};

struct Elf_struct {
  std::vector<uint8_t> buf; // owns the entire ELF image
  Elf32_Ehdr ehdr;          // host-byte-order copy of file header
  std::vector<Elf_Scn> sections;
};

/* ── Library API implementation ────────────────────────────────── */

unsigned int elf_version(unsigned int version) {
  (void)version;
  return EV_CURRENT;
}

const char *elf_errmsg(int err) {
  (void)err;
  static const char *msg = "MinimalElf: error (no detail)";
  return msg;
}

Elf *elf_begin(int fildes, Elf_Cmd cmd, Elf *ref) {
  (void)ref;
  if (cmd != ELF_C_READ) return nullptr;

  struct stat st;
  if (fstat(fildes, &st) != 0) return nullptr;

  Elf *e = new Elf;
  e->buf.resize(static_cast<size_t>(st.st_size));
  ssize_t got = 0;
  while (got < st.st_size) {
    ssize_t n = read(fildes, e->buf.data() + got, st.st_size - got);
    if (n <= 0) { delete e; return nullptr; }
    got += n;
  }

  if (e->buf.size() < sizeof(Elf32_Ehdr)) { delete e; return nullptr; }
  const Elf32_Ehdr *src_ehdr = reinterpret_cast<const Elf32_Ehdr *>(e->buf.data());
  if (memcmp(src_ehdr->e_ident, ELFMAG, SELFMAG) != 0) { delete e; return nullptr; }
  if (src_ehdr->e_ident[EI_CLASS] != ELFCLASS32) { delete e; return nullptr; }
  if (src_ehdr->e_ident[EI_DATA]  != ELFDATA2MSB) { delete e; return nullptr; }

  swap_ehdr32(*src_ehdr, e->ehdr);

  /* Pre-parse all section headers. */
  e->sections.resize(e->ehdr.e_shnum);
  for (size_t i = 0; i < e->ehdr.e_shnum; i++) {
    size_t off = e->ehdr.e_shoff + i * e->ehdr.e_shentsize;
    if (off + sizeof(Elf32_Shdr) > e->buf.size()) { delete e; return nullptr; }
    const Elf32_Shdr *src_shdr = reinterpret_cast<const Elf32_Shdr *>(e->buf.data() + off);
    e->sections[i].parent = e;
    e->sections[i].index = i;
    memcpy(&e->sections[i].shdr_be, src_shdr, sizeof(Elf32_Shdr));
    swap_shdr32(*src_shdr, e->sections[i].shdr);
  }

  return e;
}

int elf_end(Elf *elf) {
  delete elf;
  return 0;
}

int elf_getshdrstrndx(Elf *elf, size_t *dst) {
  if (!elf || !dst) return -1;
  *dst = elf->ehdr.e_shstrndx;
  return 0;
}

Elf_Scn *elf_nextscn(Elf *elf, Elf_Scn *scn) {
  if (!elf) return nullptr;
  size_t next_idx = scn ? scn->index + 1 : 1;  /* skip SHN_UNDEF at idx 0 */
  if (next_idx >= elf->sections.size()) return nullptr;
  return &elf->sections[next_idx];
}

Elf_Data *elf_getdata(Elf_Scn *scn, Elf_Data *prev) {
  if (!scn || prev) return nullptr;  /* only first chunk; libelf would return successive chunks for multi-buffer sections, but Elf2Mac never needs that */
  if (scn->data_valid) return &scn->data;

  const Elf32_Shdr &h = scn->shdr;
  scn->data.d_buf     = scn->parent->buf.data() + h.sh_offset;
  scn->data.d_size    = h.sh_size;
  scn->data.d_off     = 0;
  scn->data.d_align   = h.sh_addralign;
  scn->data.d_version = EV_CURRENT;
  scn->data.d_type    = ELF_T_BYTE;  /* generic — callers reinterpret */
  scn->data_valid = true;
  return &scn->data;
}

char *elf_strptr(Elf *elf, size_t section_index, size_t offset) {
  if (!elf || section_index >= elf->sections.size()) return nullptr;
  const Elf32_Shdr &h = elf->sections[section_index].shdr;
  if (offset >= h.sh_size) return nullptr;
  return reinterpret_cast<char *>(elf->buf.data() + h.sh_offset + offset);
}

GElf_Ehdr *gelf_getehdr(Elf *elf, GElf_Ehdr *dst) {
  if (!elf || !dst) return nullptr;
  ehdr32_to_gelf(elf->ehdr, *dst);
  return dst;
}

GElf_Shdr *gelf_getshdr(Elf_Scn *scn, GElf_Shdr *dst) {
  if (!scn || !dst) return nullptr;
  shdr32_to_gelf(scn->shdr, *dst);
  return dst;
}

GElf_Sym *gelf_getsym(Elf_Data *data, int idx, GElf_Sym *dst) {
  if (!data || !dst) return nullptr;
  size_t off = static_cast<size_t>(idx) * sizeof(Elf32_Sym);
  if (off + sizeof(Elf32_Sym) > data->d_size) return nullptr;
  const Elf32_Sym *src = reinterpret_cast<const Elf32_Sym *>(static_cast<const uint8_t *>(data->d_buf) + off);
  sym32_to_gelf(*src, *dst);
  return dst;
}

GElf_Rela *gelf_getrela(Elf_Data *data, int idx, GElf_Rela *dst) {
  if (!data || !dst) return nullptr;
  size_t off = static_cast<size_t>(idx) * sizeof(Elf32_Rela);
  if (off + sizeof(Elf32_Rela) > data->d_size) return nullptr;
  const Elf32_Rela *src = reinterpret_cast<const Elf32_Rela *>(static_cast<const uint8_t *>(data->d_buf) + off);
  rela32_to_gelf(*src, *dst);
  return dst;
}
