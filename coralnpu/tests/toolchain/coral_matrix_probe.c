#include "coral_matrix_asm.h"

void coral_matrix_probe(void) {
    coral_msettileki(33);
    coral_msettilem_reg(5);
    coral_msettileni(17);

    CORAL_MATRIX_MZERO_ONE(4);
    coral_mmacc_w_b(1, 2, 4);
    coral_mmaccu_w_b(2, 3, 5);
    coral_mmaccus_w_b(3, 4, 6);
    coral_mmaccsu_w_b(4, 5, 7);

    coral_mld_a(2, 10, 11, 2);
    coral_mst_b(1, 10, 11, 3);
    coral_mld_c(2, 10, 11, 4);
}
