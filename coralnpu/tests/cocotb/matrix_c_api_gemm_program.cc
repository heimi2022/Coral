#include "include/coral_matrix.h"
#include <stdint.h>

/*
 * A compiler-generated GEMM:
 *
 *   M=2, N=33, K=64 = K0(32) + K1(32)
 *
 * A and B are loaded once per K block. The two MMACC instructions target the
 * same C register, so this is the software-visible K accumulation sequence.
 * Scale matrices use the hardware's K-block-major layout: one 64-byte row per
 * K block, followed by the M or N scale values.
 */
int main(void) {
  const uintptr_t a = 0x80000000U;
  const uintptr_t b = 0x80002000U;
  const uintptr_t a_scale = 0x80004000U;
  const uintptr_t b_scale = 0x80005000U;
  const uintptr_t dst = 0x80006000U;

  coral_msettilemi(2);
  coral_msettileni(33);
  coral_msettileki(32);

  coral_mzero(CORAL_C0);

  coral_mlae8(CORAL_A0, (const void *)a, 64);
  coral_mlbe8(CORAL_B1, (const void *)b, 64);
  coral_mlate8(CORAL_A0, (const void *)a_scale, 64);
  coral_mlbte8(CORAL_B1, (const void *)b_scale, 64);
  coral_mmacc_w_b(CORAL_C0, CORAL_B1, CORAL_A0);

  coral_mlae8(CORAL_A0, (const void *)(a + 32), 64);
  coral_mlbe8(CORAL_B1, (const void *)(b + 32), 64);
  coral_mlate8(CORAL_A0, (const void *)(a_scale + 64), 64);
  coral_mlbte8(CORAL_B1, (const void *)(b_scale + 64), 64);
  coral_mmacc_w_b(CORAL_C0, CORAL_B1, CORAL_A0);

  coral_msce32(CORAL_C0, (void *)dst, 192);
  return 0;
}
