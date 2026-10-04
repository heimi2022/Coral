# Canonical CoralNPU matrix assembler input.
.text

msettileki 33
msettilem x5
msettileni 17

mzero c0
mzero2r c0
mzero4r c0
mzero8r m0

mmacc.w.b c0, b1, a2
mmaccu.w.b c1, b2, a3
mmaccus.w.b c2, b3, a0
mmaccsu.w.b c3, b0, a1

mlae8  a0, (a0), a1
mlbe16 b1, (a0), a1
mlce32 c0, (a0), a1
msae64 a2, (a0), a1
msbe8  b3, (a0), a1
msce16 c1, (a0), a1

mlme32 m0, (a0), x0
msme64 m7, (a0), x0
mlate8  a0, (a0), a1
mlbte16 b1, (a0), a1
mlcte32 c0, (a0), a1
msate64 a2, (a0), a1
msbte8  b3, (a0), a1
mscte16 c1, (a0), a1
