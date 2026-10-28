#ifndef CORAL_MATRIX_GEMM_H_
#define CORAL_MATRIX_GEMM_H_

#include <stddef.h>
#include <stdint.h>

#include "coral_matrix.h"
#include "coral_matrix_tiling.h"

/*
 * Software tiled MXINT8 GEMM for MatrixCore.
 *
 * A is stored as M rows of K int8 elements. B is stored transposed as N rows
 * of K int8 elements, matching the FIR/weight input direction in MatrixCore.
 * The scale arrays have ceil(K/32) rows: a_scale[g][m] and b_scale[g][n].
 * K is the logical dimension. Zero-pad both inputs to round_up(K,32) before
 * submission; the final partial group retains its original scale. See
 * coral_matrix_gemm_layout.h for storage sizes and the padding helper.
 * C is an FP32 row-major output produced by msce32.
 *
 * A single MatrixCore command supports at most 64 rows, 64 columns and 64 K
 * elements. coral_gemm_mx_multicreg() keeps up to four N tiles live in
 * C0..C3. The software hot path alternates the A tile between physical AB0
 * and AB2 for successive K tiles. The three B tiles use the complementary
 * registers, and the fourth B tile reuses the first B register. The four AB
 * registers remain architecturally symmetric; this mapping is only a compact
 * software schedule, not an architectural restriction.
 * The final N tile may be narrower than 64 columns; its width is programmed
 * independently for that tile's MMACC and store.
 * Strides are measured in bytes and must be 64-byte multiples. This keeps
 * every tile origin aligned for the current MatrixCore DMA interface. The
 * output stride may be larger than N*sizeof(float), but must retain the
 * 64-byte DMA alignment required by MatrixCore.
 */

#define CORAL_GEMM_MX_OK 0
#define CORAL_GEMM_MX_BAD_ARGUMENT (-1)
#define CORAL_GEMM_MX_BAD_K (-2)
#define CORAL_GEMM_MX_BAD_STRIDE (-3)
#define CORAL_GEMM_MX_BAD_ALIGNMENT (-4)
#define CORAL_GEMM_MX_BAD_SCHEDULE (-5)

/*
 * Public GEMM descriptor. All strides are byte strides. A is row-major
 * [M][K], B is transposed [N][K], and C is row-major FP32 [M][N]. Scale
 * storage is [ceil(K/32)][M] for A and [ceil(K/32)][N] for B. Both input
 * buffers must contain zero padding through round_up(K,32).
 */
typedef struct {
  const int8_t *a;
  size_t lda;
  const int8_t *b_transposed;
  size_t ldb;
  const uint8_t *a_scale;
  size_t a_scale_stride;
  const uint8_t *b_scale;
  size_t b_scale_stride;
  float *c;
  size_t ldc;
  size_t m;
  size_t n;
  size_t k;
} coral_matrix_gemm_desc_t;

static inline int coral_gemm_mx_validate(
    const int8_t *a, size_t lda,
    const int8_t *b_transposed, size_t ldb,
    const uint8_t *a_scale, size_t a_scale_stride,
    const uint8_t *b_scale, size_t b_scale_stride,
    const float *c, size_t ldc,
    size_t m, size_t n, size_t k) {
  if (a == NULL || b_transposed == NULL || a_scale == NULL ||
      b_scale == NULL || c == NULL || m == 0 || n == 0 || k == 0) {
    return CORAL_GEMM_MX_BAD_ARGUMENT;
  }
  if (k > SIZE_MAX - (CORAL_MATRIX_SCALE_GROUP_K - 1)) {
    return CORAL_GEMM_MX_BAD_K;
  }
  const size_t compute_k = coral_matrix_tiling_ceil_div(
      k, CORAL_MATRIX_SCALE_GROUP_K) * CORAL_MATRIX_SCALE_GROUP_K;
  const size_t scale_groups = coral_matrix_tiling_ceil_div(
      k, CORAL_MATRIX_SCALE_GROUP_K);
  if (n > SIZE_MAX / sizeof(float) ||
      lda < compute_k || ldb < compute_k || a_scale_stride < m ||
      b_scale_stride < n || ldc < n * sizeof(float)) {
    return CORAL_GEMM_MX_BAD_STRIDE;
  }
  if ((lda | ldb | a_scale_stride | b_scale_stride | ldc) & 63U) {
    return CORAL_GEMM_MX_BAD_STRIDE;
  }
  if (m > SIZE_MAX / lda || n > SIZE_MAX / ldb || m > SIZE_MAX / ldc ||
      scale_groups > SIZE_MAX / a_scale_stride ||
      scale_groups > SIZE_MAX / b_scale_stride) {
    return CORAL_GEMM_MX_BAD_STRIDE;
  }
  if ((((uintptr_t)a | (uintptr_t)b_transposed | (uintptr_t)a_scale |
        (uintptr_t)b_scale | (uintptr_t)c) & 63U) != 0) {
    return CORAL_GEMM_MX_BAD_ALIGNMENT;
  }
  return CORAL_GEMM_MX_OK;
}

static inline int coral_matrix_gemm_validate(
    const coral_matrix_gemm_desc_t *desc) {
  if (desc == NULL) {
    return CORAL_GEMM_MX_BAD_ARGUMENT;
  }
  return coral_gemm_mx_validate(
      desc->a, desc->lda, desc->b_transposed, desc->ldb,
      desc->a_scale, desc->a_scale_stride, desc->b_scale,
      desc->b_scale_stride, desc->c, desc->ldc,
      desc->m, desc->n, desc->k);
}

/*
 * Decode waits for the CONFIG CSR write before accepting a dependent matrix
 * command. Each accepted command snapshots its own shape; CONFIG does not
 * wait for older matrix operations to finish.
 */
static inline void coral_gemm_mx_set_n(size_t tile_n) {
  coral_msettilen(tile_n);
}

/*
 * Static register plan used by the multicreg scheduler. These helpers do not
 * track register liveness; MatrixCore's scoreboard remains authoritative for
 * an overwrite that still has an older MMACC user.
 */
static inline unsigned coral_gemm_mx_a_reg_for_k_tile(size_t k_tile) {
  return (unsigned)((k_tile & 1U) != 0 ? CORAL_A2 : CORAL_A0);
}

static inline unsigned coral_gemm_mx_b_reg_for_k_tile(
    size_t k_tile, size_t n_slot) {
  const unsigned a_reg = coral_gemm_mx_a_reg_for_k_tile(k_tile);
  if (a_reg == CORAL_A0) {
    static const unsigned b_regs[] = {CORAL_B1, CORAL_B2, CORAL_B3,
                                      CORAL_B1};
    return b_regs[n_slot & 3U];
  }
  static const unsigned b_regs[] = {CORAL_B3, CORAL_B0, CORAL_B1,
                                    CORAL_B3};
  return b_regs[n_slot & 3U];
}

/* Emit one N tile while keeping all matrix-register operands compile-time. */
#define CORAL_GEMM_MX_ISSUE_N_TILE(A_REG, B_REG, C_REG, ACTIVE, N_COL) \
  do {                                                                    \
    if (ACTIVE) {                                                         \
      const size_t coral_gemm_n_col = (N_COL);                            \
      const size_t coral_gemm_tile_n = coral_matrix_tiling_min(            \
          n - coral_gemm_n_col, CORAL_MATRIX_TILE_N);                     \
      if (!full_n_group) coral_gemm_mx_set_n(coral_gemm_tile_n);           \
      coral_mlbe8(                                                        \
          (B_REG),                                                         \
          (const void *)(b_transposed + coral_gemm_n_col * ldb + k0),      \
          ldb);                                                            \
      coral_mlbte8(                                                        \
          (B_REG),                                                         \
          (const void *)(b_scale + group * b_scale_stride +                 \
                         coral_gemm_n_col),                                \
          b_scale_stride);                                                 \
      if (k0 == 0) coral_mzero(C_REG);                                    \
      coral_mmacc_w_b((C_REG), (B_REG), (A_REG));                         \
      if (final_k_tile) {                                                 \
        CORAL_GEMM_MX_STORE_FULL_N_TILE((C_REG), coral_gemm_n_col);         \
      }                                                                  \
    }                                                                      \
  } while (0)

/* Fast path for a complete four-tile N group.  The caller has already
 * programmed N=64, so there is no per-tile width calculation or ACTIVE test.
 * K_OFFSET and SCALE_GROUP are explicit so this macro can issue two K tiles
 * back-to-back without relying on the outer loop's k0/group variables.
 * On the final K tile, load the next B and issue its MMACC before storing
 * the previous C.
 * At the end of a full K tile, prefetch the next group's A0/B1 before the
 * pending C stores. A0 can move early only when M stays the same size; B1 is
 * independent of M.
 * DEFER_PREVIOUS_STORE lets the caller issue the next group's C0 before
 * flushing the current C2/C3 stores.
 */
#define CORAL_GEMM_MX_ISSUE_FULL_N_TILE_AT(                                \
    A_REG, B_REG, C_REG, N_COL, K_OFFSET, SCALE_GROUP, CLEAR_C,              \
    DEFER_PREVIOUS_STORE)                                                    \
  do {                                                                      \
    CORAL_GEMM_MX_LOAD_FULL_B((B_REG), (N_COL), (K_OFFSET), (SCALE_GROUP)); \
    if (CLEAR_C) coral_mzero(C_REG);                                       \
    coral_mmacc_w_b((C_REG), (B_REG), (A_REG));                             \
    if (final_k_tile && (C_REG) == CORAL_C3 &&                            \
        (A_REG) == CORAL_A2 && prefetch_next_group) {                      \
      if (next_tile_m == tile_m) {                                        \
        CORAL_GEMM_MX_LOAD_FULL_A_AT(CORAL_A0, next_m0, 0, 0);             \
        prefetched_a0 = 1;                                                 \
      }                                                                    \
      CORAL_GEMM_MX_LOAD_FULL_B(CORAL_B1, next_n0, 0, 0);                  \
      prefetched_b1_c0 = 1;                                                \
    }                                                                      \
    if (final_k_tile && (C_REG) != CORAL_C0 &&                             \
        !(DEFER_PREVIOUS_STORE)) {                                         \
      CORAL_GEMM_MX_STORE_FULL_N_TILE(                                     \
          (C_REG) == CORAL_C0 ? CORAL_C0 : (C_REG) - 1,                   \
          (N_COL) - CORAL_MATRIX_TILE_N);                                 \
    }                                                                      \
  } while (0)

#define CORAL_GEMM_MX_LOAD_FULL_B(B_REG, N_COL, K_OFFSET, SCALE_GROUP)      \
  do {                                                                      \
    coral_mlbe8(                                                            \
        (B_REG),                                                             \
        (const void *)(b_transposed + (N_COL) * ldb + (K_OFFSET)),          \
        ldb);                                                               \
    coral_mlbte8(                                                           \
        (B_REG),                                                             \
        (const void *)(b_scale + (SCALE_GROUP) * b_scale_stride + (N_COL)), \
        b_scale_stride);                                                    \
  } while (0)

#define CORAL_GEMM_MX_ISSUE_FULL_N_TILE_LOADED(                             \
    A_REG, B_REG, C_REG, N_COL, CLEAR_C)                                     \
  do {                                                                      \
    if (CLEAR_C) coral_mzero(C_REG);                                       \
    coral_mmacc_w_b((C_REG), (B_REG), (A_REG));                             \
  } while (0)

#define CORAL_GEMM_MX_LOAD_FULL_A_AT(A_REG, M_ROW, K_OFFSET, SCALE_GROUP)   \
  do {                                                                      \
    coral_mlae8(                                                            \
        (A_REG), (const void *)(a + (M_ROW) * lda + (K_OFFSET)), lda);      \
    coral_mlate8(                                                           \
        (A_REG),                                                             \
        (const void *)(a_scale + (SCALE_GROUP) * a_scale_stride + (M_ROW)), \
        a_scale_stride);                                                    \
  } while (0)

#define CORAL_GEMM_MX_LOAD_FULL_A(A_REG, K_OFFSET, SCALE_GROUP)             \
  CORAL_GEMM_MX_LOAD_FULL_A_AT((A_REG), m0, (K_OFFSET), (SCALE_GROUP))

#define CORAL_GEMM_MX_ISSUE_FULL_N_GROUP(                                  \
    A_REG, B0_REG, B1_REG, B2_REG, B3_REG, K_OFFSET, SCALE_GROUP, CLEAR_C)  \
  do {                                                                      \
    coral_mlae8(                                                            \
        (A_REG), (const void *)(a + m0 * lda + (K_OFFSET)), lda);           \
    coral_mlate8(                                                           \
        (A_REG),                                                             \
        (const void *)(a_scale + (SCALE_GROUP) * a_scale_stride + m0),      \
        a_scale_stride);                                                    \
    CORAL_GEMM_MX_ISSUE_FULL_N_TILE_AT(                                     \
        (A_REG), (B0_REG), CORAL_C0, n0, (K_OFFSET), (SCALE_GROUP),         \
        (CLEAR_C), 0);                                                       \
    CORAL_GEMM_MX_ISSUE_FULL_N_TILE_AT(                                     \
        (A_REG), (B1_REG), CORAL_C1, n0 + CORAL_MATRIX_TILE_N,              \
        (K_OFFSET), (SCALE_GROUP), (CLEAR_C), 0);                            \
    CORAL_GEMM_MX_ISSUE_FULL_N_TILE_AT(                                     \
        (A_REG), (B2_REG), CORAL_C2, n0 + 2 * CORAL_MATRIX_TILE_N,           \
        (K_OFFSET), (SCALE_GROUP), (CLEAR_C), 0);                            \
    CORAL_GEMM_MX_ISSUE_FULL_N_TILE_AT(                                     \
        (A_REG), (B3_REG), CORAL_C3, n0 + 3 * CORAL_MATRIX_TILE_N,           \
        (K_OFFSET), (SCALE_GROUP), (CLEAR_C), 0);                            \
    if (final_k_tile) {                                                     \
      CORAL_GEMM_MX_STORE_FULL_N_TILE(                                     \
          CORAL_C3, n0 + 3 * CORAL_MATRIX_TILE_N);                          \
    }                                                                      \
  } while (0)

#define CORAL_GEMM_MX_STORE_FULL_N_TILE(C_REG, N_COL) \
  do {                                                                    \
    coral_msce32(                                                         \
        (C_REG),                                                           \
        (void *)((uint8_t *)c + m0 * ldc + (N_COL) * sizeof(float)),      \
        ldc);                                                              \
  } while (0)

/*
 * Four-C-register tiled GEMM.
 *
 * The software schedule deliberately uses a fixed two-phase physical plan:
 * even K tiles use A0 with B1/B2/B3/B1, and odd K tiles use A2 with
 * B3/B0/B1/B3. Results stay in C0..C3. This removes runtime allocator and
 * register-selection code from the hot path while avoiding a fixed A0 load at
 * every K boundary. The MatrixCore scoreboard still orders each overwrite
 * after older MMACCs that use that register.
 * Each C tile is cleared immediately before its first MMACC, after the B
 * loads have been issued, so a pending C store does not block those loads.
 * For a full four-tile N group, load the next B payload and scale and issue
 * its MMACC before storing the previous C. Tail groups store each
 * C directly after its final MMACC to retain that tile's configured width.
 * The scoreboard orders each store after the result.
 * With a full next N group, the next A0/B1 loads precede the remaining C
 * stores for both even and odd final K phases. M changes remain after the old
 * stores; a shorter next M tile delays only the A0 load. Partial K tails use
 * the general path and retain its shape-specific ordering.
 * When the next M tile has the same row count, a complete next N group also
 * issues its first MZERO C0 and MMACC before the old C2/C3 stores. The next
 * iteration skips that already-issued MMACC; the scoreboard orders C0 reuse
 * after its store. A shorter M tail keeps the conservative ordering.
 */
static inline int coral_gemm_mx_multicreg(
    const int8_t *a, size_t lda,
    const int8_t *b_transposed, size_t ldb,
    const uint8_t *a_scale, size_t a_scale_stride,
    const uint8_t *b_scale, size_t b_scale_stride,
    float *c, size_t ldc,
    size_t m, size_t n, size_t k) {
  int validation = coral_gemm_mx_validate(
      a, lda, b_transposed, ldb, a_scale, a_scale_stride,
      b_scale, b_scale_stride, c, ldc, m, n, k);
  if (validation != CORAL_GEMM_MX_OK) {
    return validation;
  }

  /* With a full K dimension, every K tile has the same hardware shape. */
  const int all_k_tiles_full = (k % CORAL_MATRIX_TILE_K) == 0;
  if (all_k_tiles_full) {
    coral_msettilek(CORAL_MATRIX_TILE_K);
  }

  /* If N has no tail, its shape is stable for the entire GEMM. */
  const int all_n_tiles_full = (n % CORAL_MATRIX_TILE_N) == 0;
  const int all_n_groups_full =
      (n % (CORAL_MATRIX_TILE_N * CORAL_MATRIX_N_GROUP_TILES)) == 0;
  const int all_m_tiles_full = (m % CORAL_MATRIX_TILE_M) == 0;
  if (all_n_tiles_full) {
    coral_gemm_mx_set_n(CORAL_MATRIX_TILE_N);
  }

  int next_m_tile_already_configured = 0;
  int prefetched_a0 = 0;
  int prefetched_b1_c0 = 0;
  int prefetched_c0_issued = 0;
  /* Keep one group loop across M boundaries so invariant B addresses and
   * strides do not need an outer-loop reinitialization before each M tile. */
  for (size_t m0 = 0, n0 = 0; m0 < m;) {
    const size_t tile_m = all_m_tiles_full ? CORAL_MATRIX_TILE_M :
        coral_matrix_tiling_min(m - m0, CORAL_MATRIX_TILE_M);

    /* M is constant for every N/K tile in this M tile. */
    if (n0 == 0 && !next_m_tile_already_configured) {
      coral_msettilem(tile_m);
    }
    next_m_tile_already_configured = 0;

    const size_t remaining_tiles = coral_matrix_tiling_ceil_div(
        n - n0, CORAL_MATRIX_TILE_N);
    const size_t n_tiles = all_n_groups_full ? CORAL_MATRIX_N_GROUP_TILES :
        coral_matrix_tiling_min(remaining_tiles, CORAL_MATRIX_N_GROUP_TILES);
    const size_t group_columns = coral_matrix_tiling_min(
        n - n0, CORAL_MATRIX_TILE_N * CORAL_MATRIX_N_GROUP_TILES);
    const int full_n_group = all_n_tiles_full ||
        group_columns == n_tiles * CORAL_MATRIX_TILE_N;
    const size_t group_n_width =
        CORAL_MATRIX_TILE_N * CORAL_MATRIX_N_GROUP_TILES;
    const int next_group_in_same_m = n0 + group_n_width < n;
    const size_t next_m0 = next_group_in_same_m ? m0 : m0 + tile_m;
    const size_t next_n0 = next_group_in_same_m ? n0 + group_n_width : 0;
    const size_t next_tile_m = next_m0 < m ?
        (all_m_tiles_full ? CORAL_MATRIX_TILE_M : coral_matrix_tiling_min(
            m - next_m0, CORAL_MATRIX_TILE_M)) : 0;
    const int prefetch_next_group =
        full_n_group && n_tiles == CORAL_MATRIX_N_GROUP_TILES &&
        all_k_tiles_full && next_m0 < m && n - next_n0 >= group_n_width;
    const int overlap_next_group =
        prefetch_next_group && next_tile_m == tile_m;

    /* A full group keeps N=64 for every MATMUL and its stores. */
    if (full_n_group && !all_n_tiles_full) {
      coral_gemm_mx_set_n(CORAL_MATRIX_TILE_N);
    }

    if (full_n_group && n_tiles == CORAL_MATRIX_N_GROUP_TILES &&
        all_k_tiles_full) {
      /* Unroll two K tiles. Keep next-group prefetches after the current
       * group's last MATMUL so register reuse cannot block its issue. */
      size_t k0 = 0;
      size_t group = 0;
      int even_a_ready = 0;
      while (k0 < k) {
        const size_t odd_k0 = k0 + CORAL_MATRIX_TILE_K;
        const size_t odd_group = group +
            CORAL_MATRIX_TILE_K / CORAL_MATRIX_SCALE_GROUP_K;
        const int has_odd = odd_k0 < k;
        int final_k_tile = !has_odd;
        const int clear_c = k0 == 0;
        const int first_b1_c0_ready = prefetched_b1_c0;
        const int first_c0_already_issued = prefetched_c0_issued;

        if (k0 == 0) even_a_ready = prefetched_a0;
        prefetched_a0 = 0;
        prefetched_b1_c0 = 0;
        prefetched_c0_issued = 0;

        if (!even_a_ready) {
          CORAL_GEMM_MX_LOAD_FULL_A(CORAL_A0, k0, group);
        }
        even_a_ready = 0;
        if (k0 == 0 && first_b1_c0_ready && !first_c0_already_issued) {
          CORAL_GEMM_MX_ISSUE_FULL_N_TILE_LOADED(
              CORAL_A0, CORAL_B1, CORAL_C0, n0, clear_c);
        } else if (!first_c0_already_issued) {
          CORAL_GEMM_MX_ISSUE_FULL_N_TILE_AT(
              CORAL_A0, CORAL_B1, CORAL_C0, n0, k0, group, clear_c, 0);
        }
        CORAL_GEMM_MX_ISSUE_FULL_N_TILE_AT(
            CORAL_A0, CORAL_B2, CORAL_C1,
            n0 + CORAL_MATRIX_TILE_N, k0, group, clear_c, 0);
        CORAL_GEMM_MX_ISSUE_FULL_N_TILE_AT(
            CORAL_A0, CORAL_B3, CORAL_C2,
            n0 + 2 * CORAL_MATRIX_TILE_N, k0, group, clear_c, 0);
        CORAL_GEMM_MX_LOAD_FULL_B(
            CORAL_B1, n0 + 3 * CORAL_MATRIX_TILE_N, k0, group);

        /* A2 shares physical reg2 with the current B2. Issue the final
         * even MATMUL before a conflicting A2 load can block dispatch. */
        CORAL_GEMM_MX_ISSUE_FULL_N_TILE_LOADED(
            CORAL_A0, CORAL_B1, CORAL_C3,
            n0 + 3 * CORAL_MATRIX_TILE_N, clear_c);
        /* A2 is needed by the next odd K tile and can be loaded after the
         * current even tile has finished issuing. */
        if (has_odd) {
          CORAL_GEMM_MX_LOAD_FULL_A(CORAL_A2, odd_k0, odd_group);
        }
        if (final_k_tile) {
          if (prefetch_next_group) {
            if (next_tile_m == tile_m) {
              CORAL_GEMM_MX_LOAD_FULL_A_AT(CORAL_A0, next_m0, 0, 0);
              prefetched_a0 = 1;
            }
            CORAL_GEMM_MX_LOAD_FULL_B(CORAL_B1, next_n0, 0, 0);
            prefetched_b1_c0 = 1;
            if (overlap_next_group) {
              coral_mzero(CORAL_C0);
              coral_mmacc_w_b(CORAL_C0, CORAL_B1, CORAL_A0);
              prefetched_c0_issued = 1;
            }
          }
          CORAL_GEMM_MX_STORE_FULL_N_TILE(
              CORAL_C2, n0 + 2 * CORAL_MATRIX_TILE_N);
          CORAL_GEMM_MX_STORE_FULL_N_TILE(
              CORAL_C3, n0 + 3 * CORAL_MATRIX_TILE_N);
        }

        if (!has_odd) break;

        final_k_tile = odd_k0 + CORAL_MATRIX_TILE_K == k;

        /* The scoreboard orders the B3 overwrite after its even use. */
        CORAL_GEMM_MX_ISSUE_FULL_N_TILE_AT(
            CORAL_A2, CORAL_B3, CORAL_C0, n0, odd_k0, odd_group, 0, 0);
        CORAL_GEMM_MX_ISSUE_FULL_N_TILE_AT(
            CORAL_A2, CORAL_B0, CORAL_C1,
            n0 + CORAL_MATRIX_TILE_N, odd_k0, odd_group, 0, 0);

        if (final_k_tile) {
          CORAL_GEMM_MX_ISSUE_FULL_N_TILE_AT(
              CORAL_A2, CORAL_B1, CORAL_C2,
              n0 + 2 * CORAL_MATRIX_TILE_N, odd_k0, odd_group, 0, 0);
          /* After C3, prefetch A0/B1. If the next group keeps the same
           * row shape, issue its C0 before flushing C2/C3; otherwise store
           * C2 here before changing the M dimension. */
          CORAL_GEMM_MX_ISSUE_FULL_N_TILE_AT(
              CORAL_A2, CORAL_B3, CORAL_C3,
              n0 + 3 * CORAL_MATRIX_TILE_N, odd_k0, odd_group, 0,
              overlap_next_group);
          if (overlap_next_group) {
            coral_mzero(CORAL_C0);
            coral_mmacc_w_b(CORAL_C0, CORAL_B1, CORAL_A0);
            prefetched_c0_issued = 1;
            CORAL_GEMM_MX_STORE_FULL_N_TILE(
                CORAL_C2, n0 + 2 * CORAL_MATRIX_TILE_N);
          }
          CORAL_GEMM_MX_STORE_FULL_N_TILE(
              CORAL_C3, n0 + 3 * CORAL_MATRIX_TILE_N);
        } else {
          /* Retain the existing lookahead for another K tile within
           * this group: queue both current B loads before the A load. */
          CORAL_GEMM_MX_LOAD_FULL_B(
              CORAL_B1, n0 + 2 * CORAL_MATRIX_TILE_N, odd_k0, odd_group);
          CORAL_GEMM_MX_LOAD_FULL_B(
              CORAL_B3, n0 + 3 * CORAL_MATRIX_TILE_N, odd_k0, odd_group);
          const size_t next_k0 = odd_k0 + CORAL_MATRIX_TILE_K;
          const size_t next_group = odd_group +
              CORAL_MATRIX_TILE_K / CORAL_MATRIX_SCALE_GROUP_K;
          CORAL_GEMM_MX_LOAD_FULL_A(CORAL_A0, next_k0, next_group);
          even_a_ready = 1;
          CORAL_GEMM_MX_ISSUE_FULL_N_TILE_LOADED(
              CORAL_A2, CORAL_B1, CORAL_C2,
              n0 + 2 * CORAL_MATRIX_TILE_N, 0);
          CORAL_GEMM_MX_ISSUE_FULL_N_TILE_LOADED(
              CORAL_A2, CORAL_B3, CORAL_C3,
              n0 + 3 * CORAL_MATRIX_TILE_N, 0);
        }

        k0 = odd_k0 + CORAL_MATRIX_TILE_K;
        group = odd_group + CORAL_MATRIX_TILE_K /
            CORAL_MATRIX_SCALE_GROUP_K;
      }
    } else {
      for (size_t k0 = 0; k0 < k;) {
        const size_t logical_tile_k = coral_matrix_tiling_min(
            k - k0, CORAL_MATRIX_TILE_K);
        const size_t tile_k = coral_matrix_tiling_ceil_div(
            logical_tile_k, CORAL_MATRIX_SCALE_GROUP_K) *
            CORAL_MATRIX_SCALE_GROUP_K;
        const size_t group = k0 / CORAL_MATRIX_SCALE_GROUP_K;
        const int final_k_tile = logical_tile_k == k - k0;

        if (!all_k_tiles_full) {
          coral_msettilek(tile_k);
        }

        const size_t k_tile_index = k0 / CORAL_MATRIX_TILE_K;
        if (full_n_group && n_tiles == CORAL_MATRIX_N_GROUP_TILES &&
            (k_tile_index & 1U) == 0) {
          CORAL_GEMM_MX_ISSUE_FULL_N_GROUP(
              CORAL_A0, CORAL_B1, CORAL_B2, CORAL_B3, CORAL_B1,
              k0, group, k0 == 0);
        } else if (full_n_group && n_tiles == CORAL_MATRIX_N_GROUP_TILES &&
                   (k_tile_index & 1U) != 0) {
          CORAL_GEMM_MX_ISSUE_FULL_N_GROUP(
              CORAL_A2, CORAL_B3, CORAL_B0, CORAL_B1, CORAL_B3,
              k0, group, 0);
        } else if ((k_tile_index & 1U) == 0) {
          coral_mlae8(CORAL_A0, (const void *)(a + m0 * lda + k0), lda);
          coral_mlate8(
              CORAL_A0,
              (const void *)(a_scale + group * a_scale_stride + m0),
              a_scale_stride);
          CORAL_GEMM_MX_ISSUE_N_TILE(CORAL_A0, CORAL_B1, CORAL_C0,
                                     n_tiles >= 1, n0);
          CORAL_GEMM_MX_ISSUE_N_TILE(CORAL_A0, CORAL_B2, CORAL_C1,
                                     n_tiles >= 2,
                                     n0 + CORAL_MATRIX_TILE_N);
          CORAL_GEMM_MX_ISSUE_N_TILE(CORAL_A0, CORAL_B3, CORAL_C2,
                                     n_tiles >= 3,
                                     n0 + 2 * CORAL_MATRIX_TILE_N);
          CORAL_GEMM_MX_ISSUE_N_TILE(CORAL_A0, CORAL_B1, CORAL_C3,
                                     n_tiles >= 4,
                                     n0 + 3 * CORAL_MATRIX_TILE_N);
        } else {
          coral_mlae8(CORAL_A2, (const void *)(a + m0 * lda + k0), lda);
          coral_mlate8(
              CORAL_A2,
              (const void *)(a_scale + group * a_scale_stride + m0),
              a_scale_stride);
          CORAL_GEMM_MX_ISSUE_N_TILE(CORAL_A2, CORAL_B3, CORAL_C0,
                                     n_tiles >= 1, n0);
          CORAL_GEMM_MX_ISSUE_N_TILE(CORAL_A2, CORAL_B0, CORAL_C1,
                                     n_tiles >= 2,
                                     n0 + CORAL_MATRIX_TILE_N);
          CORAL_GEMM_MX_ISSUE_N_TILE(CORAL_A2, CORAL_B1, CORAL_C2,
                                     n_tiles >= 3,
                                     n0 + 2 * CORAL_MATRIX_TILE_N);
          CORAL_GEMM_MX_ISSUE_N_TILE(CORAL_A2, CORAL_B3, CORAL_C3,
                                     n_tiles >= 4,
                                     n0 + 3 * CORAL_MATRIX_TILE_N);
        }
        k0 += logical_tile_k;
      }
    }

    /* Odd final K tiles prefetch A0/B1 before STORE C2/C3. Finish any
     * remaining loads here. Keep M changes after the old stores so each
     * store sees the old row count, even when the next M tile is short. */
    if (prefetch_next_group) {
      if (next_m0 != m0) {
        if (next_tile_m != tile_m) {
          coral_msettilem(next_tile_m);
        }
        /* The next tile either received its new shape above or reuses the
         * current shape without another CONFIG instruction. */
        next_m_tile_already_configured = 1;
      }
      if (!prefetched_a0) {
        CORAL_GEMM_MX_LOAD_FULL_A_AT(CORAL_A0, next_m0, 0, 0);
      }
      if (!prefetched_b1_c0) {
        CORAL_GEMM_MX_LOAD_FULL_B(CORAL_B1, next_n0, 0, 0);
      }
      prefetched_a0 = 1;
      prefetched_b1_c0 = 1;
    }
    n0 += coral_matrix_tiling_min(
        n - n0, CORAL_MATRIX_TILE_N * CORAL_MATRIX_N_GROUP_TILES);
    if (n0 == n) {
      m0 += tile_m;
      n0 = 0;
    }
  }
  return CORAL_GEMM_MX_OK;
}

#undef CORAL_GEMM_MX_ISSUE_N_TILE
#undef CORAL_GEMM_MX_LOAD_FULL_A
#undef CORAL_GEMM_MX_LOAD_FULL_A_AT
#undef CORAL_GEMM_MX_LOAD_FULL_B
#undef CORAL_GEMM_MX_ISSUE_FULL_N_TILE_LOADED
#undef CORAL_GEMM_MX_ISSUE_FULL_N_TILE_AT
#undef CORAL_GEMM_MX_ISSUE_FULL_N_GROUP
#undef CORAL_GEMM_MX_STORE_FULL_N_TILE

static inline int coral_matrix_gemm_multicreg_run(
    const coral_matrix_gemm_desc_t *desc) {
  int validation = coral_matrix_gemm_validate(desc);
  if (validation != CORAL_GEMM_MX_OK) {
    return validation;
  }
  return coral_gemm_mx_multicreg(
      desc->a, desc->lda, desc->b_transposed, desc->ldb,
      desc->a_scale, desc->a_scale_stride, desc->b_scale,
      desc->b_scale_stride, desc->c, desc->ldc,
      desc->m, desc->n, desc->k);
}

#endif
