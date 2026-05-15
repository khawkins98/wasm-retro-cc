# MinimalElf — a libelf replacement for Elf2Mac wasm build.
# See MinimalElf.h for rationale.

add_library(MinimalElf STATIC MinimalElf.cc)
target_include_directories(MinimalElf PUBLIC ${CMAKE_CURRENT_SOURCE_DIR})
set_target_properties(MinimalElf PROPERTIES CXX_STANDARD 17)
