#include "include/coral_matrix_gemm.h"

/* M=64+1, N=256+1, K=64+64; keep C partial sums across both K tiles. */
int main(void) {
  return coral_gemm_mx_multicreg(
      (const int8_t *)(uintptr_t)0x00040000U, 128,
      (const int8_t *)(uintptr_t)0x00050000U, 128,
      (const uint8_t *)(uintptr_t)0x00060000U, 512,
      (const uint8_t *)(uintptr_t)0x00061000U, 512,
      (float *)(uintptr_t)0x00080000U, 1088,
      65, 257, 128);
}
