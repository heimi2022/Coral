#include <cassert>

#include "coral_matrix_tiling.h"

namespace {

void CheckNBoundaries(size_t n) {
  coral_matrix_tiling_plan_t plan;
  assert(coral_matrix_tiling_plan_init(&plan, 64, n, 64) ==
         CORAL_MATRIX_TILING_OK);
  assert(plan.m_tiles == 1);
  assert(plan.n_groups == (n + 255) / 256);
  assert(plan.k_tiles == 1);

  size_t covered = 0;
  for (size_t group_index = 0; group_index < plan.n_groups; ++group_index) {
    coral_matrix_n_group_t group;
    assert(coral_matrix_tiling_get_n_group(&plan, 0, group_index, &group) ==
           CORAL_MATRIX_TILING_OK);
    assert(group.n_offset == covered);
    assert(group.n_size == coral_matrix_tiling_min(256, n - covered));
    assert(group.n_tiles == coral_matrix_tiling_ceil_div(group.n_size, 64));

    for (size_t slot = 0; slot < group.n_tiles; ++slot) {
      coral_matrix_n_tile_t tile;
      assert(coral_matrix_tiling_get_n_tile(&group, slot, &tile) ==
             CORAL_MATRIX_TILING_OK);
      assert(tile.offset == covered);
      assert(tile.size == coral_matrix_tiling_min(64, n - covered));
      covered += tile.size;
    }
  }
  assert(covered == n);
}

void CheckK128() {
  coral_matrix_tiling_plan_t plan;
  assert(coral_matrix_tiling_plan_init(&plan, 512, 512, 128) ==
         CORAL_MATRIX_TILING_OK);
  assert(plan.m_tiles == 8 && plan.n_groups == 2 && plan.k_tiles == 2);
  assert(plan.scale_groups == 4);

  coral_matrix_m_tile_t m_tile;
  assert(coral_matrix_tiling_get_m_tile(&plan, 7, &m_tile) ==
         CORAL_MATRIX_TILING_OK);
  assert(m_tile.offset == 448 && m_tile.size == 64);

  coral_matrix_k_tile_t k_tile;
  assert(coral_matrix_tiling_get_k_tile(&plan, 0, &k_tile) ==
         CORAL_MATRIX_TILING_OK);
  assert(k_tile.offset == 0 && k_tile.size == 64);
  assert(k_tile.scale_group == 0 && k_tile.scale_group_count == 2);
  assert(coral_matrix_tiling_get_k_tile(&plan, 1, &k_tile) ==
         CORAL_MATRIX_TILING_OK);
  assert(k_tile.offset == 64 && k_tile.size == 64);
  assert(k_tile.scale_group == 2 && k_tile.scale_group_count == 2);
}

void CheckInvalidDimensions() {
  coral_matrix_tiling_plan_t plan;
  assert(coral_matrix_tiling_plan_init(&plan, 0, 64, 64) ==
         CORAL_MATRIX_TILING_BAD_ARGUMENT);
  assert(coral_matrix_tiling_plan_init(&plan, 64, 64, 0) ==
         CORAL_MATRIX_TILING_BAD_ARGUMENT);
}

void CheckKTails() {
  for (size_t k = 1; k <= 257; ++k) {
    coral_matrix_tiling_plan_t plan;
    assert(coral_matrix_tiling_plan_init(&plan, 65, 257, k) ==
           CORAL_MATRIX_TILING_OK);
    assert(plan.scale_groups == (k + 31) / 32);
    size_t covered = 0;
    size_t groups = 0;
    for (size_t index = 0; index < plan.k_tiles; ++index) {
      coral_matrix_k_tile_t tile;
      assert(coral_matrix_tiling_get_k_tile(&plan, index, &tile) ==
             CORAL_MATRIX_TILING_OK);
      assert(tile.offset == covered);
      assert(tile.size == coral_matrix_tiling_min(64, k - covered));
      assert(tile.compute_size >= tile.size && tile.compute_size <= 64);
      assert(tile.compute_size % 32 == 0);
      assert(tile.scale_group == groups);
      covered += tile.size;
      groups += tile.scale_group_count;
    }
    assert(covered == k && groups == plan.scale_groups);
  }
}

}  // namespace

int main() {
  CheckNBoundaries(65);
  CheckNBoundaries(129);
  CheckNBoundaries(193);
  CheckNBoundaries(255);
  CheckNBoundaries(257);
  CheckK128();
  CheckKTails();
  CheckInvalidDimensions();
  return 0;
}
