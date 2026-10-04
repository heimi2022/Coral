# Canonical CoralNPU matrix source for the patched XuanTie gas.
# Unlike coral_matrix_asm.s, this file uses the registered coral.* mnemonics
# and gas's normal memory operand syntax.
.text

coral.msettileki 33
coral.msettilem x5
coral.msettileni 17

coral.mzero m0
coral.mzero2r m0
coral.mzero4r m0
coral.mzero8r m0

coral.mmacc.w.b m0, m1, m2
coral.mmaccu.w.b m1, m2, m3
coral.mmaccus.w.b m2, m3, m0
coral.mmaccsu.w.b m3, m0, m1

coral.mlae8  m0, a1, 0(a0)
coral.mlbe16 m1, a1, 0(a0)
coral.mlce32 m2, a1, 0(a0)
coral.msae64 m2, a1, 0(a0)
coral.msbe8  m3, a1, 0(a0)
coral.msce16 m1, a1, 0(a0)

coral.mlme32 m0, x0, 0(a0)
coral.msme64 m7, x0, 0(a0)
coral.mlate8  m0, a1, 0(a0)
coral.mlbte16 m1, a1, 0(a0)
coral.mlcte32 m2, a1, 0(a0)
coral.msate64 m2, a1, 0(a0)
coral.msbte8  m3, a1, 0(a0)
coral.mscte16 m1, a1, 0(a0)
