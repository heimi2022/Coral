define_design_lib work -path ./elab
history keep 500
set enable_page_mode false
set sh_enable_page_mode false
set compile_seqmap_identify_shift_registers false
set compile_seqmap_identify_shift_registers_with_synchronous_logic false
set timing_enable_multiple_clocks_per_reg true

# Treat behavioral SRAM models as black boxes during DC synthesis.
# Their generic array implementations are for simulation, and mapping them
# into stdcells is both unnecessary and memory-hungry for this flow.
set hdlin_sv_blackbox_modules "Sram_2048x128 Sram_512x128"

set lib_path    "
                /home/wjj/PDK/TSMC/28nm/TSMC_HPC+7t_Stdcell/tcbn28hpcplusbwp7t40p140_180b/TSMCHOME/digital/Front_End/timing_power_noise/CCS/tcbn28hpcplusbwp7t40p140_180a \
                /home/wjj/PDK/TSMC/28nm/TSMC_HPC+7t_Stdcell/tcbn28hpcplusbwp7t40p140lvt_180b/TSMCHOME/digital/Front_End/timing_power_noise/CCS/tcbn28hpcplusbwp7t40p140lvt_180a \
                "

set rtl_path    "../1-RTL/rvv_core_mini_axi_single_verilog"

set search_path ". $rtl_path $lib_path "

set target_library  "tcbn28hpcplusbwp7t40p140lvtssg0p81v125c_ccs.db  \
                     tcbn28hpcplusbwp7t40p140ssg0p81v125c_ccs.db     \
                    "

set synthetic_library "/opt/synopsys/syn/V-2023.12-SP5/libraries/syn/dw_foundation.sldb \
                       /opt/synopsys/syn/V-2023.12-SP5/libraries/syn/standard.sldb \
                       "

set link_library    "* \
                    $target_library  \ 
                    $synthetic_library \
                    "
