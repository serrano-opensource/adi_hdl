###############################################################################
## Copyright (C) 2026 Analog Devices, Inc. All rights reserved.
### SPDX short identifier: ADIBSD
###############################################################################

###################################################################################################
###################################################################################################
##
# ad_add_cic_decimation_filter - Creates a subsystem based on the Xilinx cic_compiler IP,
# with a per-channel bypass mux (bypass = raw passthrough, matching the design's
# behavior with the decimator absent). One single-channel cic_compiler instance is used
# per channel (rather than the IP's internal multi-channel/TDM mode) since the channels
# arrive as fully parallel streams on the same clock, not time-multiplexed. All channels
# share one decimation rate, applied via the IP's "Programmable" rate-change config
# channel, broadcast from a single small sequencer (cic_cfg_seq) that also issues a
# reset pulse to the CIC cores whenever the rate changes.
#
# \param[name] - Subsystem name
# \param[n_chan] - Number of channels to filter
# \param[number_of_stages] - CIC number of stages (N)
# \param[differential_delay] - CIC differential delay (M)
# \param[data_width] - Input/output sample width, in bits
# \param[min_rate] - Minimum programmable decimation rate
# \param[max_rate] - Maximum programmable decimation rate
# \param[init_rate] - Decimation rate applied out of reset
# \param[rate_width] - Width, in bits, of the rate value/config channel (must match
# the control peripheral driving the "rate" pin, and the generated cic_compiler's
# s_axis_config_tdata width for the chosen Maximum_Rate)
proc ad_add_cic_decimation_filter {name n_chan number_of_stages differential_delay \
                                    data_width min_rate max_rate init_rate rate_width} {
  global ad_hdl_dir

  create_bd_cell -type hier $name
  set filter_name "cic_decimator"

  create_bd_pin -dir I $name/aclk
  create_bd_pin -dir I $name/aresetn
  create_bd_pin -dir I $name/bypass
  create_bd_pin -dir I -from [expr $rate_width-1] -to 0 $name/rate
  create_bd_pin -dir O $name/busy

  add_files -norecurse $ad_hdl_dir/library/common/ad_bus_mux.v
  add_files -norecurse $ad_hdl_dir/projects/common/xilinx/cic_cfg_seq.v

  # shared config-channel sequencer - broadcasts rate/reset to every channel instance
  create_bd_cell -type module -reference cic_cfg_seq $name/cfg_seq
  set_property -dict [list \
    CONFIG.RATE_WIDTH $rate_width] [get_bd_cells $name/cfg_seq]

  ad_connect $name/aclk $name/cfg_seq/clk
  ad_connect $name/aresetn $name/cfg_seq/aresetn
  ad_connect $name/rate $name/cfg_seq/rate
  ad_connect $name/cfg_seq/busy $name/busy

  # synchronize the sequencer-generated active-low CIC reset to the CIC clock
  ad_ip_instance proc_sys_reset $name/cic_rstgen
  ad_ip_parameter $name/cic_rstgen CONFIG.C_EXT_RST_WIDTH 1
  ad_ip_parameter $name/cic_rstgen CONFIG.C_EXT_RESET_HIGH 0

  ad_connect $name/cfg_seq/cic_aresetn $name/cic_rstgen/ext_reset_in
  ad_connect $name/aclk $name/cic_rstgen/slowest_sync_clk

  # add filter instances for n channels
  for {set i 0} {$i < $n_chan} {incr i} {
    ad_ip_instance cic_compiler $name/${filter_name}_${i} [ list \
      Filter_Type          Decimation \
      Number_Of_Stages     $number_of_stages \
      Differential_Delay   $differential_delay \
      Number_Of_Channels   1 \
      Sample_Rate_Changes  Programmable \
      Fixed_Or_Initial_Rate $init_rate \
      Minimum_Rate         $min_rate \
      Maximum_Rate         $max_rate \
      RateSpecification    Sample_Period \
      SamplePeriod         1 \
      Input_Data_Width     $data_width \
      Quantization         Truncation \
      Output_Data_Width    $data_width \
      Use_Xtreme_DSP_Slice true \
      HAS_DOUT_TREADY      false \
      HAS_ACLKEN           false \
      HAS_ARESETN          true \
    ]

    ad_connect $name/aclk $name/${filter_name}_${i}/aclk
    ad_connect $name/cic_rstgen/peripheral_aresetn $name/${filter_name}_${i}/aresetn
    ad_connect $name/cfg_seq/cfg_tdata $name/${filter_name}_${i}/s_axis_config_tdata
    ad_connect $name/cfg_seq/cfg_tvalid $name/${filter_name}_${i}/s_axis_config_tvalid

    if {$i == 0} {
      # all channels use identical config/timing, so watch only channel 0's tready
      ad_connect $name/${filter_name}_0/s_axis_config_tready $name/cfg_seq/cfg_tready
    }

    create_bd_pin -dir I $name/valid_in_$i
    create_bd_pin -dir I $name/enable_in_$i
    create_bd_pin -dir O $name/valid_out_$i
    create_bd_pin -dir O $name/enable_out_$i
    create_bd_pin -dir I -from [expr $data_width-1] -to 0 $name/data_in_$i
    create_bd_pin -dir O -from [expr $data_width-1] -to 0 $name/data_out_$i

    ad_connect $name/valid_in_$i $name/${filter_name}_${i}/s_axis_data_tvalid
    ad_connect $name/data_in_$i $name/${filter_name}_${i}/s_axis_data_tdata

    create_bd_cell -type module -reference ad_bus_mux $name/out_mux_$i
    set_property -dict [list \
      CONFIG.DATA_WIDTH $data_width] [get_bd_cells $name/out_mux_$i]

    # data_in_0/select_path=0 = decimated CIC output (default reset value of "bypass"
    # is 1, so select_path=1/data_in_1 = raw passthrough is what's selected at reset,
    # matching today's undecimated behavior with zero extra logic)
    ad_connect $name/${filter_name}_${i}/m_axis_data_tvalid $name/out_mux_${i}/valid_in_0
    ad_connect $name/enable_in_$i $name/out_mux_${i}/enable_in_0
    ad_connect $name/${filter_name}_${i}/m_axis_data_tdata $name/out_mux_${i}/data_in_0

    ad_connect $name/valid_in_$i $name/out_mux_${i}/valid_in_1
    ad_connect $name/enable_in_$i $name/out_mux_${i}/enable_in_1
    ad_connect $name/data_in_$i $name/out_mux_${i}/data_in_1

    ad_connect $name/bypass $name/out_mux_${i}/select_path

    ad_connect $name/out_mux_${i}/valid_out $name/valid_out_$i
    ad_connect $name/out_mux_${i}/enable_out $name/enable_out_$i
    ad_connect $name/out_mux_${i}/data_out $name/data_out_$i
  }
}
