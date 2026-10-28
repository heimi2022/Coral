#include "include/coral_matrix_gemm.h"

/* The same four-C-register schedule as the large test, with a shorter run. */
int main(void) {
  return coral_gemm_mx_multicreg(
      (const int8_t *)(uintptr_t)0x80000000U, 128 * sizeof(int8_t),
      (const int8_t *)(uintptr_t)0x80010000U, 128 * sizeof(int8_t),
      (const uint8_t *)(uintptr_t)0x80020000U, 512,
      (const uint8_t *)(uintptr_t)0x80021000U, 512,
      (float *)(uintptr_t)0x80040000U, 256 * sizeof(float),
      64, 256, 64);
}
