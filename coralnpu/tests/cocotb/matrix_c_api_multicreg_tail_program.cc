#include "include/coral_matrix_gemm.h"

/* Exercise four C registers with a 64/64/64/1 N split. */
int main(void) {
  return coral_gemm_mx_multicreg(
      (const int8_t *)(uintptr_t)0x80000000U, 128,
      (const int8_t *)(uintptr_t)0x80010000U, 128,
      (const uint8_t *)(uintptr_t)0x80020000U, 512,
      (const uint8_t *)(uintptr_t)0x80021000U, 512,
      (float *)(uintptr_t)0x80040000U, 832,
      64, 193, 64);
}
