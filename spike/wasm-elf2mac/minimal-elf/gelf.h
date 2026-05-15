/* gelf.h compat shim — points at MinimalElf.h.
 * Elf2Mac includes <gelf.h>; we redirect to our header so the wasm
 * build links against MinimalElf instead of libelf. */
#ifndef _GELF_H_SHIM
#define _GELF_H_SHIM
#include "MinimalElf.h"
#endif
