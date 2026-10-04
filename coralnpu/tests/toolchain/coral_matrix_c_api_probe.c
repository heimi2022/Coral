#include "coral_matrix.h"

void coral_matrix_c_api_probe(void *base, uintptr_t stride) {
    coral_msettileki(33);
    coral_msettilemi(2);
    coral_msettileni(33);
    coral_msettilek(32);
    coral_msettilem(2);
    coral_msettilen(33);

    coral_mzero(CORAL_C0);
    coral_mzero2r(CORAL_C0);
    coral_mzero4r(CORAL_C0);
    coral_mzero8r(CORAL_M0);

    coral_mmacc_w_b(CORAL_C0, CORAL_B1, CORAL_A2);
    coral_mmaccu_w_b(CORAL_C1, CORAL_B2, CORAL_A3);
    coral_mmaccus_w_b(CORAL_C2, CORAL_B3, CORAL_A0);
    coral_mmaccsu_w_b(CORAL_C3, CORAL_B0, CORAL_A1);

    coral_mlae8(CORAL_A0, base, stride);
    coral_mlae16(CORAL_A1, base, stride);
    coral_mlae32(CORAL_A2, base, stride);
    coral_mlae64(CORAL_A3, base, stride);
    coral_msae8(CORAL_A0, base, stride);
    coral_msae16(CORAL_A1, base, stride);
    coral_msae32(CORAL_A2, base, stride);
    coral_msae64(CORAL_A3, base, stride);

    coral_mlbe8(CORAL_B0, base, stride);
    coral_mlbe16(CORAL_B1, base, stride);
    coral_mlbe32(CORAL_B2, base, stride);
    coral_mlbe64(CORAL_B3, base, stride);
    coral_msbe8(CORAL_B0, base, stride);
    coral_msbe16(CORAL_B1, base, stride);
    coral_msbe32(CORAL_B2, base, stride);
    coral_msbe64(CORAL_B3, base, stride);

    coral_mlce8(CORAL_C0, base, stride);
    coral_mlce16(CORAL_C1, base, stride);
    coral_mlce32(CORAL_C2, base, stride);
    coral_mlce64(CORAL_C3, base, stride);
    coral_msce8(CORAL_C0, base, stride);
    coral_msce16(CORAL_C1, base, stride);
    coral_msce32(CORAL_C2, base, stride);
    coral_msce64(CORAL_C3, base, stride);

    coral_mlme8(CORAL_M0, base);
    coral_mlme16(CORAL_M1, base);
    coral_mlme32(CORAL_M2, base);
    coral_mlme64(CORAL_M3, base);
    coral_msme8(CORAL_M4, base);
    coral_msme16(CORAL_M5, base);
    coral_msme32(CORAL_M6, base);
    coral_msme64(CORAL_M7, base);

    coral_mlate8(CORAL_A0, base, stride);
    coral_mlate16(CORAL_A1, base, stride);
    coral_mlate32(CORAL_A2, base, stride);
    coral_mlate64(CORAL_A3, base, stride);
    coral_msate8(CORAL_A0, base, stride);
    coral_msate16(CORAL_A1, base, stride);
    coral_msate32(CORAL_A2, base, stride);
    coral_msate64(CORAL_A3, base, stride);

    coral_mlbte8(CORAL_B0, base, stride);
    coral_mlbte16(CORAL_B1, base, stride);
    coral_mlbte32(CORAL_B2, base, stride);
    coral_mlbte64(CORAL_B3, base, stride);
    coral_msbte8(CORAL_B0, base, stride);
    coral_msbte16(CORAL_B1, base, stride);
    coral_msbte32(CORAL_B2, base, stride);
    coral_msbte64(CORAL_B3, base, stride);

    coral_mlcte8(CORAL_C0, base, stride);
    coral_mlcte16(CORAL_C1, base, stride);
    coral_mlcte32(CORAL_C2, base, stride);
    coral_mlcte64(CORAL_C3, base, stride);
    coral_mscte8(CORAL_C0, base, stride);
    coral_mscte16(CORAL_C1, base, stride);
    coral_mscte32(CORAL_C2, base, stride);
    coral_mscte64(CORAL_C3, base, stride);
}
