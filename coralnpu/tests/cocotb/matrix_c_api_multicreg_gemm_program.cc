#include "include/coral_matrix_gemm.h"

/*
 * Exercise the four-C-register schedule on a large GEMM:
 *
 *   A: 512 x 128, row-major S1.6 int8
 *   B: 512 x 128, transposed [N][K] S1.6 int8
 *   C: 512 x 512, row-major FP32
 *
 * The helper alternates A0/B1,B2,B3,B1 and A2/B3,B0,B1,B3 across K tiles,
 * keeping partial results in C0..C3. On the final K tile, each next B load
 * and MMACC precede the previous C store; C3 is stored last.
 * After the final odd-phase C3 MMACC, the next group's A0/B1 loads precede
 * STORE C2/C3 when their dimensions permit.
 */
int main(void) {
  return coral_gemm_mx_multicreg(
      (const int8_t *)(uintptr_t)0x80000000U, 128 * sizeof(int8_t),
      (const int8_t *)(uintptr_t)0x80010000U, 128 * sizeof(int8_t),
      (const uint8_t *)(uintptr_t)0x80020000U, 512,
      (const uint8_t *)(uintptr_t)0x80021000U, 512,
      (float *)(uintptr_t)0x80040000U, 512 * sizeof(float),
      512, 512, 128);
}
