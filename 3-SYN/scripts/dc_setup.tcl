define_design_lib work -path ./elab
history keep 500
set enable_page_mode false
set sh_enable_page_mode false
set compile_seqmap_identify_shift_registers false
set compile_seqmap_identify_shift_registers_with_synchronous_logic false
set timing_enable_multiple_clocks_per_reg true

set lib_tsmc22ulp_path " \
                       /projects/home/soc/zhangj25/DC/library/ \ 
                       "

set search_path       ". $lib_tsmc22ulp_path"

set target_library  "ics55_LLSC_H7CR_ss_rcworst_1p08_125_nldm.db  \
                    "

set synthetic_library "dw_foundation.sldb"

set link_library      "* \
                $target_library  \ 
                $synthetic_library\
                       "