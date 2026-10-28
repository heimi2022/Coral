#include "include/coral_matrix.h"

#include <stddef.h>

/* Test-only fixed-shape kernel with B packed as [N tile][K tile][64][64]. */
#define ISSUE_PACKED_B_TILE(A_REG, B_REG, C_REG, GLOBAL_N_TILE, K_TILE,      \
                            SCALE_GROUP, CLEAR_C)                            \
  do {                                                                       \
    const size_t packed_offset =                                             \
        ((GLOBAL_N_TILE) * 2 + (K_TILE)) * 64 * 64;                          \
    const size_t n_col = (GLOBAL_N_TILE) * 64;                               \
    coral_mlbe8((B_REG), b + packed_offset, 64);                             \
    coral_mlbte8((B_REG), b_scale + (SCALE_GROUP) * 512 + n_col, 512);       \
    if (CLEAR_C) coral_mzero(C_REG);                                         \
    coral_mmacc_w_b(C_REG, (B_REG), (A_REG));                                \
  } while (0)

int main(void) {
  const int8_t *a = (const int8_t *)(uintptr_t)0x80000000U;
  const int8_t *b = (const int8_t *)(uintptr_t)0x80010000U;
  const uint8_t *a_scale = (const uint8_t *)(uintptr_t)0x80020000U;
  const uint8_t *b_scale = (const uint8_t *)(uintptr_t)0x80021000U;
  float *c = (float *)(uintptr_t)0x80040000U;

  coral_msettilem(64);
  coral_msettilen(64);
  coral_msettilek(64);
  for (size_t m0 = 0; m0 < 512; m0 += 64) {
    for (size_t n_tile = 0; n_tile < 8; n_tile += 4) {
      for (size_t k_tile = 0; k_tile < 2; ++k_tile) {
        const size_t k0 = k_tile * 64;
        const size_t scale_group = k_tile * 2;
        if (k_tile == 0) {
          coral_mlae8(CORAL_A0, a + m0 * 128, 128);
          coral_mlate8(CORAL_A0, a_scale + scale_group * 512 + m0, 512);
          ISSUE_PACKED_B_TILE(CORAL_A0, CORAL_B1, CORAL_C0, n_tile, 0,
                              scale_group, 1);
          ISSUE_PACKED_B_TILE(CORAL_A0, CORAL_B2, CORAL_C1, n_tile + 1, 0,
                              scale_group, 1);
          ISSUE_PACKED_B_TILE(CORAL_A0, CORAL_B3, CORAL_C2, n_tile + 2, 0,
                              scale_group, 1);
          ISSUE_PACKED_B_TILE(CORAL_A0, CORAL_B1, CORAL_C3, n_tile + 3, 0,
                              scale_group, 1);
        } else {
          coral_mlae8(CORAL_A2, a + m0 * 128 + k0, 128);
          coral_mlate8(CORAL_A2, a_scale + scale_group * 512 + m0, 512);
          ISSUE_PACKED_B_TILE(CORAL_A2, CORAL_B3, CORAL_C0, n_tile, 1,
                              scale_group, 0);
          ISSUE_PACKED_B_TILE(CORAL_A2, CORAL_B0, CORAL_C1, n_tile + 1, 1,
                              scale_group, 0);
          ISSUE_PACKED_B_TILE(CORAL_A2, CORAL_B1, CORAL_C2, n_tile + 2, 1,
                              scale_group, 0);
          ISSUE_PACKED_B_TILE(CORAL_A2, CORAL_B3, CORAL_C3, n_tile + 3, 1,
                              scale_group, 0);
        }
      }
      coral_msce32(CORAL_C0,
                   (void *)((uintptr_t)c + m0 * 2048 + n_tile * 256), 2048);
      coral_msce32(CORAL_C1,
                   (void *)((uintptr_t)c + m0 * 2048 + (n_tile + 1) * 256),
                   2048);
      coral_msce32(CORAL_C2,
                   (void *)((uintptr_t)c + m0 * 2048 + (n_tile + 2) * 256),
                   2048);
      coral_msce32(CORAL_C3,
                   (void *)((uintptr_t)c + m0 * 2048 + (n_tile + 3) * 256),
                   2048);
    }
  }
  return 0;
}

#undef ISSUE_PACKED_B_TILE
