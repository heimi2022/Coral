#include "include/coral_matrix_gemm.h"

#ifndef GEMM_M
#error "Define GEMM_M, GEMM_N and GEMM_K for this program"
#endif

/* The testbench supplies pretransposed B and zero-padded K rows. */
int main(void) {
  const size_t ab_stride = GEMM_K <= 128 ? 128 : ((GEMM_K + 63) / 64) * 64;
  const coral_matrix_gemm_desc_t desc = {
      (const int8_t *)(uintptr_t)0x80000000U, ab_stride,
      (const int8_t *)(uintptr_t)0x80010000U, ab_stride,
      (const uint8_t *)(uintptr_t)0x80020000U, 512,
      (const uint8_t *)(uintptr_t)0x80021000U, 512,
      (float *)(uintptr_t)0x80040000U, ((GEMM_N * 4 + 63) / 64) * 64,
      GEMM_M, GEMM_N, GEMM_K,
  };
  return coral_matrix_gemm_multicreg_run(&desc);
}
