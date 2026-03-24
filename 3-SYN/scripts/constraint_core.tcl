set     CLK_SOURCE_LATENCY  	 1
set     CLK_NETWORK_LATENCY 	 1
set     OUT_LOAD                 1

set     MAX_FANOUT               16
set     MAX_CAP                  1
set     MAX_TRAN                 0.08
##### Source Clock Definition ###########################################################
reset_design
set PERIOD 0.666 
create_clock [get_ports clk] -name clk -period $PERIOD -waveform [list 0 [expr $PERIOD * 0.5]]


#set_host_options -max_cores 16

set_leakage_optimization true
set_dynamic_optimization true


#
#
##2GHz
#create_clock [get_ports sample_clk]  -period 0.5 -waveform {0 0.25} -name sample_clk
##create_clock [get_ports clk_div_temp] -period 0.5 -waveform {0 0.25} -name clk_div
##set_ideal_network [all_clocks]
#
#create_clock [get_ports CLKR]  -period 2 -waveform {0 1} -name CLKR 
##create_generated_clock -name CLKR -source sample_clk -divide_by 4 [get_ports CLKR]
#
#set_clock_uncertainty -setup 0.13  [get_ports sample_clk]
#set_clock_uncertainty -hold 0.1  [get_ports sample_clk]
#set_clock_transition -max 0.02 [get_ports sample_clk]
#
#set_clock_uncertainty -setup 0.2  [get_ports CLKR]
#set_clock_uncertainty -hold 0.2  [get_ports CLKR]
#set_clock_transition -max 0.08 [get_ports CLKR]

#set_clock_uncertainty -setup 0.2  [get_ports CLKR]
#set_clock_uncertainty -hold 0.2  [get_ports CLKR]
#set_clock_transition -max 0.1  [get_ports CLKR]


#create_clock -period 1 -name buf_clk [get_pins u_ckmux_0/I1] 
#create_clock -period 1 -name dcd_clk [get_pins u_ckmux_0/I0] 
#set_clock_groups -logically_exclusive -group buf_clk -group dcd_clk

#create_generated_clock -name dca_clk -source [get_pins u_ckmux_0/I0] -master_clock [get_clocks {dcd_clk}] -edges {1 2 3} -add

#set_dont_touch_network [get_pins u_ckmux_0/I1]
#set_dont_touch_network [get_pins u_ckmux_0/I0]
#set_disable_timing u_ckmux_0 -from I0 -to Z

#create_clock -period 1 -name dca_clk_in [get_pins u_ckmux_0/Z] 

#create_generated_clock -name mux_clk_out_1 [get_pins u_dca_ctrl_0/clk_dcm] \
#                 -source [get_pins u_ckmux_0/Z] \
#                 -edges {1 2 3} -combinational -add
#
#create_generated_clock -name mux_clk_out_2 [get_pins u_dca_0/clk_in]  \
#                 -source [get_pins u_ckmux_0/Z] \
#                 -edges {1 2 3} -combinational -add


#set_ideal_network [all_clocks]
##set_ideal_network [get_pins u_dff/Q]
##set_ideal_network [get_pins u_dff/D]
#set_clock_uncertainty -setup 0.1 [all_clocks]
#set_clock_transition -max 0.08 [all_clocks]


set ALL_EX_OUT          [remove_from_collection [current_design] [all_outputs]]
set ALL_EX_OUT_IN       [remove_from_collection $ALL_EX_OUT [all_inputs]]
set_max_transition      $MAX_TRAN               $ALL_EX_OUT_IN 
set_max_fanout          $MAX_FANOUT             $ALL_EX_OUT_IN
set_max_capacitance     $MAX_CAP                $ALL_EX_OUT_IN
set_load                $OUT_LOAD               [all_outputs]


#set_input_delay -max 1 -clock clk [all_inputs]
#remove_input_delay [get_ports clk]
#set_output_delay -max 9 -clock clk [all_outputs]
set_ideal_network [all_clocks]


