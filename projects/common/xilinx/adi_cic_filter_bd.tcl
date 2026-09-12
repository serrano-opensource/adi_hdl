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
    ad_connect $name/cfg_seq/cic_aresetn $name/${filter_name}_${i}/aresetn
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

###################################################################################################
###################################################################################################
##
# ad_add_cic_interpolation_filter - Creates a subsystem based on the Xilinx cic_compiler IP in
# Interpolation mode, with an input-pop-side bypass mux (bypass = raw passthrough, matching the
# design's behavior with the interpolator absent). One single-channel cic_compiler instance is
# used per channel, for the same reason as the decimator (fully parallel channels on one clock,
# not TDM). All channels share one interpolation rate, applied via the shared cic_cfg_seq
# sequencer (reused unchanged from the decimator, since it's generic w.r.t. filter direction).
#
# Unlike the decimator (which muxes on the output side, gated by an always-present full-rate
# input valid), the interpolator must mux on the INPUT POP-REQUEST side: the CIC's own
# s_axis_data_tready dictates when a new (slow-rate) input sample should be pulled from upstream
# (e.g. util_upack2), while a downstream JESD204 TX transport layer has no backpressure and must
# be fed a data sample every device-clock cycle unconditionally.
#
# \param[name] - Subsystem name
# \param[n_chan] - Number of channels to filter
# \param[number_of_stages] - CIC number of stages (N)
# \param[differential_delay] - CIC differential delay (M)
# \param[data_width] - Input/output sample width, in bits
# \param[min_rate] - Minimum programmable interpolation rate
# \param[max_rate] - Maximum programmable interpolation rate
# \param[init_rate] - Interpolation rate applied out of reset
# \param[rate_width] - Width, in bits, of the rate value/config channel (must match
# the control peripheral driving the "rate" pin, and the generated cic_compiler's
# s_axis_config_tdata width for the chosen Maximum_Rate)
proc ad_add_cic_interpolation_filter {name n_chan number_of_stages differential_delay \
                                       data_width min_rate max_rate init_rate rate_width} {
  global ad_hdl_dir

  create_bd_cell -type hier $name
  set filter_name "cic_interpolator"

  create_bd_pin -dir I $name/aclk
  create_bd_pin -dir I $name/aresetn
  create_bd_pin -dir I $name/bypass
  create_bd_pin -dir I -from [expr $rate_width-1] -to 0 $name/rate
  create_bd_pin -dir O $name/busy

  # full_rate_strobe: the downstream TPL's own per-cycle "latching now" strobe, used to pace
  # fifo_rd_en in bypass mode only, so bypass reproduces today's behavior bit-for-bit.
  create_bd_pin -dir I $name/full_rate_strobe
  # fifo_rd_en: single shared pop-request strobe, meant to drive a util_upack2-style
  # fifo_rd_en port (only bit 0 of that vector port is functionally significant, so a
  # scalar driver here, broadcast onto the wider port by ad_connect, is correct).
  create_bd_pin -dir O $name/fifo_rd_en

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

  # rden_mux: select_path=bypass picks between channel 0's CIC s_axis_data_tready
  # (interpolating - pop a new sample only once every R cycles) and full_rate_strobe
  # (bypass - pop a new sample every cycle, matching today's behavior). Reuses ad_bus_mux
  # purely for its 2-way select logic; data/enable pins are unused (tied to GND).
  create_bd_cell -type module -reference ad_bus_mux $name/rden_mux
  set_property -dict [list \
    CONFIG.DATA_WIDTH 1] [get_bd_cells $name/rden_mux]
  ad_connect $name/bypass $name/rden_mux/select_path
  ad_connect $name/full_rate_strobe $name/rden_mux/valid_in_1
  ad_connect GND $name/rden_mux/enable_in_1
  ad_connect GND $name/rden_mux/data_in_1
  ad_connect GND $name/rden_mux/enable_in_0
  ad_connect GND $name/rden_mux/data_in_0
  ad_connect $name/rden_mux/valid_out $name/fifo_rd_en

  # add filter instances for n channels
  #
  # SamplePeriod below = "clock cycles between input samples" (pg140). For a
  # Programmable-rate core the static hardware must be sized for the
  # FASTEST/most-demanding case in the configured range, i.e. min_rate -- NOT
  # max_rate. Using max_rate previously introduced a fixed, rate-independent
  # extra division of (max_rate/min_rate) on top of whatever rate is set at
  # runtime (e.g. 32/4 = 8x too slow at every configured rate).
  for {set i 0} {$i < $n_chan} {incr i} {
    ad_ip_instance cic_compiler $name/${filter_name}_${i} [ list \
      Filter_Type          Interpolation \
      Number_Of_Stages     $number_of_stages \
      Differential_Delay   $differential_delay \
      Number_Of_Channels   1 \
      Sample_Rate_Changes  Programmable \
      Fixed_Or_Initial_Rate $init_rate \
      Minimum_Rate         $min_rate \
      Maximum_Rate         $max_rate \
      RateSpecification    Sample_Period \
      SamplePeriod         $min_rate \
      Input_Data_Width     $data_width \
      Quantization         Truncation \
      Output_Data_Width    $data_width \
      Use_Xtreme_DSP_Slice true \
      HAS_DOUT_TREADY      false \
      HAS_ACLKEN           false \
      HAS_ARESETN          true \
    ]

    ad_connect $name/aclk $name/${filter_name}_${i}/aclk
    ad_connect $name/cfg_seq/cic_aresetn $name/${filter_name}_${i}/aresetn
    ad_connect $name/cfg_seq/cfg_tdata $name/${filter_name}_${i}/s_axis_config_tdata
    ad_connect $name/cfg_seq/cfg_tvalid $name/${filter_name}_${i}/s_axis_config_tvalid

    if {$i == 0} {
      # all channels use identical config/timing, so watch only channel 0's tready
      ad_connect $name/${filter_name}_0/s_axis_config_tready $name/cfg_seq/cfg_tready
      ad_connect $name/${filter_name}_0/s_axis_data_tready $name/rden_mux/valid_in_0
    }

    create_bd_pin -dir I -from [expr $data_width-1] -to 0 $name/data_in_$i
    create_bd_pin -dir O -from [expr $data_width-1] -to 0 $name/data_out_$i

    # input side: fifo_rd_data-style buses are held/registered (unchanged until the next
    # pop), so it's safe to present continuously with tvalid tied high -- the CIC's own
    # tready (once every R cycles) is what actually paces the pop, via rden_mux above.
    ad_connect $name/data_in_$i $name/${filter_name}_${i}/s_axis_data_tdata
    ad_connect VCC $name/${filter_name}_${i}/s_axis_data_tvalid

    create_bd_cell -type module -reference ad_bus_mux $name/out_mux_$i
    set_property -dict [list \
      CONFIG.DATA_WIDTH $data_width] [get_bd_cells $name/out_mux_$i]

    # data_in_0 = interpolated (fast-rate) CIC output; data_in_1 = raw passthrough.
    # bypass reset default (1) selects data_in_1, matching today's uninterpolated TX
    # behavior with zero extra logic, same convention as the decimator. valid_in_0/1
    # and enable_in_0/1 are tied off (GND): the downstream JESD204 TX transport layer
    # has no data-valid input on its per-channel data port, it latches every
    # device-clock cycle unconditionally, so there is nothing to drive them with, and
    # valid_out/enable_out are left unconnected (unused outputs) for the same reason.
    ad_connect $name/${filter_name}_${i}/m_axis_data_tdata $name/out_mux_${i}/data_in_0
    ad_connect GND $name/out_mux_${i}/valid_in_0
    ad_connect GND $name/out_mux_${i}/enable_in_0
    ad_connect $name/data_in_$i $name/out_mux_${i}/data_in_1
    ad_connect GND $name/out_mux_${i}/valid_in_1
    ad_connect GND $name/out_mux_${i}/enable_in_1
    ad_connect $name/bypass $name/out_mux_${i}/select_path
    ad_connect $name/out_mux_${i}/data_out $name/data_out_$i
  }
}
