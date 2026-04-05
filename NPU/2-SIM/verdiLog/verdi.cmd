verdiSetActWin -dock widgetDock_<Decl._Tree>
simSetSimulator "-vcssv" -exec "./simv" -args
debImport "-dbdir" "./simv.daidir"
debLoadSimResult /home/wjj/2-NPU/NPU/2-SIM/novas.fsdb
wvCreateWindow
verdiWindowResize -win $_Verdi_1 -32 -32 "900" "700"
verdiSetActWin -dock widgetDock_MTB_SOURCE_TAB_1
srcDeselectAll -win $_nTrace1
wvGetSignalOpen -win $_nWave2
wvGetSignalSetScope -win $_nWave2 "/CoreMiniAxi"
verdiSetActWin -win $_nWave2
wvGetSignalSetScope -win $_nWave2 "/CoreMiniAxi/cg"
wvGetSignalSetScope -win $_nWave2 "/CoreMiniAxi/core"
wvGetSignalSetScope -win $_nWave2 "/CoreMiniAxi/axiSlave"
wvGetSignalSetScope -win $_nWave2 "/CoreMiniAxi/csr"
wvGetSignalSetScope -win $_nWave2 "/CoreMiniAxi"
wvGetSignalSetScope -win $_nWave2 "/CoreMiniAxi/csr"
wvGetSignalSetScope -win $_nWave2 "/CoreMiniAxi"
wvGetSignalSetScope -win $_nWave2 "/CoreMiniAxi/core"
wvGetSignalSetScope -win $_nWave2 "/CoreMiniAxi/core/score/csr"
wvSetPosition -win $_nWave2 {("G1" 8)}
wvSetPosition -win $_nWave2 {("G1" 8)}
wvAddSignal -win $_nWave2 -clear
wvAddSignal -win $_nWave2 -group {"G1" \
{/CoreMiniAxi/core/score/csr/matrixCfgReq_bits_op\[1:0\]} \
{/CoreMiniAxi/core/score/csr/matrixCfgReq_valid} \
{/CoreMiniAxi/core/score/csr/xtilekEn} \
{/CoreMiniAxi/core/score/csr/xtilek\[31:0\]} \
{/CoreMiniAxi/core/score/csr/xtilemEn} \
{/CoreMiniAxi/core/score/csr/xtilem\[31:0\]} \
{/CoreMiniAxi/core/score/csr/xtilenEn} \
{/CoreMiniAxi/core/score/csr/xtilen\[31:0\]} \
}
wvAddSignal -win $_nWave2 -group {"G2" \
}
wvSelectSignal -win $_nWave2 {( "G1" 1 2 3 4 5 6 7 8 )} 
wvSetPosition -win $_nWave2 {("G1" 8)}
wvSetPosition -win $_nWave2 {("G1" 8)}
wvSetPosition -win $_nWave2 {("G1" 8)}
wvAddSignal -win $_nWave2 -clear
wvAddSignal -win $_nWave2 -group {"G1" \
{/CoreMiniAxi/core/score/csr/matrixCfgReq_bits_op\[1:0\]} \
{/CoreMiniAxi/core/score/csr/matrixCfgReq_valid} \
{/CoreMiniAxi/core/score/csr/xtilekEn} \
{/CoreMiniAxi/core/score/csr/xtilek\[31:0\]} \
{/CoreMiniAxi/core/score/csr/xtilemEn} \
{/CoreMiniAxi/core/score/csr/xtilem\[31:0\]} \
{/CoreMiniAxi/core/score/csr/xtilenEn} \
{/CoreMiniAxi/core/score/csr/xtilen\[31:0\]} \
}
wvAddSignal -win $_nWave2 -group {"G2" \
}
wvSelectSignal -win $_nWave2 {( "G1" 1 2 3 4 5 6 7 8 )} 
wvSetPosition -win $_nWave2 {("G1" 8)}
wvGetSignalClose -win $_nWave2
wvSetCursor -win $_nWave2 1457.475129 -snap {("G1" 1)}
wvSetOptions -win $_nWave2 -cursorCenter on
wvZoomOut -win $_nWave2
wvZoomOut -win $_nWave2
wvZoomOut -win $_nWave2
wvSelectSignal -win $_nWave2 {( "G1" 4 )} 
wvSetCursor -win $_nWave2 363183.891700 -snap {("G1" 3)}
wvSetCursor -win $_nWave2 275361.086654 -snap {("G1" 2)}
wvSelectSignal -win $_nWave2 {( "G1" 2 )} 
wvSelectSignal -win $_nWave2 {( "G1" 3 )} 
wvSetCursor -win $_nWave2 257674.549527 -snap {("G1" 3)}
wvSelectSignal -win $_nWave2 {( "G1" 5 )} 
wvSelectSignal -win $_nWave2 {( "G1" 7 )} 
wvSelectSignal -win $_nWave2 {( "G1" 5 )} 
wvSetCursor -win $_nWave2 246391.758601 -snap {("G1" 5)}
wvSelectSignal -win $_nWave2 {( "G1" 1 )} 
wvSelectSignal -win $_nWave2 {( "G1" 2 )} 
wvSelectSignal -win $_nWave2 {( "G1" 4 )} 
wvSelectSignal -win $_nWave2 {( "G1" 1 )} 
wvSelectSignal -win $_nWave2 {( "G1" 2 )} 
wvSetCursor -win $_nWave2 260419.012185 -snap {("G1" 3)}
wvZoomIn -win $_nWave2
wvZoomIn -win $_nWave2
wvScrollDown -win $_nWave2 0
wvScrollDown -win $_nWave2 0
wvSelectSignal -win $_nWave2 {( "G1" 3 )} 
wvSelectSignal -win $_nWave2 {( "G1" 5 )} 
wvSelectSignal -win $_nWave2 {( "G1" 2 )} 
wvSelectSignal -win $_nWave2 {( "G1" 4 )} 
wvZoomOut -win $_nWave2
wvSelectSignal -win $_nWave2 {( "G1" 3 )} 
wvSetPosition -win $_nWave2 {("G1" 3)}
wvSetPosition -win $_nWave2 {("G1" 2)}
wvSetPosition -win $_nWave2 {("G1" 1)}
wvMoveSelected -win $_nWave2
wvSetPosition -win $_nWave2 {("G1" 1)}
wvSetPosition -win $_nWave2 {("G1" 2)}
wvSelectSignal -win $_nWave2 {( "G1" 4 )} 
wvSelectSignal -win $_nWave2 {( "G1" 7 )} 
wvSelectSignal -win $_nWave2 {( "G1" 3 )} 
debExit
