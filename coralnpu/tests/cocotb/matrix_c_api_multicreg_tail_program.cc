#include "include/coral_matrix_gemm.h"

/* Exercise four C registers with a 64/64/64/1 N split. */
int main(void) {
  return coral_gemm_mx_multicreg(
      (const int8_t *)(uintptr_t)0x00040000U, 128,
      (const int8_t *)(uintptr_t)0x00050000U, 128,
      (const uint8_t *)(uintptr_t)0x00060000U, 512,
      (const uint8_t *)(uintptr_t)0x00061000U, 512,
      (float *)(uintptr_t)0x00080000U, 832,
      64, 193, 64);
}
