#include "include/coral_matrix_gemm.h"

int main(void) {
  const coral_matrix_gemm_desc_t desc = {
      (const int8_t *)(uintptr_t)0x00040000U, 128,
      (const int8_t *)(uintptr_t)0x00050000U, 128,
      (const uint8_t *)(uintptr_t)0x00060000U, 512,
      (const uint8_t *)(uintptr_t)0x00061000U, 512,
      (float *)(uintptr_t)0x00080000U, 320,
      64, 65, 64};
  return coral_matrix_gemm_multicreg_run(&desc);
}
