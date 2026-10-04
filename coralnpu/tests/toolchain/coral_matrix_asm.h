#ifndef CORAL_MATRIX_ASM_H_
#define CORAL_MATRIX_ASM_H_

/*
 * Low-level CoralNPU matrix instruction emission.
 *
 * The operands are architectural register numbers, not C matrix objects.
 * All arguments must be compile-time constants.  This header intentionally
 * emits .word values because the host RISC-V assembler does not know the
 * CoralNPU matrix mnemonics yet.
 */

#define CORAL_MATRIX_OPCODE 0x2bU

#define CORAL_MATRIX_PUT(value, shift) ((unsigned)(value) << (shift))
#define CORAL_MATRIX_BASE(func, uop) \
    (CORAL_MATRIX_OPCODE | CORAL_MATRIX_PUT((func), 28) | \
     CORAL_MATRIX_PUT((uop), 26))

#define CORAL_MATRIX_REQUIRE_CONST_RANGE(value, maximum) \
    ((void)sizeof(char[(                                    \
        __builtin_constant_p(value) &&                     \
        ((value) >= 0) && ((value) <= (maximum))) ? 1 : -1]))

#define CORAL_MATRIX_REQUIRE_CONST(condition) \
    ((void)sizeof(char[(                                  \
        __builtin_constant_p(condition) && (condition)) ? 1 : -1]))

#define CORAL_MATRIX_EMIT(word) \
    __asm__ volatile(".word %0" : : "i"(word) : "memory")

#define CORAL_MATRIX_CONFIG_IMM(func, value) \
    (CORAL_MATRIX_BASE((func), 0) | CORAL_MATRIX_PUT((value), 15))

#define CORAL_MATRIX_CONFIG_REG(func, rs1) \
    (CORAL_MATRIX_BASE((func), 0) | CORAL_MATRIX_PUT(1, 25) | \
     CORAL_MATRIX_PUT((rs1), 15))

#define coral_msettileki(value) do {                         \
    CORAL_MATRIX_REQUIRE_CONST_RANGE((value), 0x3ff);       \
    CORAL_MATRIX_EMIT(CORAL_MATRIX_CONFIG_IMM(1, (value))); \
} while (0)

#define coral_msettilemi(value) do {                         \
    CORAL_MATRIX_REQUIRE_CONST_RANGE((value), 0x3ff);       \
    CORAL_MATRIX_EMIT(CORAL_MATRIX_CONFIG_IMM(2, (value))); \
} while (0)

#define coral_msettileni(value) do {                         \
    CORAL_MATRIX_REQUIRE_CONST_RANGE((value), 0x3ff);       \
    CORAL_MATRIX_EMIT(CORAL_MATRIX_CONFIG_IMM(3, (value))); \
} while (0)

#define coral_msettilek_reg(rs1) do {                        \
    CORAL_MATRIX_REQUIRE_CONST_RANGE((rs1), 31);            \
    CORAL_MATRIX_EMIT(CORAL_MATRIX_CONFIG_REG(1, (rs1)));  \
} while (0)

#define coral_msettilem_reg(rs1) do {                        \
    CORAL_MATRIX_REQUIRE_CONST_RANGE((rs1), 31);            \
    CORAL_MATRIX_EMIT(CORAL_MATRIX_CONFIG_REG(2, (rs1)));  \
} while (0)

#define coral_msettilen_reg(rs1) do {                        \
    CORAL_MATRIX_REQUIRE_CONST_RANGE((rs1), 31);            \
    CORAL_MATRIX_EMIT(CORAL_MATRIX_CONFIG_REG(3, (rs1)));  \
} while (0)

#define CORAL_MATRIX_MZERO(count_code, md)                   \
    (CORAL_MATRIX_BASE(0, 3) | CORAL_MATRIX_PUT((count_code), 23) | \
     CORAL_MATRIX_PUT((md), 7))

#define coral_mzero(count_code, md) do {                     \
    CORAL_MATRIX_REQUIRE_CONST_RANGE((count_code), 7);      \
    CORAL_MATRIX_REQUIRE_CONST_RANGE((md), 7);              \
    CORAL_MATRIX_REQUIRE_CONST(                              \
        ((count_code) == 0) || ((count_code) == 1) ||       \
        ((count_code) == 3) || ((count_code) == 7));        \
    CORAL_MATRIX_REQUIRE_CONST(                              \
        ((count_code) == 0) ||                              \
        ((count_code) == 1 && ((md) % 2) == 0) ||           \
        ((count_code) == 3 && ((md) % 4) == 0) ||           \
        ((count_code) == 7 && ((md) % 8) == 0));            \
    CORAL_MATRIX_EMIT(CORAL_MATRIX_MZERO((count_code), (md))); \
} while (0)

#define CORAL_MATRIX_MZERO_ONE(md) coral_mzero(0, (md))
#define CORAL_MATRIX_MZERO_TWO(md) coral_mzero(1, (md))
#define CORAL_MATRIX_MZERO_FOUR(md) coral_mzero(3, (md))
#define CORAL_MATRIX_MZERO_EIGHT(md) coral_mzero(7, (md))

#define CORAL_MATRIX_MATMUL(size_sup, ms2, ms1, md)          \
    (CORAL_MATRIX_BASE(1, 2) | CORAL_MATRIX_PUT((size_sup), 23) | \
     CORAL_MATRIX_PUT((ms2), 20) | CORAL_MATRIX_PUT((ms1), 15) | \
     CORAL_MATRIX_PUT(2, 10) | CORAL_MATRIX_PUT((md), 7))

#define coral_mmacc_w_b(ms2, ms1, md) do {                   \
    CORAL_MATRIX_REQUIRE_CONST_RANGE((ms2), 7);             \
    CORAL_MATRIX_REQUIRE_CONST_RANGE((ms1), 7);             \
    CORAL_MATRIX_REQUIRE_CONST_RANGE((md), 7);              \
    CORAL_MATRIX_EMIT(CORAL_MATRIX_MATMUL(3, (ms2), (ms1), (md))); \
} while (0)

#define coral_mmaccu_w_b(ms2, ms1, md) do {                  \
    CORAL_MATRIX_REQUIRE_CONST_RANGE((ms2), 7);             \
    CORAL_MATRIX_REQUIRE_CONST_RANGE((ms1), 7);             \
    CORAL_MATRIX_REQUIRE_CONST_RANGE((md), 7);              \
    CORAL_MATRIX_EMIT(CORAL_MATRIX_MATMUL(0, (ms2), (ms1), (md))); \
} while (0)

#define coral_mmaccus_w_b(ms2, ms1, md) do {                 \
    CORAL_MATRIX_REQUIRE_CONST_RANGE((ms2), 7);             \
    CORAL_MATRIX_REQUIRE_CONST_RANGE((ms1), 7);             \
    CORAL_MATRIX_REQUIRE_CONST_RANGE((md), 7);              \
    CORAL_MATRIX_EMIT(CORAL_MATRIX_MATMUL(1, (ms2), (ms1), (md))); \
} while (0)

#define coral_mmaccsu_w_b(ms2, ms1, md) do {                 \
    CORAL_MATRIX_REQUIRE_CONST_RANGE((ms2), 7);             \
    CORAL_MATRIX_REQUIRE_CONST_RANGE((ms1), 7);             \
    CORAL_MATRIX_REQUIRE_CONST_RANGE((md), 7);              \
    CORAL_MATRIX_EMIT(CORAL_MATRIX_MATMUL(2, (ms2), (ms1), (md))); \
} while (0)

#define CORAL_MATRIX_MEMORY(family, store, elem_width, rs1, rs2, reg) \
    (CORAL_MATRIX_BASE((family), 1) | CORAL_MATRIX_PUT((store), 25) | \
     CORAL_MATRIX_PUT((rs2), 20) | CORAL_MATRIX_PUT((rs1), 15) | \
     CORAL_MATRIX_PUT((elem_width), 10) | CORAL_MATRIX_PUT((reg), 7))

#define CORAL_MATRIX_MEMORY_EMIT(family, store, elem_width, rs1, rs2, reg) do { \
    CORAL_MATRIX_REQUIRE_CONST_RANGE((family), 6);         \
    CORAL_MATRIX_REQUIRE_CONST_RANGE((store), 1);          \
    CORAL_MATRIX_REQUIRE_CONST_RANGE((elem_width), 3);     \
    CORAL_MATRIX_REQUIRE_CONST_RANGE((rs1), 31);           \
    CORAL_MATRIX_REQUIRE_CONST_RANGE((rs2), 31);           \
    CORAL_MATRIX_REQUIRE_CONST_RANGE((reg), 7);            \
    CORAL_MATRIX_REQUIRE_CONST(((family) != 3) || ((rs2) == 0)); \
    CORAL_MATRIX_EMIT(CORAL_MATRIX_MEMORY((family), (store), \
                                          (elem_width), (rs1), (rs2), (reg))); \
} while (0)

#define coral_mld_a(elem_width, rs1, rs2, reg) \
    CORAL_MATRIX_MEMORY_EMIT(0, 0, (elem_width), (rs1), (rs2), (reg))
#define coral_mst_a(elem_width, rs1, rs2, reg) \
    CORAL_MATRIX_MEMORY_EMIT(0, 1, (elem_width), (rs1), (rs2), (reg))
#define coral_mld_b(elem_width, rs1, rs2, reg) \
    CORAL_MATRIX_MEMORY_EMIT(1, 0, (elem_width), (rs1), (rs2), (reg))
#define coral_mst_b(elem_width, rs1, rs2, reg) \
    CORAL_MATRIX_MEMORY_EMIT(1, 1, (elem_width), (rs1), (rs2), (reg))
#define coral_mld_c(elem_width, rs1, rs2, reg) \
    CORAL_MATRIX_MEMORY_EMIT(2, 0, (elem_width), (rs1), (rs2), (reg))
#define coral_mst_c(elem_width, rs1, rs2, reg) \
    CORAL_MATRIX_MEMORY_EMIT(2, 1, (elem_width), (rs1), (rs2), (reg))

#endif
