#include <cassert>

#include "coral_matrix_ab_allocator.h"
#include "coral_matrix_tiling.h"

namespace {

void CheckFourTileReuse() {
  coral_matrix_ab_allocator_t allocator;
  coral_matrix_ab_allocator_init(&allocator);

  size_t a_reg;
  size_t b0_reg;
  size_t b1_reg;
  size_t b2_reg;
  assert(coral_matrix_ab_allocator_allocate(
             &allocator, CORAL_MATRIX_AB_OPERAND_A, 1, 3, &a_reg) ==
         CORAL_MATRIX_AB_ALLOCATOR_OK);
  assert(coral_matrix_ab_allocator_allocate(
             &allocator, CORAL_MATRIX_AB_OPERAND_B, 10, 0, &b0_reg) ==
         CORAL_MATRIX_AB_ALLOCATOR_OK);
  assert(coral_matrix_ab_allocator_allocate(
             &allocator, CORAL_MATRIX_AB_OPERAND_B, 11, 1, &b1_reg) ==
         CORAL_MATRIX_AB_ALLOCATOR_OK);
  assert(coral_matrix_ab_allocator_allocate(
             &allocator, CORAL_MATRIX_AB_OPERAND_B, 12, 2, &b2_reg) ==
         CORAL_MATRIX_AB_ALLOCATOR_OK);

  size_t unused_reg;
  assert(coral_matrix_ab_allocator_allocate(
             &allocator, CORAL_MATRIX_AB_OPERAND_B, 13, 3, &unused_reg) ==
         CORAL_MATRIX_AB_ALLOCATOR_NO_FREE_REG);
  assert(unused_reg == CORAL_MATRIX_AB_REG_NONE);

  assert(coral_matrix_ab_allocator_begin_event(&allocator, 1) ==
         CORAL_MATRIX_AB_ALLOCATOR_OK);
  size_t b3_reg;
  assert(coral_matrix_ab_allocator_allocate(
             &allocator, CORAL_MATRIX_AB_OPERAND_B, 13, 3, &b3_reg) ==
         CORAL_MATRIX_AB_ALLOCATOR_OK);
  assert(b3_reg == b0_reg);

  coral_matrix_ab_reg_state_t state;
  assert(coral_matrix_ab_allocator_get(&allocator, a_reg, &state) ==
         CORAL_MATRIX_AB_ALLOCATOR_OK);
  assert(state.allocated && state.operand_kind == CORAL_MATRIX_AB_OPERAND_A &&
         state.owner == 1 && state.first_use_event == 0 &&
         state.last_use_event == 3);

  assert(coral_matrix_ab_allocator_begin_event(&allocator, 4) ==
         CORAL_MATRIX_AB_ALLOCATOR_OK);
  for (size_t reg = 0; reg < CORAL_MATRIX_AB_REG_COUNT; ++reg) {
    assert(coral_matrix_ab_allocator_get(&allocator, reg, &state) ==
           CORAL_MATRIX_AB_ALLOCATOR_OK);
    assert(!state.allocated);
  }
}

void CheckEventInvariants() {
  coral_matrix_ab_allocator_t allocator;
  coral_matrix_ab_allocator_init(&allocator);

  size_t reg;
  assert(coral_matrix_ab_allocator_allocate(
             &allocator, CORAL_MATRIX_AB_OPERAND_A, 0, 0, &reg) ==
         CORAL_MATRIX_AB_ALLOCATOR_OK);
  assert(coral_matrix_ab_allocator_begin_event(&allocator, 0) ==
         CORAL_MATRIX_AB_ALLOCATOR_OK);
  assert(coral_matrix_ab_allocator_begin_event(&allocator, 1) ==
         CORAL_MATRIX_AB_ALLOCATOR_OK);
  assert(coral_matrix_ab_allocator_begin_event(&allocator, 0) ==
         CORAL_MATRIX_AB_ALLOCATOR_BAD_EVENT);
  assert(coral_matrix_ab_allocator_allocate(
             &allocator, CORAL_MATRIX_AB_OPERAND_B, 1, 0, &reg) ==
         CORAL_MATRIX_AB_ALLOCATOR_BAD_EVENT);
  assert(coral_matrix_ab_allocator_get(
             &allocator, CORAL_MATRIX_AB_REG_COUNT, nullptr) ==
         CORAL_MATRIX_AB_ALLOCATOR_BAD_ARGUMENT);
}

void CheckPlannerBoundaries() {
  const size_t n_values[] = {65, 129, 255, 257};
  for (size_t n : n_values) {
    coral_matrix_tiling_plan_t plan;
    assert(coral_matrix_tiling_plan_init(&plan, 64, n, 64) ==
           CORAL_MATRIX_TILING_OK);

    for (size_t group_index = 0; group_index < plan.n_groups;
         ++group_index) {
      coral_matrix_n_group_t group;
      assert(coral_matrix_tiling_get_n_group(
                 &plan, 0, group_index, &group) == CORAL_MATRIX_TILING_OK);

      coral_matrix_ab_allocator_t allocator;
      coral_matrix_ab_allocator_init(&allocator);
      const size_t last_event = group.n_tiles - 1;
      size_t a_reg;
      assert(coral_matrix_ab_allocator_allocate(
                 &allocator, CORAL_MATRIX_AB_OPERAND_A, group_index,
                 last_event, &a_reg) == CORAL_MATRIX_AB_ALLOCATOR_OK);

      const size_t resident_tiles = group.n_tiles < 3 ? group.n_tiles : 3;
      size_t b_reg[3];
      for (size_t slot = 0; slot < resident_tiles; ++slot) {
        assert(coral_matrix_ab_allocator_allocate(
                   &allocator, CORAL_MATRIX_AB_OPERAND_B, slot, slot,
                   &b_reg[slot]) == CORAL_MATRIX_AB_ALLOCATOR_OK);
      }
      if (group.n_tiles == 4) {
        assert(coral_matrix_ab_allocator_begin_event(&allocator, 1) ==
               CORAL_MATRIX_AB_ALLOCATOR_OK);
        size_t fourth_reg;
        assert(coral_matrix_ab_allocator_allocate(
                   &allocator, CORAL_MATRIX_AB_OPERAND_B, 3, 3,
                   &fourth_reg) == CORAL_MATRIX_AB_ALLOCATOR_OK);
        assert(fourth_reg == b_reg[0]);
      }
      assert(coral_matrix_ab_allocator_begin_event(
                 &allocator, last_event + 1) ==
             CORAL_MATRIX_AB_ALLOCATOR_OK);
    }
  }
}

}  // namespace

int main() {
  CheckFourTileReuse();
  CheckEventInvariants();
  CheckPlannerBoundaries();
  return 0;
}
