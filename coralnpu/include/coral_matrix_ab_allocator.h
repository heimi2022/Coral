#ifndef CORAL_MATRIX_AB_ALLOCATOR_H_
#define CORAL_MATRIX_AB_ALLOCATOR_H_

#include <stddef.h>
#include <stdint.h>

/* All four AB registers are interchangeable physical storage slots. */
#define CORAL_MATRIX_AB_REG_COUNT 4U
#define CORAL_MATRIX_AB_REG_NONE ((size_t)-1)

#define CORAL_MATRIX_AB_ALLOCATOR_OK 0
#define CORAL_MATRIX_AB_ALLOCATOR_BAD_ARGUMENT (-1)
#define CORAL_MATRIX_AB_ALLOCATOR_NO_FREE_REG (-2)
#define CORAL_MATRIX_AB_ALLOCATOR_BAD_EVENT (-3)
#define CORAL_MATRIX_AB_ALLOCATOR_BAD_REG (-4)

typedef enum {
  CORAL_MATRIX_AB_OPERAND_A = 0,
  CORAL_MATRIX_AB_OPERAND_B = 1,
} coral_matrix_ab_operand_kind_t;

typedef struct {
  uint8_t allocated;
  uint8_t operand_kind;
  size_t owner;
  size_t first_use_event;
  size_t last_use_event;
} coral_matrix_ab_reg_state_t;

typedef struct {
  size_t current_event;
  coral_matrix_ab_reg_state_t reg[CORAL_MATRIX_AB_REG_COUNT];
} coral_matrix_ab_allocator_t;

static inline void coral_matrix_ab_allocator_clear_reg(
    coral_matrix_ab_reg_state_t *state) {
  state->allocated = 0;
  state->operand_kind = 0;
  state->owner = 0;
  state->first_use_event = 0;
  state->last_use_event = 0;
}

static inline void coral_matrix_ab_allocator_init(
    coral_matrix_ab_allocator_t *allocator) {
  if (allocator == NULL) {
    return;
  }
  allocator->current_event = 0;
  for (size_t reg = 0; reg < CORAL_MATRIX_AB_REG_COUNT; ++reg) {
    coral_matrix_ab_allocator_clear_reg(&allocator->reg[reg]);
  }
}

/*
 * Events are monotonically increasing command-order tokens, not presumed
 * clock counts. A register whose last use is event E remains live during E
 * and becomes reusable when the allocator advances to an event greater than
 * E. The instruction emitter must still preserve the corresponding hardware
 * ordering/barrier when it overwrites a released register.
 */
static inline int coral_matrix_ab_allocator_begin_event(
    coral_matrix_ab_allocator_t *allocator, size_t event) {
  if (allocator == NULL) {
    return CORAL_MATRIX_AB_ALLOCATOR_BAD_ARGUMENT;
  }
  if (event < allocator->current_event) {
    return CORAL_MATRIX_AB_ALLOCATOR_BAD_EVENT;
  }

  for (size_t reg = 0; reg < CORAL_MATRIX_AB_REG_COUNT; ++reg) {
    coral_matrix_ab_reg_state_t *state = &allocator->reg[reg];
    if (state->allocated && state->last_use_event < event) {
      coral_matrix_ab_allocator_clear_reg(state);
    }
  }
  allocator->current_event = event;
  return CORAL_MATRIX_AB_ALLOCATOR_OK;
}

/* Allocate the lowest-numbered currently free physical register. */
static inline int coral_matrix_ab_allocator_allocate(
    coral_matrix_ab_allocator_t *allocator,
    coral_matrix_ab_operand_kind_t operand_kind, size_t owner,
    size_t last_use_event, size_t *reg_out) {
  if (allocator == NULL || reg_out == NULL ||
      (operand_kind != CORAL_MATRIX_AB_OPERAND_A &&
       operand_kind != CORAL_MATRIX_AB_OPERAND_B)) {
    return CORAL_MATRIX_AB_ALLOCATOR_BAD_ARGUMENT;
  }
  if (last_use_event < allocator->current_event) {
    return CORAL_MATRIX_AB_ALLOCATOR_BAD_EVENT;
  }

  for (size_t reg = 0; reg < CORAL_MATRIX_AB_REG_COUNT; ++reg) {
    coral_matrix_ab_reg_state_t *state = &allocator->reg[reg];
    if (!state->allocated) {
      state->allocated = 1;
      state->operand_kind = (uint8_t)operand_kind;
      state->owner = owner;
      state->first_use_event = allocator->current_event;
      state->last_use_event = last_use_event;
      *reg_out = reg;
      return CORAL_MATRIX_AB_ALLOCATOR_OK;
    }
  }
  *reg_out = CORAL_MATRIX_AB_REG_NONE;
  return CORAL_MATRIX_AB_ALLOCATOR_NO_FREE_REG;
}

static inline int coral_matrix_ab_allocator_get(
    const coral_matrix_ab_allocator_t *allocator, size_t reg,
    coral_matrix_ab_reg_state_t *state_out) {
  if (allocator == NULL || state_out == NULL) {
    return CORAL_MATRIX_AB_ALLOCATOR_BAD_ARGUMENT;
  }
  if (reg >= CORAL_MATRIX_AB_REG_COUNT) {
    return CORAL_MATRIX_AB_ALLOCATOR_BAD_REG;
  }
  *state_out = allocator->reg[reg];
  return CORAL_MATRIX_AB_ALLOCATOR_OK;
}

#endif
