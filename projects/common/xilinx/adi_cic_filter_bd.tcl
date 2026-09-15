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
# A 47-tap FIR compensation filter (Xilinx fir_compiler, symmetric coefficients)
# follows each CIC channel to correct output-level droop, with its own independent
# bypass mux. Step 1b (current): the FIR pair runs continuously on a fixed
# placeholder coefficient set - no reload sequencer or control register yet, and
# only the first complex channel (i=0 I, i=1 Q) is wired, pending in-context
# synthesis/timing verification before extending to all n_chan channels.
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
  set fir_name "fir_compensator"

  # 47-tap symmetric placeholder: unity gain, center tap only (index 23 of 0-46).
  # Real droop-correction taps get computed separately and pushed in later via
  # the reload sequencer (not yet built) - this seed only matters pre-reload.
  set init_coeff_vector "0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,1,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0"

  create_bd_pin -dir I $name/aclk
  create_bd_pin -dir I $name/aresetn
  create_bd_pin -dir I $name/bypass
  create_bd_pin -dir I -from [expr $rate_width-1] -to 0 $name/rate
  create_bd_pin -dir O $name/busy

  # FIR control interface - drives to/from axi_cic_decimate_ctrl, a sibling
  # AXI-lite peripheral outside this hierarchy (same relationship as
  # rate/bypass/busy above). fir_coef_addr/fir_coef_rdata widths mirror
  # fir_coef_seq.v's ADDR_WIDTH/COEF_WIDTH defaults (6/16, for NUM_TAPS=47) -
  # hardcoded here rather than threaded through as proc parameters, matching
  # the existing init_coeff_vector's hardcoded-for-47-taps approach.
  create_bd_pin -dir I $name/fir_bypass
  create_bd_pin -dir O $name/fir_busy
  create_bd_pin -dir I $name/fir_load
  create_bd_pin -dir O -from 5 -to 0 $name/fir_coef_addr
  create_bd_pin -dir I -from 15 -to 0 $name/fir_coef_rdata

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

  # --- step 1b/step 4: single FIR pair (i=0 I, i=1 Q) wiring. fir_bypass is
  # a real control pin now, driven externally by axi_cic_decimate_ctrl; each
  # core's coefficients are loaded via coef_seq below, driven by firmware
  # through the same peripheral (FIR_COEF_DATA/FIR_LOAD). enable_out_$i is
  # delayed by the FIR core's confirmed C_LATENCY=35 cycles
  # (util_delay instances below) before feeding the bypass mux's processed-path
  # input, so it lines up with the FIR's own output timing; the raw-passthrough
  # path uses the undelayed enable_out_$i directly, since bypass has no added
  # latency to compensate for.

  # --- FIR reset: deliberately independent of cic_rstgen/cfg_seq. The CIC's
  # reset is intentionally re-pulsed on every rate change (bounds the CIC's own
  # rate-change transient) - the FIR doesn't decimate and has no equivalent need
  # to reset on a CIC rate change. Worse, resetting the FIR core clears its
  # CONFIG-channel state; per a documented AMD/Xilinx forum report, resetting
  # after a config packet has been sent but before data has flowed can leave
  # s_axis_reload_tready permanently stuck (recoverable only by reprogramming).
  # So the FIR pair gets its own reset, generated once from the block's
  # top-level aresetn at power-up, never touched by cic_cfg_seq.
  ad_ip_instance proc_sys_reset $name/fir_rstgen
  ad_ip_parameter $name/fir_rstgen CONFIG.C_EXT_RST_WIDTH 1
  ad_ip_parameter $name/fir_rstgen CONFIG.C_EXT_RESET_HIGH 0

  ad_connect $name/aresetn $name/fir_rstgen/ext_reset_in
  ad_connect $name/aclk $name/fir_rstgen/slowest_sync_clk

  add_files -norecurse $ad_hdl_dir/library/common/util_delay.v
  add_files -norecurse $ad_hdl_dir/projects/common/xilinx/fir_coef_seq.v
  add_files -norecurse $ad_hdl_dir/projects/common/xilinx/fir_out_sat.v

  # invert fir_rstgen's active-low reset to active-high for util_delay's
  # synchronous active-high reset input (created once, shared by both channels)
  create_bd_cell -type ip -vlnv xilinx.com:ip:util_vector_logic:2.0 $name/fir_enable_dly_rst_inv
  set_property -dict [list CONFIG.C_SIZE {1} CONFIG.C_OPERATION {not}] [get_bd_cells $name/fir_enable_dly_rst_inv]
  ad_connect $name/fir_rstgen/peripheral_aresetn $name/fir_enable_dly_rst_inv/Op1

  for {set i 0} {$i < 2} {incr i} {
    ad_ip_instance fir_compiler $name/${fir_name}_${i} [ list \
      Filter_Type                  Single_Rate \
      Rate_Change_Type             Integer \
      RateSpecification            Input_Sample_Period \
      SamplePeriod                 1 \
      Coefficient_Reload           true \
      Num_Reload_Slots             1 \
      Coefficient_Sets             1 \
      CoefficientSource            Vector \
      CoefficientVector            $init_coeff_vector \
      Coefficient_Width            16 \
      Coefficient_Fractional_Bits  0 \
      Coefficient_Sign             Signed \
      Coefficient_Structure        Symmetric \
      Quantization                 Integer_Coefficients \
      Data_Width                   $data_width \
      Output_Rounding_Mode         Symmetric_Rounding_to_Zero \
      Output_Width                 24 \
      Filter_Architecture          Systolic_Multiply_Accumulate \
      Number_Channels              1 \
      S_DATA_Has_FIFO              true \
      M_DATA_Has_TREADY            false \
      Has_ARESETn                  true \
      Has_ACLKEN                   false \
    ]

    ad_connect $name/aclk $name/${fir_name}_${i}/aclk
    ad_connect $name/fir_rstgen/peripheral_aresetn $name/${fir_name}_${i}/aresetn

    ad_connect $name/data_out_$i $name/${fir_name}_${i}/s_axis_data_tdata
    ad_connect $name/valid_out_$i $name/${fir_name}_${i}/s_axis_data_tvalid

    create_bd_pin -dir O $name/fir_valid_out_$i
    create_bd_pin -dir O $name/fir_enable_out_$i
    create_bd_pin -dir O -from [expr $data_width-1] -to 0 $name/fir_data_out_$i

    # delay enable_out_$i by the FIR core's confirmed C_LATENCY=35 cycles, so it
    # arrives at fir_out_mux_$i in the same cycle as the FIR's own output data/valid
    create_bd_cell -type module -reference util_delay $name/fir_enable_dly_$i
    set_property -dict [list \
      CONFIG.DATA_WIDTH   {1} \
      CONFIG.DELAY_CYCLES {35} \
    ] [get_bd_cells $name/fir_enable_dly_$i]

    ad_connect $name/aclk $name/fir_enable_dly_$i/clk
    ad_connect $name/fir_enable_dly_rst_inv/Res $name/fir_enable_dly_$i/reset
    ad_connect $name/enable_out_$i $name/fir_enable_dly_$i/din

    # 24->16 saturate: the core now extracts its accumulator at Output_Width=24
    # to land on the coefficients' correct Q1.14 scale (confirmed via
    # fir_scale_check simulation - see design notes); this brings it back to
    # the 16-bit sample width the rest of the datapath (mux, packer, DMA)
    # expects, clamping rather than wrapping on the rare out-of-range value.
    # Purely combinational - adds no pipeline latency, so C_LATENCY=35 and
    # the existing enable-delay match are both unaffected.
    create_bd_cell -type module -reference fir_out_sat $name/fir_out_sat_$i
    set_property -dict [list \
      CONFIG.IN_WIDTH  {24} \
      CONFIG.OUT_WIDTH $data_width \
    ] [get_bd_cells $name/fir_out_sat_$i]

    ad_connect $name/${fir_name}_${i}/m_axis_data_tdata $name/fir_out_sat_$i/din

    create_bd_cell -type module -reference ad_bus_mux $name/fir_out_mux_$i
    set_property -dict [list \
      CONFIG.DATA_WIDTH $data_width] [get_bd_cells $name/fir_out_mux_$i]

    ad_connect $name/${fir_name}_${i}/m_axis_data_tvalid $name/fir_out_mux_${i}/valid_in_0
    ad_connect $name/fir_enable_dly_$i/dout $name/fir_out_mux_${i}/enable_in_0
    ad_connect $name/fir_out_sat_$i/dout $name/fir_out_mux_${i}/data_in_0

    ad_connect $name/valid_out_$i $name/fir_out_mux_${i}/valid_in_1
    ad_connect $name/enable_out_$i $name/fir_out_mux_${i}/enable_in_1
    ad_connect $name/data_out_$i $name/fir_out_mux_${i}/data_in_1

    ad_connect $name/fir_bypass $name/fir_out_mux_${i}/select_path

    ad_connect $name/fir_out_mux_${i}/valid_out $name/fir_valid_out_$i
    ad_connect $name/fir_out_mux_${i}/enable_out $name/fir_enable_out_$i
    ad_connect $name/fir_out_mux_${i}/data_out $name/fir_data_out_$i
  }

  # --- coefficient reload sequencer. Shares fir_rstgen's reset domain (not
  # top-level aresetn directly) so it resets to idle in lockstep with the FIR
  # cores whenever they reset - a stale sequencer state after a core reset
  # would be meaningless. Practical consequence: firmware must re-issue a
  # coefficient load after any FIR-domain reset (power-up), which it already
  # has to do anyway for the very first load. ---
  create_bd_cell -type module -reference fir_coef_seq $name/coef_seq
  set_property -dict [list \
    CONFIG.DATA_WIDTH   {16} \
    CONFIG.NUM_TAPS     {24} \
    CONFIG.ADDR_WIDTH   {6} \
    CONFIG.CONFIG_WIDTH {8} \
  ] [get_bd_cells $name/coef_seq]

  ad_connect $name/aclk $name/coef_seq/clk
  ad_connect $name/fir_rstgen/peripheral_aresetn $name/coef_seq/aresetn

  ad_connect $name/fir_load $name/coef_seq/load
  ad_connect $name/coef_seq/busy $name/fir_busy

  # coefficient register file lives in axi_cic_decimate_ctrl, outside this
  # hierarchy - coef_addr/coef_rdata just pass through to the top-level pins
  ad_connect $name/coef_seq/coef_addr $name/fir_coef_addr
  ad_connect $name/fir_coef_rdata $name/coef_seq/coef_rdata

  # broadcast reload/config to both channels; only channel 0's tready is
  # watched, matching cfg_seq's established convention - both channels
  # always share identical configuration and timing
  for {set i 0} {$i < 2} {incr i} {
    ad_connect $name/coef_seq/reload_tdata $name/${fir_name}_${i}/s_axis_reload_tdata
    ad_connect $name/coef_seq/reload_tvalid $name/${fir_name}_${i}/s_axis_reload_tvalid
    ad_connect $name/coef_seq/reload_tlast $name/${fir_name}_${i}/s_axis_reload_tlast
    ad_connect $name/coef_seq/config_tdata $name/${fir_name}_${i}/s_axis_config_tdata
    ad_connect $name/coef_seq/config_tvalid $name/${fir_name}_${i}/s_axis_config_tvalid
  }
  ad_connect $name/${fir_name}_0/s_axis_reload_tready $name/coef_seq/reload_tready
  ad_connect $name/${fir_name}_0/s_axis_config_tready $name/coef_seq/config_tready

}