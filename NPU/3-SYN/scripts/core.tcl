set TOP_MODULE RvvCoreMiniAxi	
set compile_enable_register_merging    true
set compile_seqmap_propagate_constants true
set verilogout_no_tri   "true"
set verilogout_equation "false"
set mv_default_level_shifter_voltage_range_infinity true
set mv_insert_level_shifter_verbose true
source -e -v ./scripts/dc_setup.tcl
# Keep compile resource usage conservative on this workstation.
set_host_options -max_cores 1

set change_names_dont_change_bus_members      true
set compile_disable_hierarchical_inverter_opt true
set auto_insert_level_shifters_on_clocks      all
set auto_insert_level_shifters 				  true

##set top and link all the sub modules
analyze -format sverilog ./flist.v  -define DC_SYN
elaborate       $TOP_MODULE
current_design  $TOP_MODULE
link

###
source -e -v ./scripts/constraint_core.tcl
report_clock
check_design > ./rpt/check_design.rpt
check_timing  > ./rpt/check_timing.rpt

source -e -v ./scripts/set_dont_use.tcl
#source -e -v ./scripts/set_false_path.tcl
#source -e -v ./scripts/constraints_avs.tcl
source -e -v ./scripts/set_dont_touch_cell.tcl

#set_clock_gating_style \
#                     -setup 0.3 \
#                     -hold 0 \
#                     -pos integrated \
#                     -neg integrated \
# LDRO_FSM#                     -max_fanout 32 \
#                     -control_point before \
#                     -control_signal scan_enable
#
#insert_clock_gating
#set_dont_touch [get_cells HCA]

#source -e -v ./scripts/set_dont_touch_cell.tcl
#set_max_area 0
group_path -name INPUT_GROUP -from [all_inputs]
group_path -name OUTPUT_GROUP -to  [all_outputs]

source -e -v ./scripts/operation_conditions.tcl
#set upf_create_implicit_supply_sets false
#load_upf      ./scripts/KWS_AVS_V1_2020_0111.upf
#set_voltage -object_list {VDD_top_net} 0.81
#set_voltage -object_list {VDD_core_net} 0.5
#set_voltage -object_list {VSS_net} 0


#load_upf      ./scripts/KWS_AVS_V2_2020_0218.upf
#set_voltage -object_list {VDD_TOP_NET} 0.81
#set_voltage -object_list {VDD_CORE_NET} 0.5
#set_voltage -object_list {VSS_NET} 0


set_fix_multiple_port_nets -all -buffer_constants
set_fix_multiple_port_nets -all -buffer_constants [all_designs]


set compile_timing_high_effort "true"
compile_ultra -area_high_effort_script -retime -no_autoungroup
set hlo_resource_allocation area
optimize_registers
set complie_ultra_ungroup_dw true
##compile_ultra -timing_high_effort_script -no_autoungroup  -no_boundary_optimization -incremental

set verilogout_no_tri   "true"
set verilogout_equation "false"

#define_name_rules  myrule -type net -allowed "0-9" -first_restricted "_ 0-9 N" -replacement_char "0-9" -prefix "n"
#change_names -rules myrule -verbose

change_names -hier -rules verilog


write_sdc                                		./outputs/$data/${TOP_MODULE}.sdc
write -format ddc     -hierarchy -output 		./outputs/$data/${TOP_MODULE}.ddc
write -format verilog -hierarchy -output 		./outputs/$data/${TOP_MODULE}.v
save_upf                                 		./outputs/$data/${TOP_MODULE}.upf
write_link_library -out                  		./outputs/$data/link_library.txt

                                                   	

report_constraint -all_vio 				  > ./rpt/$data/constraint.rpt
report_area   -hier        				  > ./rpt/$data/area.rpt
report_constraint  -all_violators                         > ./rpt/$data/${TOP_MODULE}_constraint_all_violators.rpt
check_timing                                              > ./rpt/$data/${TOP_MODULE}_check_timing_final.rpt
report_timing_requirements                                > ./rpt/$data/${TOP_MODULE}_report_timing_requirements.rpt
report_timing -transition_time -nets -attributes -nosplit > ./rpt/$data/${TOP_MODULE}_mapped_timing.rpt
report_area -physical -nosplit -hierarchy                 > ./rpt/$data/${TOP_MODULE}_mapped_area.rpt
report_power                                              > ./rpt/$data/${TOP_MODULE}_power.rpt
report_cell                                               > ./rpt/$data/${TOP_MODULE}_cell.rpt
report_timing  -delay max -max_paths 100 -transition_time > ./rpt/$data/${TOP_MODULE}_timing_max_path.rpt
##report_timing  -delay max -max_paths 100 -transition_time -group avs_clk -significant_digits 4 -transition_time > ./rpt/$data/${TOP_MODULE}_timing_max_path_avs_clk.rpt
report_timing  -delay min -max_paths 100                  > ./rpt/$data/${TOP_MODULE}_timing_min_path.rpt
report_reference                                          > ./rpt/$data/${TOP_MODULE}_ref.rpt
##report qor##
report_qor > ./rpt/$data/${TOP_MODULE}_qor.rpt



## copy .v & .sdc to 4-PT
#file copy -force ./outputs/$data/${TOP_MODULE}.v   ../4-PT/inputs/${TOP_MODULE}.v
#file copy -force ./outputs/$data/${TOP_MODULE}.sdc ../4-PT/inputs/${TOP_MODULE}.sdc

## copy .v to V2S
#file copy -force ./outputs/$data/${TOP_MODULE}.v	../7-V2S/Input

## copy .v to 5-SIM-sdf
#file copy -force ./outputs/$data/${TOP_MODULE}.v	../5-SIM-sdf/netlist
