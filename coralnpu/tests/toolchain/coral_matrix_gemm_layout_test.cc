#include <cassert>
#include <cstdint>
#include <cstring>

#include "coral_matrix_gemm_layout.h"
#include "coral_matrix_gemm.h"

namespace {

void CheckPadding(size_t k) {
  constexpr size_t m = 3;
  constexpr size_t n = 5;
  alignas(64) int8_t a[m * 320];
  alignas(64) int8_t b[n * 320];
  coral_matrix_gemm_layout_t layout;
  assert(coral_matrix_gemm_layout_init(&layout, m, n, k) ==
         CORAL_MATRIX_LAYOUT_OK);
  assert(layout.compute_k == ((k + 31) / 32) * 32);
  assert(layout.scale_groups == (k + 31) / 32);
  assert(layout.lda == layout.ldb && layout.lda >= layout.compute_k);
  assert((layout.lda | layout.a_scale_stride |
          layout.b_scale_stride | layout.ldc) % 64 == 0);
  assert(layout.a_bytes == m * layout.lda);
  assert(layout.b_bytes == n * layout.ldb);
  assert(layout.a_scale_bytes == layout.scale_groups * layout.a_scale_stride);
  assert(layout.b_scale_bytes == layout.scale_groups * layout.b_scale_stride);
  assert(layout.c_bytes == m * layout.ldc);
  alignas(64) uint8_t a_scale[640];
  alignas(64) uint8_t b_scale[640];
  alignas(64) float c[m * 16];
  assert(coral_gemm_mx_validate(
      a, layout.lda, b, layout.ldb,
      a_scale, layout.a_scale_stride, b_scale, layout.b_scale_stride,
      c, layout.ldc, m, n, k) == CORAL_GEMM_MX_OK);

  std::memset(a, 0x55, sizeof(a));
  std::memset(b, 0x66, sizeof(b));
  for (size_t row = 0; row < m; ++row) {
    for (size_t index = 0; index < k; ++index) {
      a[row * layout.lda + index] = static_cast<int8_t>((row + index) % 17 - 8);
    }
  }
  for (size_t row = 0; row < n; ++row) {
    for (size_t index = 0; index < k; ++index) {
      b[row * layout.ldb + index] = static_cast<int8_t>((2 * row + index) % 13 - 6);
    }
  }
  assert(coral_matrix_gemm_pad_k(a, layout.lda, b, layout.ldb, m, n, k) ==
         CORAL_MATRIX_LAYOUT_OK);
  for (size_t index = 0; index < sizeof(a); ++index) {
    const size_t row = index / layout.lda;
    const size_t col = index % layout.lda;
    const int8_t expected = row >= m || col >= layout.compute_k ? 0x55 :
        col < k ? static_cast<int8_t>((row + col) % 17 - 8) : 0;
    assert(a[index] == expected);
  }
  for (size_t index = 0; index < sizeof(b); ++index) {
    const size_t row = index / layout.ldb;
    const size_t col = index % layout.ldb;
    const int8_t expected = row >= n || col >= layout.compute_k ? 0x66 :
        col < k ? static_cast<int8_t>((2 * row + col) % 13 - 6) : 0;
    assert(b[index] == expected);
  }
}

}  // namespace

int main() {
  // The multicreg schedule alternates the A register so that the next K
  // tile can be loaded while the previous tile's MMACCs drain.
  assert(coral_gemm_mx_a_reg_for_k_tile(0) == CORAL_A0);
  assert(coral_gemm_mx_a_reg_for_k_tile(1) == CORAL_A2);
  assert(coral_gemm_mx_a_reg_for_k_tile(2) == CORAL_A0);
  const unsigned even_b_regs[] = {CORAL_B1, CORAL_B2, CORAL_B3, CORAL_B1};
  const unsigned odd_b_regs[] = {CORAL_B3, CORAL_B0, CORAL_B1, CORAL_B3};
  for (size_t slot = 0; slot < 4; ++slot) {
    assert(coral_gemm_mx_b_reg_for_k_tile(0, slot) == even_b_regs[slot]);
    assert(coral_gemm_mx_b_reg_for_k_tile(1, slot) == odd_b_regs[slot]);
    assert(coral_gemm_mx_b_reg_for_k_tile(2, slot) == even_b_regs[slot]);
  }

  for (size_t k = 1; k <= 257; ++k) {
    CheckPadding(k);
  }
  coral_matrix_gemm_layout_t layout;
  assert(coral_matrix_gemm_layout_init(&layout, 65, 257, 129) == 0);
  assert(layout.lda == 192 && layout.ldc == 1088);
  assert(layout.a_scale_stride == 128 && layout.b_scale_stride == 320);
  assert(coral_matrix_gemm_layout_init(nullptr, 1, 1, 1) ==
         CORAL_MATRIX_LAYOUT_BAD_ARGUMENT);
  assert(coral_matrix_gemm_layout_init(&layout, 1, 1, 0) ==
         CORAL_MATRIX_LAYOUT_BAD_ARGUMENT);
  assert(coral_matrix_gemm_layout_init(&layout, SIZE_MAX, 1, 1) ==
         CORAL_MATRIX_LAYOUT_OVERFLOW);
  assert(coral_matrix_gemm_layout_init(&layout, 1, SIZE_MAX, 1) ==
         CORAL_MATRIX_LAYOUT_OVERFLOW);
  assert(coral_matrix_gemm_layout_init(&layout, 1, 1, SIZE_MAX) ==
         CORAL_MATRIX_LAYOUT_OVERFLOW);
  assert(coral_matrix_gemm_layout_init(&layout, SIZE_MAX / 64, 1, 65) ==
         CORAL_MATRIX_LAYOUT_OVERFLOW);
  alignas(64) int8_t a[128];
  alignas(64) int8_t b[128];
  alignas(64) uint8_t scale[64];
  alignas(64) float c[16];
  assert(coral_gemm_mx_validate(a, 64, b, 64, scale, 64, scale, 64,
                              c, 64, 1, 1, 65) == CORAL_GEMM_MX_BAD_STRIDE);
  assert(coral_gemm_mx_validate(a, 64, b, 64, scale, 64, scale, 64,
                              c, 64, 1, 1, SIZE_MAX) == CORAL_GEMM_MX_BAD_K);
  assert(coral_gemm_mx_validate(a, 64, b, 64, scale, 64, scale, 64,
                              c, 64, 1, SIZE_MAX, 1) == CORAL_GEMM_MX_BAD_STRIDE);
  assert(coral_gemm_mx_validate(a + 1, 64, b, 64, scale, 64, scale, 64,
                              c, 64, 1, 1, 1) == CORAL_GEMM_MX_BAD_ALIGNMENT);
  std::memset(a, 0x55, sizeof(a));
  assert(coral_matrix_gemm_pad_k(a, 64, b, 128, 1, 1, 65) ==
         CORAL_MATRIX_LAYOUT_BAD_ARGUMENT);
  assert(coral_matrix_gemm_pad_k(a + 1, 64, b, 64, 1, 1, 1) ==
         CORAL_MATRIX_LAYOUT_BAD_ARGUMENT);
  assert(coral_matrix_gemm_pad_k(a, 64, b, 64, 1, 1, SIZE_MAX) ==
         CORAL_MATRIX_LAYOUT_OVERFLOW);
  for (int8_t value : a) {
    assert(value == 0x55);
  }
  return 0;
}
