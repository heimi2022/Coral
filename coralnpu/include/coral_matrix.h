#ifndef CORAL_MATRIX_H_
#define CORAL_MATRIX_H_

#include <stdint.h>

/*
 * CoralNPU matrix instructions use the standard RISC-V custom-0 opcode.
 * This header is a C bring-up interface; it does not require gas support for
 * Coral mnemonics and emits the frozen instruction words directly.
 */
#define CORAL_MATRIX_OPCODE 0x2bU

#define CORAL_MATRIX_PUT(value, shift) ((unsigned)(value) << (shift))
#define CORAL_MATRIX_BASE(func, uop) \
  (CORAL_MATRIX_OPCODE | CORAL_MATRIX_PUT((func), 28) | \
   CORAL_MATRIX_PUT((uop), 26))

#define CORAL_MATRIX_REQUIRE_CONST_RANGE(value, maximum) \
  ((void)sizeof(char[((__builtin_constant_p(value) && \
                      ((value) >= 0) && ((value) <= (maximum))) ? 1 : -1)]))

#define CORAL_MATRIX_REQUIRE_CONST(condition) \
  ((void)sizeof(char[((__builtin_constant_p(condition) && (condition)) ? \
                      1 : -1)]))

#define CORAL_MATRIX_EMIT(word) \
  __asm__ volatile(".word %0" : : "i"(word) : "memory")

/*
 * Matrix register field values.  A and B use fields 0..3; C uses fields 4..7
 * in the frozen encoding.  The M names expose the raw 3-bit field for APIs
 * that need a whole matrix register.
 */
#define CORAL_A0 0
#define CORAL_A1 1
#define CORAL_A2 2
#define CORAL_A3 3
#define CORAL_B0 0
#define CORAL_B1 1
#define CORAL_B2 2
#define CORAL_B3 3
#define CORAL_C0 4
#define CORAL_C1 5
#define CORAL_C2 6
#define CORAL_C3 7
#define CORAL_M0 0
#define CORAL_M1 1
#define CORAL_M2 2
#define CORAL_M3 3
#define CORAL_M4 4
#define CORAL_M5 5
#define CORAL_M6 6
#define CORAL_M7 7

/* Immediate tile-shape configuration. */
#define coral_msettileki(value) do {                         \
  CORAL_MATRIX_REQUIRE_CONST_RANGE((value), 0x3ff);         \
  CORAL_MATRIX_EMIT(CORAL_MATRIX_BASE(1, 0) |                \
                    CORAL_MATRIX_PUT((value), 15));         \
} while (0)

#define coral_msettilemi(value) do {                         \
  CORAL_MATRIX_REQUIRE_CONST_RANGE((value), 0x3ff);         \
  CORAL_MATRIX_EMIT(CORAL_MATRIX_BASE(2, 0) |                \
                    CORAL_MATRIX_PUT((value), 15));         \
} while (0)

#define coral_msettileni(value) do {                         \
  CORAL_MATRIX_REQUIRE_CONST_RANGE((value), 0x3ff);         \
  CORAL_MATRIX_EMIT(CORAL_MATRIX_BASE(3, 0) |                \
                    CORAL_MATRIX_PUT((value), 15));         \
} while (0)

/*
 * Register-source configuration uses the fixed ABI registers a0/a1 for the
 * runtime value.  The instruction encoding names x10 (a0) as rs1.
 */
#define CORAL_MATRIX_CONFIG_REG_WORD(func) \
  (CORAL_MATRIX_BASE((func), 0) | CORAL_MATRIX_PUT(1, 25) | \
   CORAL_MATRIX_PUT(10, 15))

#define CORAL_MATRIX_EMIT_CONFIG_VALUE(func, value) do {     \
  __asm__ volatile(                                          \
      "mv a0, %0\n\t"                                     \
      ".word %1"                                            \
      :                                                      \
      : "r"(value), "i"(CORAL_MATRIX_CONFIG_REG_WORD(func)) \
      : "a0", "memory");                                   \
} while (0)

#define coral_msettilek(value) CORAL_MATRIX_EMIT_CONFIG_VALUE(1, (value))
#define coral_msettilem(value) CORAL_MATRIX_EMIT_CONFIG_VALUE(2, (value))
#define coral_msettilen(value) CORAL_MATRIX_EMIT_CONFIG_VALUE(3, (value))

/*
 * Matrix memory operations use a runtime base address and byte stride.  The
 * frozen C ABI moves those operands to a0/a1, then emits the instruction with
 * those fixed scalar register fields.  Matrix register fields remain compile-
 * time constants so the instruction word is still fully determined by the
 * source.
 */
#define CORAL_MATRIX_MEMORY_WORD(func, store, elem_width, matrix_reg) \
  (CORAL_MATRIX_BASE((func), 1) | CORAL_MATRIX_PUT((store), 25) | \
   CORAL_MATRIX_PUT(11, 20) | CORAL_MATRIX_PUT(10, 15) | \
   CORAL_MATRIX_PUT((elem_width), 10) | \
   CORAL_MATRIX_PUT((matrix_reg), 7))

#define CORAL_MATRIX_MEMORY_EMIT(func, store, elem_width, matrix_reg, \
                                 base, stride) do {                  \
  CORAL_MATRIX_REQUIRE_CONST_RANGE((func), 6);                      \
  CORAL_MATRIX_REQUIRE_CONST_RANGE((store), 1);                     \
  CORAL_MATRIX_REQUIRE_CONST_RANGE((elem_width), 3);                \
  CORAL_MATRIX_REQUIRE_CONST_RANGE((matrix_reg), 7);                \
  __asm__ volatile(                                                  \
      "mv a0, %0\n\t"                                             \
      "mv a1, %1\n\t"                                             \
      ".word %2"                                                     \
      :                                                              \
      : "r"(base), "r"(stride),                                    \
        "i"(CORAL_MATRIX_MEMORY_WORD((func), (store),              \
                                      (elem_width), (matrix_reg)))   \
      : "a0", "a1", "memory");                                    \
} while (0)

#define CORAL_MATRIX_TILE_MEMORY_EMIT(func, store, elem_width, matrix_reg, \
                                      base, stride) do {               \
  CORAL_MATRIX_REQUIRE_CONST((matrix_reg) <= 3);                       \
  CORAL_MATRIX_MEMORY_EMIT((func), (store), (elem_width),              \
                           (matrix_reg), (base), (stride));            \
} while (0)

#define CORAL_MATRIX_ACC_MEMORY_EMIT(func, store, elem_width, matrix_reg, \
                                     base, stride) do {                \
  CORAL_MATRIX_REQUIRE_CONST((matrix_reg) >= 4 && (matrix_reg) <= 7); \
  CORAL_MATRIX_MEMORY_EMIT((func), (store), (elem_width),              \
                           (matrix_reg), (base), (stride));            \
} while (0)

/* A tile register load/store.  Stride is measured in bytes. */
#define coral_mlae8(reg, base, stride) \
  CORAL_MATRIX_TILE_MEMORY_EMIT(0, 0, 0, (reg), (base), (stride))
#define coral_mlae16(reg, base, stride) \
  CORAL_MATRIX_TILE_MEMORY_EMIT(0, 0, 1, (reg), (base), (stride))
#define coral_mlae32(reg, base, stride) \
  CORAL_MATRIX_TILE_MEMORY_EMIT(0, 0, 2, (reg), (base), (stride))
#define coral_mlae64(reg, base, stride) \
  CORAL_MATRIX_TILE_MEMORY_EMIT(0, 0, 3, (reg), (base), (stride))
#define coral_msae8(reg, base, stride) \
  CORAL_MATRIX_TILE_MEMORY_EMIT(0, 1, 0, (reg), (base), (stride))
#define coral_msae16(reg, base, stride) \
  CORAL_MATRIX_TILE_MEMORY_EMIT(0, 1, 1, (reg), (base), (stride))
#define coral_msae32(reg, base, stride) \
  CORAL_MATRIX_TILE_MEMORY_EMIT(0, 1, 2, (reg), (base), (stride))
#define coral_msae64(reg, base, stride) \
  CORAL_MATRIX_TILE_MEMORY_EMIT(0, 1, 3, (reg), (base), (stride))

/* B tile register load/store. */
#define coral_mlbe8(reg, base, stride) \
  CORAL_MATRIX_TILE_MEMORY_EMIT(1, 0, 0, (reg), (base), (stride))
#define coral_mlbe16(reg, base, stride) \
  CORAL_MATRIX_TILE_MEMORY_EMIT(1, 0, 1, (reg), (base), (stride))
#define coral_mlbe32(reg, base, stride) \
  CORAL_MATRIX_TILE_MEMORY_EMIT(1, 0, 2, (reg), (base), (stride))
#define coral_mlbe64(reg, base, stride) \
  CORAL_MATRIX_TILE_MEMORY_EMIT(1, 0, 3, (reg), (base), (stride))
#define coral_msbe8(reg, base, stride) \
  CORAL_MATRIX_TILE_MEMORY_EMIT(1, 1, 0, (reg), (base), (stride))
#define coral_msbe16(reg, base, stride) \
  CORAL_MATRIX_TILE_MEMORY_EMIT(1, 1, 1, (reg), (base), (stride))
#define coral_msbe32(reg, base, stride) \
  CORAL_MATRIX_TILE_MEMORY_EMIT(1, 1, 2, (reg), (base), (stride))
#define coral_msbe64(reg, base, stride) \
  CORAL_MATRIX_TILE_MEMORY_EMIT(1, 1, 3, (reg), (base), (stride))

/* C accumulation register load/store. */
#define coral_mlce8(reg, base, stride) \
  CORAL_MATRIX_ACC_MEMORY_EMIT(2, 0, 0, (reg), (base), (stride))
#define coral_mlce16(reg, base, stride) \
  CORAL_MATRIX_ACC_MEMORY_EMIT(2, 0, 1, (reg), (base), (stride))
#define coral_mlce32(reg, base, stride) \
  CORAL_MATRIX_ACC_MEMORY_EMIT(2, 0, 2, (reg), (base), (stride))
#define coral_mlce64(reg, base, stride) \
  CORAL_MATRIX_ACC_MEMORY_EMIT(2, 0, 3, (reg), (base), (stride))
#define coral_msce8(reg, base, stride) \
  CORAL_MATRIX_ACC_MEMORY_EMIT(2, 1, 0, (reg), (base), (stride))
#define coral_msce16(reg, base, stride) \
  CORAL_MATRIX_ACC_MEMORY_EMIT(2, 1, 1, (reg), (base), (stride))
#define coral_msce32(reg, base, stride) \
  CORAL_MATRIX_ACC_MEMORY_EMIT(2, 1, 2, (reg), (base), (stride))
#define coral_msce64(reg, base, stride) \
  CORAL_MATRIX_ACC_MEMORY_EMIT(2, 1, 3, (reg), (base), (stride))

/* Whole matrix register load/store; rs2 is fixed to x0 by the encoding. */
#define CORAL_MATRIX_WHOLE_MEMORY_WORD(store, elem_width, matrix_reg) \
  (CORAL_MATRIX_MEMORY_WORD(3, (store), (elem_width), (matrix_reg)) & \
   ~(CORAL_MATRIX_PUT(0x1f, 20)))
#define CORAL_MATRIX_WHOLE_MEMORY_EMIT(store, elem_width, matrix_reg, \
                                       base) do {                     \
  CORAL_MATRIX_REQUIRE_CONST_RANGE((store), 1);                      \
  CORAL_MATRIX_REQUIRE_CONST_RANGE((elem_width), 3);                 \
  CORAL_MATRIX_REQUIRE_CONST_RANGE((matrix_reg), 7);                 \
  __asm__ volatile(                                                   \
      "mv a0, %0\n\t"                                              \
      ".word %1"                                                      \
      :                                                               \
      : "r"(base),                                                    \
        "i"(CORAL_MATRIX_WHOLE_MEMORY_WORD((store), (elem_width),    \
                                            (matrix_reg)))            \
      : "a0", "memory");                                             \
} while (0)

#define coral_mlme8(reg, base) \
  CORAL_MATRIX_WHOLE_MEMORY_EMIT(0, 0, (reg), (base))
#define coral_mlme16(reg, base) \
  CORAL_MATRIX_WHOLE_MEMORY_EMIT(0, 1, (reg), (base))
#define coral_mlme32(reg, base) \
  CORAL_MATRIX_WHOLE_MEMORY_EMIT(0, 2, (reg), (base))
#define coral_mlme64(reg, base) \
  CORAL_MATRIX_WHOLE_MEMORY_EMIT(0, 3, (reg), (base))
#define coral_msme8(reg, base) \
  CORAL_MATRIX_WHOLE_MEMORY_EMIT(1, 0, (reg), (base))
#define coral_msme16(reg, base) \
  CORAL_MATRIX_WHOLE_MEMORY_EMIT(1, 1, (reg), (base))
#define coral_msme32(reg, base) \
  CORAL_MATRIX_WHOLE_MEMORY_EMIT(1, 2, (reg), (base))
#define coral_msme64(reg, base) \
  CORAL_MATRIX_WHOLE_MEMORY_EMIT(1, 3, (reg), (base))

/* Transposed A/B/C tile load/store. */
#define coral_mlate8(reg, base, stride) \
  CORAL_MATRIX_TILE_MEMORY_EMIT(4, 0, 0, (reg), (base), (stride))
#define coral_mlate16(reg, base, stride) \
  CORAL_MATRIX_TILE_MEMORY_EMIT(4, 0, 1, (reg), (base), (stride))
#define coral_mlate32(reg, base, stride) \
  CORAL_MATRIX_TILE_MEMORY_EMIT(4, 0, 2, (reg), (base), (stride))
#define coral_mlate64(reg, base, stride) \
  CORAL_MATRIX_TILE_MEMORY_EMIT(4, 0, 3, (reg), (base), (stride))
#define coral_msate8(reg, base, stride) \
  CORAL_MATRIX_TILE_MEMORY_EMIT(4, 1, 0, (reg), (base), (stride))
#define coral_msate16(reg, base, stride) \
  CORAL_MATRIX_TILE_MEMORY_EMIT(4, 1, 1, (reg), (base), (stride))
#define coral_msate32(reg, base, stride) \
  CORAL_MATRIX_TILE_MEMORY_EMIT(4, 1, 2, (reg), (base), (stride))
#define coral_msate64(reg, base, stride) \
  CORAL_MATRIX_TILE_MEMORY_EMIT(4, 1, 3, (reg), (base), (stride))

#define coral_mlbte8(reg, base, stride) \
  CORAL_MATRIX_TILE_MEMORY_EMIT(5, 0, 0, (reg), (base), (stride))
#define coral_mlbte16(reg, base, stride) \
  CORAL_MATRIX_TILE_MEMORY_EMIT(5, 0, 1, (reg), (base), (stride))
#define coral_mlbte32(reg, base, stride) \
  CORAL_MATRIX_TILE_MEMORY_EMIT(5, 0, 2, (reg), (base), (stride))
#define coral_mlbte64(reg, base, stride) \
  CORAL_MATRIX_TILE_MEMORY_EMIT(5, 0, 3, (reg), (base), (stride))
#define coral_msbte8(reg, base, stride) \
  CORAL_MATRIX_TILE_MEMORY_EMIT(5, 1, 0, (reg), (base), (stride))
#define coral_msbte16(reg, base, stride) \
  CORAL_MATRIX_TILE_MEMORY_EMIT(5, 1, 1, (reg), (base), (stride))
#define coral_msbte32(reg, base, stride) \
  CORAL_MATRIX_TILE_MEMORY_EMIT(5, 1, 2, (reg), (base), (stride))
#define coral_msbte64(reg, base, stride) \
  CORAL_MATRIX_TILE_MEMORY_EMIT(5, 1, 3, (reg), (base), (stride))

#define coral_mlcte8(reg, base, stride) \
  CORAL_MATRIX_ACC_MEMORY_EMIT(6, 0, 0, (reg), (base), (stride))
#define coral_mlcte16(reg, base, stride) \
  CORAL_MATRIX_ACC_MEMORY_EMIT(6, 0, 1, (reg), (base), (stride))
#define coral_mlcte32(reg, base, stride) \
  CORAL_MATRIX_ACC_MEMORY_EMIT(6, 0, 2, (reg), (base), (stride))
#define coral_mlcte64(reg, base, stride) \
  CORAL_MATRIX_ACC_MEMORY_EMIT(6, 0, 3, (reg), (base), (stride))
#define coral_mscte8(reg, base, stride) \
  CORAL_MATRIX_ACC_MEMORY_EMIT(6, 1, 0, (reg), (base), (stride))
#define coral_mscte16(reg, base, stride) \
  CORAL_MATRIX_ACC_MEMORY_EMIT(6, 1, 1, (reg), (base), (stride))
#define coral_mscte32(reg, base, stride) \
  CORAL_MATRIX_ACC_MEMORY_EMIT(6, 1, 2, (reg), (base), (stride))
#define coral_mscte64(reg, base, stride) \
  CORAL_MATRIX_ACC_MEMORY_EMIT(6, 1, 3, (reg), (base), (stride))

/* mzero uses uop=11 and count codes 0, 1, 3, and 7 for 1, 2, 4, and 8. */
#define CORAL_MATRIX_MZERO(count_code, md)                    \
  (CORAL_MATRIX_BASE(0, 3) | CORAL_MATRIX_PUT((count_code), 23) | \
   CORAL_MATRIX_PUT((md), 7))

#define CORAL_MATRIX_ZERO(count_code, md) do {                \
  CORAL_MATRIX_REQUIRE_CONST_RANGE((count_code), 7);          \
  CORAL_MATRIX_REQUIRE_CONST_RANGE((md), 7);                  \
  CORAL_MATRIX_REQUIRE_CONST(                                  \
      ((count_code) == 0) || ((count_code) == 1) ||           \
      ((count_code) == 3) || ((count_code) == 7));             \
  CORAL_MATRIX_REQUIRE_CONST(                                  \
      ((count_code) == 0) ||                                  \
      ((count_code) == 1 && ((md) % 2) == 0) ||               \
      ((count_code) == 3 && ((md) % 4) == 0) ||               \
      ((count_code) == 7 && ((md) % 8) == 0));                \
  CORAL_MATRIX_EMIT(CORAL_MATRIX_MZERO((count_code), (md))); \
} while (0)

#define coral_mzero(md) CORAL_MATRIX_ZERO(0, (md))
#define coral_mzero2r(md) CORAL_MATRIX_ZERO(1, (md))
#define coral_mzero4r(md) CORAL_MATRIX_ZERO(3, (md))
#define coral_mzero8r(md) CORAL_MATRIX_ZERO(7, (md))

/* Matrix multiply uses uop=10 and fixed func=1. */
#define CORAL_MATRIX_MATMUL(size_sup, ms2, ms1, md)            \
  (CORAL_MATRIX_BASE(1, 2) | CORAL_MATRIX_PUT((size_sup), 23) | \
   CORAL_MATRIX_PUT((ms2), 20) | CORAL_MATRIX_PUT((ms1), 15) | \
   CORAL_MATRIX_PUT(2, 10) | CORAL_MATRIX_PUT((md), 7))

#define CORAL_MATRIX_MATMUL_EMIT(size_sup, md, ms2, ms1) do {  \
  CORAL_MATRIX_REQUIRE_CONST_RANGE((md), 7);                  \
  CORAL_MATRIX_REQUIRE_CONST_RANGE((ms2), 7);                 \
  CORAL_MATRIX_REQUIRE_CONST_RANGE((ms1), 7);                 \
  CORAL_MATRIX_EMIT(CORAL_MATRIX_MATMUL((size_sup), (ms2),    \
                                        (ms1), (md)));        \
} while (0)

#define coral_mmacc_w_b(md, ms2, ms1) \
  CORAL_MATRIX_MATMUL_EMIT(3, (md), (ms2), (ms1))
#define coral_mmaccu_w_b(md, ms2, ms1) \
  CORAL_MATRIX_MATMUL_EMIT(0, (md), (ms2), (ms1))
#define coral_mmaccus_w_b(md, ms2, ms1) \
  CORAL_MATRIX_MATMUL_EMIT(1, (md), (ms2), (ms1))
#define coral_mmaccsu_w_b(md, ms2, ms1) \
  CORAL_MATRIX_MATMUL_EMIT(2, (md), (ms2), (ms1))

#endif
