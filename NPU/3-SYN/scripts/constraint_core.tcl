set     CLK_SOURCE_LATENCY  	 1
set     CLK_NETWORK_LATENCY 	 1
set     OUT_LOAD                 1

set     MAX_FANOUT               16
set     MAX_CAP                  0.2
set     MAX_TRAN                 0.15
##### Source Clock Definition ###########################################################
reset_design
set PERIOD 2.0
create_clock [get_ports io_aclk] -name clk -period $PERIOD -waveform [list 0 [expr {$PERIOD * 0.5}]]

set_clock_uncertainty -setup 0.05 [get_clocks clk]
set_clock_uncertainty -hold  0.02 [get_clocks clk]
set_clock_transition  0.05 [get_clocks clk]

set_ideal_network [get_ports io_aclk]

set ALL_EX_OUT          [remove_from_collection [current_design] [all_outputs]]
set ALL_EX_OUT_IN       [remove_from_collection $ALL_EX_OUT [all_inputs]]
set_max_transition      $MAX_TRAN               $ALL_EX_OUT_IN 
set_max_fanout          $MAX_FANOUT             $ALL_EX_OUT_IN
set_max_capacitance     $MAX_CAP                $ALL_EX_OUT_IN


# 3. I/O 端口约束
set ALL_IN_EX_CLK [remove_from_collection [all_inputs] [get_ports io_aclk]]
set_input_delay  [expr {$PERIOD * 0.4}] -clock clk $ALL_IN_EX_CLK
set_output_delay [expr {$PERIOD * 0.4}] -clock clk [all_outputs]
set_load $OUT_LOAD [all_outputs]
