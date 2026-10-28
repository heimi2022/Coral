#ifndef CORAL_MATRIX_GEMM_LAYOUT_H_
#define CORAL_MATRIX_GEMM_LAYOUT_H_

#include <stddef.h>
#include <stdint.h>

#include "coral_matrix_tiling.h"

#define CORAL_MATRIX_LAYOUT_OK 0
#define CORAL_MATRIX_LAYOUT_BAD_ARGUMENT (-1)
#define CORAL_MATRIX_LAYOUT_OVERFLOW (-2)

/* Recommended DMA storage for positive logical M/N/K. All sizes are bytes.
 * B is already transposed [N][K]; this interface does not transpose it.
 * Allocate each buffer at a 64-byte aligned address. */
typedef struct {
  size_t compute_k;
  size_t scale_groups;
  size_t lda;
  size_t ldb;
  size_t a_scale_stride;
  size_t b_scale_stride;
  size_t ldc;
  size_t a_bytes;
  size_t b_bytes;
  size_t a_scale_bytes;
  size_t b_scale_bytes;
  size_t c_bytes;
} coral_matrix_gemm_layout_t;

static inline int coral_matrix_gemm_layout_init(
    coral_matrix_gemm_layout_t *layout, size_t m, size_t n, size_t k) {
  if (layout == NULL || m == 0 || n == 0 || k == 0) {
    return CORAL_MATRIX_LAYOUT_BAD_ARGUMENT;
  }
  if (m > SIZE_MAX - 63 || k > SIZE_MAX - 63 ||
      n > (SIZE_MAX - 63) / sizeof(float)) {
    return CORAL_MATRIX_LAYOUT_OVERFLOW;
  }
  coral_matrix_gemm_layout_t result;
  result.compute_k = (k + 31) & ~(size_t)31;
  result.scale_groups = coral_matrix_tiling_ceil_div(k, 32);
  result.lda = result.ldb = (k + 63) & ~(size_t)63;
  result.a_scale_stride = (m + 63) & ~(size_t)63;
  result.b_scale_stride = (n + 63) & ~(size_t)63;
  result.ldc = (n * sizeof(float) + 63) & ~(size_t)63;
  if (m > SIZE_MAX / result.lda || n > SIZE_MAX / result.ldb ||
      result.scale_groups > SIZE_MAX / result.a_scale_stride ||
      result.scale_groups > SIZE_MAX / result.b_scale_stride ||
      m > SIZE_MAX / result.ldc) {
    return CORAL_MATRIX_LAYOUT_OVERFLOW;
  }
  result.a_bytes = m * result.lda;
  result.b_bytes = n * result.ldb;
  result.a_scale_bytes = result.scale_groups * result.a_scale_stride;
  result.b_scale_bytes = result.scale_groups * result.b_scale_stride;
  result.c_bytes = m * result.ldc;
  *layout = result;
  return CORAL_MATRIX_LAYOUT_OK;
}

/* Zero only [K, round_up(K,32)) in every A and transposed-B row.
 * Call BEFORE submitting GEMM, on writable buffers with capacity M*lda and
 * N*ldb. Never modify these buffers while a matrix command still uses them.
 * The final partial scale group uses the caller's original scale. */
static inline int coral_matrix_gemm_pad_k(
    int8_t *a, size_t lda, int8_t *b_transposed, size_t ldb,
    size_t m, size_t n, size_t k) {
  if (a == NULL || b_transposed == NULL || m == 0 || n == 0 || k == 0) {
    return CORAL_MATRIX_LAYOUT_BAD_ARGUMENT;
  }
  if (k > SIZE_MAX - 31) {
    return CORAL_MATRIX_LAYOUT_OVERFLOW;
  }
  const size_t compute_k = (k + 31) & ~(size_t)31;
  if (lda < compute_k || ldb < compute_k ||
      ((lda | ldb | (uintptr_t)a | (uintptr_t)b_transposed) & 63U)) {
    return CORAL_MATRIX_LAYOUT_BAD_ARGUMENT;
  }
  if (m > SIZE_MAX / lda || n > SIZE_MAX / ldb) {
    return CORAL_MATRIX_LAYOUT_OVERFLOW;
  }
  if (k == compute_k) {
    return CORAL_MATRIX_LAYOUT_OK;
  }
  for (size_t row = 0; row < m; ++row) {
    for (size_t index = k; index < compute_k; ++index) {
      a[row * lda + index] = 0;
    }
  }
  for (size_t row = 0; row < n; ++row) {
    for (size_t index = k; index < compute_k; ++index) {
      b_transposed[row * ldb + index] = 0;
    }
  }
  return CORAL_MATRIX_LAYOUT_OK;
}

#endif
