#include <algorithm>
#include <array>
#include <cassert>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <deque>

#include "coral_matrix.h"
#include "coral_matrix_gemm_layout.h"

namespace {

struct Operand {
  const int8_t* data = nullptr;
  size_t stride = 0;
  const uint8_t* scale = nullptr;
  size_t scale_stride = 0;
  size_t rows = 0;
  size_t k = 0;
};

struct Model {
  size_t m = 0, n = 0, k = 0;
  std::array<Operand, 4> ab{};
  std::array<bool, 4> reg_is_left{};
  double c[4][64][64]{};
  size_t clears = 0, matmuls = 0, stores = 0;
  size_t k_tiles = 0;
  std::array<size_t, 4> accumulated_tiles{};
  std::deque<unsigned> pending_stores;
  std::deque<unsigned> loaded_b_regs;
  unsigned loads_before_store = 0;
  size_t store_lookaheads = 0;
  unsigned group_prefetch_stage = 0;
  size_t early_group_a_loads = 0, early_group_b_loads = 0;
  size_t early_group_matmuls = 0;

  void Configure(size_t& axis, size_t value) {
    assert(pending_stores.empty());
    axis = value;
  }

  void Load(unsigned reg, const void* base, size_t stride, bool left) {
    if (pending_stores.size() == 2) {
      // Next-group prefetches must follow both current C2/C3 MATMULs.
      assert(pending_stores.front() == CORAL_C2 &&
             pending_stores.back() == CORAL_C3);
      if (left) {
        assert(reg == CORAL_A0 && group_prefetch_stage == 0);
        group_prefetch_stage = 1;
        ++early_group_a_loads;
      } else {
        assert(reg == CORAL_B1 &&
               (group_prefetch_stage == 0 || group_prefetch_stage == 2));
        group_prefetch_stage = 3;
        ++early_group_b_loads;
      }
    } else if (!pending_stores.empty()) {
      assert(!left);
    }
    if (!left) {
      loaded_b_regs.push_back(reg);
      if (!pending_stores.empty() && pending_stores.size() != 2)
        ++loads_before_store;
    }
    reg_is_left[reg] = left;
    ab[reg] = {static_cast<const int8_t*>(base), stride, nullptr, 0,
               left ? m : n, k};
  }

  void Scale(unsigned reg, const void* base, size_t stride) {
    if (pending_stores.size() == 2) {
      assert((group_prefetch_stage == 1 && reg == CORAL_A0) ||
             (group_prefetch_stage == 3 && reg == CORAL_B1));
      ++group_prefetch_stage;
    } else if (!pending_stores.empty()) {
      assert(!reg_is_left[reg]);
      ++loads_before_store;
    }
    ab[reg].scale = static_cast<const uint8_t*>(base);
    ab[reg].scale_stride = stride;
  }

  void Clear(unsigned reg) {
    // A different C register may be cleared while older C stores drain. The
    // register being cleared itself must not still have a pending store.
    assert(std::find(pending_stores.begin(), pending_stores.end(), reg) ==
           pending_stores.end());
    accumulated_tiles[reg - CORAL_C0] = 0;
    for (auto& row : c[reg - CORAL_C0]) {
      for (double& value : row) value = 0;
    }
    ++clears;
  }

  void Matmul(unsigned dest, unsigned right, unsigned left) {
    assert(std::find(pending_stores.begin(), pending_stores.end(), dest) ==
           pending_stores.end());
    if (pending_stores.size() == 2) {
      assert(pending_stores.front() == CORAL_C2 &&
             pending_stores.back() == CORAL_C3);
      assert(dest == CORAL_C0 && right == CORAL_B1 && left == CORAL_A0);
      assert(group_prefetch_stage == 4);
      assert(accumulated_tiles[0] == 0);
      ++early_group_matmuls;
    }
    assert(!loaded_b_regs.empty() && loaded_b_regs.front() == right);
    loaded_b_regs.pop_front();
    assert(left != right);
    const Operand& a = ab[left];
    const Operand& b = ab[right];
    assert(a.data && a.scale && b.data && b.scale);
    assert(a.rows == m && b.rows == n && a.k == k && b.k == k);
    for (size_t i = 0; i < m; ++i) {
      for (size_t j = 0; j < n; ++j) {
        for (size_t x = 0; x < k; ++x) {
          const int exponent = a.scale[(x / 32) * a.scale_stride + i] +
                               b.scale[(x / 32) * b.scale_stride + j] - 266;
          c[dest - CORAL_C0][i][j] += std::ldexp(
              int(a.data[i * a.stride + x]) * b.data[j * b.stride + x],
              exponent);
        }
      }
    }
    ++matmuls;
    if (++accumulated_tiles[dest - CORAL_C0] == k_tiles) {
      pending_stores.push_back(dest);
    }
  }

  void Store(unsigned reg, void* base, size_t stride) {
    // Full groups issue the next B load and MMACC before the previous store.
    assert(!pending_stores.empty() && pending_stores.front() == reg);
    assert(group_prefetch_stage == 0 || group_prefetch_stage == 4);
    group_prefetch_stage = 0;
    store_lookaheads += loads_before_store != 0;
    loads_before_store = 0;
    pending_stores.pop_front();
    for (size_t i = 0; i < m; ++i) {
      auto* row = reinterpret_cast<float*>(static_cast<uint8_t*>(base) +
                                           i * stride);
      for (size_t j = 0; j < n; ++j) row[j] = c[reg - CORAL_C0][i][j];
    }
    ++stores;
  }
};

Model model;

}  // namespace

// Execute the real scheduler with synchronous matrix operations on the host.
// This checks scheduling and addresses, not RTL timing or accumulator rounding.
#undef coral_msettilem
#undef coral_msettilen
#undef coral_msettilek
#undef coral_mlae8
#undef coral_mlbe8
#undef coral_mlate8
#undef coral_mlbte8
#undef coral_mzero
#undef coral_mmacc_w_b
#undef coral_msce32
#define coral_msettilem(value) model.Configure(model.m, value)
#define coral_msettilen(value) model.Configure(model.n, value)
#define coral_msettilek(value) model.Configure(model.k, value)
#define coral_mlae8(reg, base, stride) model.Load(reg, base, stride, true)
#define coral_mlbe8(reg, base, stride) model.Load(reg, base, stride, false)
#define coral_mlate8(reg, base, stride) model.Scale(reg, base, stride)
#define coral_mlbte8(reg, base, stride) model.Scale(reg, base, stride)
#define coral_mzero(reg) model.Clear(reg)
#define coral_mmacc_w_b(dest, right, left) model.Matmul(dest, right, left)
#define coral_msce32(reg, base, stride) model.Store(reg, base, stride)
#include "coral_matrix_gemm.h"

namespace {

void Check(size_t m, size_t n, size_t k) {
  alignas(64) static int8_t a[512 * 320], b[512 * 320];
  alignas(64) static uint8_t as[10 * 512], bs[10 * 512];
  alignas(64) static float output[512 * 512];
  coral_matrix_gemm_layout_t layout;
  assert(coral_matrix_gemm_layout_init(&layout, m, n, k) == 0);
  for (size_t i = 0; i < m; ++i) {
    for (size_t x = 0; x < layout.lda; ++x) {
      a[i * layout.lda + x] = x < k ? int((i * 3 + x * 5) % 15) - 7 : 0;
    }
  }
  for (size_t j = 0; j < n; ++j) {
    for (size_t x = 0; x < layout.ldb; ++x) {
      b[j * layout.ldb + x] = x < k ? int((j * 7 + x * 2) % 13) - 6 : 0;
    }
  }
  for (size_t g = 0; g < layout.scale_groups; ++g) {
    for (size_t i = 0; i < m; ++i) {
      as[g * layout.a_scale_stride + i] = 126 + (g + i) % 3;
    }
    for (size_t j = 0; j < n; ++j) {
      bs[g * layout.b_scale_stride + j] = 126 + (2 * g + j) % 3;
    }
  }
  for (float& value : output) value = -999;
  model = Model{};
  model.k_tiles = (k + 63) / 64;
  assert(coral_gemm_mx_multicreg(
      a, layout.lda, b, layout.ldb, as, layout.a_scale_stride,
      bs, layout.b_scale_stride, output, layout.ldc, m, n, k) == 0);
  const size_t output_tiles = ((m + 63) / 64) * ((n + 63) / 64);
  assert(model.clears == output_tiles);
  assert(model.stores == output_tiles);
  assert(model.matmuls == output_tiles * ((k + 63) / 64));
  assert(model.pending_stores.empty());
  assert(model.store_lookaheads ==
         ((m + 63) / 64) * (n / 256) * 3);
  size_t expected_early_a = 0, expected_early_b = 0;
  size_t expected_early_matmuls = 0;
  if (k % 64 == 0) {
    for (size_t m0 = 0; m0 < m; m0 += 64) {
      for (size_t n0 = 0; n0 + 256 <= n; n0 += 256) {
        const size_t next_m0 = n0 + 256 < n ? m0 : m0 + 64;
        const size_t next_n0 = n0 + 256 < n ? n0 + 256 : 0;
        if (next_m0 >= m || n - next_n0 < 256) continue;
        ++expected_early_b;
        expected_early_a += coral_matrix_tiling_min(m - m0, 64) ==
                            coral_matrix_tiling_min(m - next_m0, 64);
        expected_early_matmuls +=
            coral_matrix_tiling_min(m - m0, 64) ==
            coral_matrix_tiling_min(m - next_m0, 64);
      }
    }
  }
  assert(model.early_group_a_loads == expected_early_a);
  assert(model.early_group_b_loads == expected_early_b);
  assert(model.early_group_matmuls == expected_early_matmuls);
  for (size_t i = 0; i < m; ++i) {
    for (size_t j = 0; j < layout.ldc / sizeof(float); ++j) {
      double expected = -999;
      if (j < n) {
        expected = 0;
        for (size_t x = 0; x < k; ++x) {
          const int exponent = as[(x / 32) * layout.a_scale_stride + i] +
                               bs[(x / 32) * layout.b_scale_stride + j] - 266;
          expected += std::ldexp(int(a[i * layout.lda + x]) *
                                b[j * layout.ldb + x], exponent);
        }
      }
      assert(output[i * (layout.ldc / sizeof(float)) + j] == float(expected));
    }
  }
}

}  // namespace

int main() {
  size_t cases = 0;
  for (size_t m : {1, 3, 65, 128}) {
    for (size_t n : {1, 65, 129, 255, 256, 257, 512}) {
      for (size_t k : {1, 32, 63, 64, 65, 96, 127, 128, 129, 192, 256, 320}) {
        Check(m, n, k);
        ++cases;
      }
    }
  }
  // Cover full groups across several M boundaries and shorter full N groups.
  for (size_t n : {64, 128, 192, 256, 512}) {
    Check(192, n, 128);
    Check(193, n, 128);
    cases += 2;
  }
  Check(512, 512, 128);
  ++cases;
  std::printf("GEMM schedule: %zu shapes passed\n", cases);
}
