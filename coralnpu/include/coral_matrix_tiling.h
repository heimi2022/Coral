#ifndef CORAL_MATRIX_TILING_H_
#define CORAL_MATRIX_TILING_H_

#include <stddef.h>

/* MatrixCore's architectural tile and scale-group boundaries. */
#define CORAL_MATRIX_TILE_M 64U
#define CORAL_MATRIX_TILE_N 64U
#define CORAL_MATRIX_TILE_K 64U
#define CORAL_MATRIX_SCALE_GROUP_K 32U
#define CORAL_MATRIX_N_GROUP_TILES 4U

#define CORAL_MATRIX_TILING_OK 0
#define CORAL_MATRIX_TILING_BAD_ARGUMENT (-1)
#define CORAL_MATRIX_TILING_BAD_K (-2)

typedef struct {
  size_t m;
  size_t n;
  size_t k;
  size_t m_tiles;
  size_t n_groups;
  size_t k_tiles;
  size_t scale_groups;
} coral_matrix_tiling_plan_t;

typedef struct {
  size_t index;
  size_t offset;
  size_t size;
} coral_matrix_m_tile_t;

typedef struct {
  size_t m_index;
  size_t n_group_index;
  size_t m_offset;
  size_t m_size;
  size_t n_offset;
  size_t n_size;
  size_t n_tiles;
} coral_matrix_n_group_t;

typedef struct {
  size_t slot;
  size_t offset;
  size_t size;
} coral_matrix_n_tile_t;

typedef struct {
  size_t index;
  size_t offset;
  size_t size;
  size_t compute_size;
  size_t scale_group;
  size_t scale_group_count;
} coral_matrix_k_tile_t;

static inline size_t coral_matrix_tiling_ceil_div(size_t value,
                                                  size_t divisor) {
  return value / divisor + (value % divisor != 0);
}

static inline size_t coral_matrix_tiling_min(size_t lhs, size_t rhs) {
  return lhs < rhs ? lhs : rhs;
}

static inline int coral_matrix_tiling_plan_init(
    coral_matrix_tiling_plan_t *plan, size_t m, size_t n, size_t k) {
  if (plan == NULL || m == 0 || n == 0 || k == 0) {
    return CORAL_MATRIX_TILING_BAD_ARGUMENT;
  }
  plan->m = m;
  plan->n = n;
  plan->k = k;
  plan->m_tiles = coral_matrix_tiling_ceil_div(m, CORAL_MATRIX_TILE_M);
  plan->n_groups = coral_matrix_tiling_ceil_div(
      n, CORAL_MATRIX_TILE_N * CORAL_MATRIX_N_GROUP_TILES);
  plan->k_tiles = coral_matrix_tiling_ceil_div(k, CORAL_MATRIX_TILE_K);
  plan->scale_groups = coral_matrix_tiling_ceil_div(
      k, CORAL_MATRIX_SCALE_GROUP_K);
  return CORAL_MATRIX_TILING_OK;
}

static inline int coral_matrix_tiling_get_m_tile(
    const coral_matrix_tiling_plan_t *plan, size_t index,
    coral_matrix_m_tile_t *tile) {
  if (plan == NULL || tile == NULL || index >= plan->m_tiles) {
    return CORAL_MATRIX_TILING_BAD_ARGUMENT;
  }

  tile->index = index;
  tile->offset = index * CORAL_MATRIX_TILE_M;
  tile->size = coral_matrix_tiling_min(
      CORAL_MATRIX_TILE_M, plan->m - tile->offset);
  return CORAL_MATRIX_TILING_OK;
}

static inline int coral_matrix_tiling_get_n_group(
    const coral_matrix_tiling_plan_t *plan, size_t m_index,
    size_t n_group_index, coral_matrix_n_group_t *group) {
  coral_matrix_m_tile_t m_tile;
  if (group == NULL ||
      coral_matrix_tiling_get_m_tile(plan, m_index, &m_tile) !=
          CORAL_MATRIX_TILING_OK ||
      n_group_index >= plan->n_groups) {
    return CORAL_MATRIX_TILING_BAD_ARGUMENT;
  }

  group->m_index = m_index;
  group->n_group_index = n_group_index;
  group->m_offset = m_tile.offset;
  group->m_size = m_tile.size;
  group->n_offset = n_group_index *
                    CORAL_MATRIX_TILE_N * CORAL_MATRIX_N_GROUP_TILES;
  group->n_size = coral_matrix_tiling_min(
      CORAL_MATRIX_TILE_N * CORAL_MATRIX_N_GROUP_TILES,
      plan->n - group->n_offset);
  group->n_tiles = coral_matrix_tiling_ceil_div(
      group->n_size, CORAL_MATRIX_TILE_N);
  return CORAL_MATRIX_TILING_OK;
}

static inline int coral_matrix_tiling_get_n_tile(
    const coral_matrix_n_group_t *group, size_t slot,
    coral_matrix_n_tile_t *tile) {
  if (group == NULL || tile == NULL || slot >= group->n_tiles) {
    return CORAL_MATRIX_TILING_BAD_ARGUMENT;
  }

  tile->slot = slot;
  tile->offset = group->n_offset + slot * CORAL_MATRIX_TILE_N;
  tile->size = coral_matrix_tiling_min(
      CORAL_MATRIX_TILE_N, group->n_size - slot * CORAL_MATRIX_TILE_N);
  return CORAL_MATRIX_TILING_OK;
}

static inline int coral_matrix_tiling_get_k_tile(
    const coral_matrix_tiling_plan_t *plan, size_t index,
    coral_matrix_k_tile_t *tile) {
  if (plan == NULL || tile == NULL || index >= plan->k_tiles) {
    return CORAL_MATRIX_TILING_BAD_ARGUMENT;
  }

  tile->index = index;
  tile->offset = index * CORAL_MATRIX_TILE_K;
  tile->size = coral_matrix_tiling_min(
      CORAL_MATRIX_TILE_K, plan->k - tile->offset);
  tile->compute_size = coral_matrix_tiling_ceil_div(
      tile->size, CORAL_MATRIX_SCALE_GROUP_K) * CORAL_MATRIX_SCALE_GROUP_K;
  tile->scale_group = tile->offset / CORAL_MATRIX_SCALE_GROUP_K;
  tile->scale_group_count = tile->compute_size / CORAL_MATRIX_SCALE_GROUP_K;
  return CORAL_MATRIX_TILING_OK;
}

#endif
