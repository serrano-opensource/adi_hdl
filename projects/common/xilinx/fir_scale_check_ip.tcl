###############################################################################
## Copyright (C) 2026 Analog Devices, Inc. All rights reserved.
### SPDX short identifier: ADIBSD
###############################################################################
#
# fir_scale_check_ip.tcl - creates the standalone (out-of-context) fir_compiler
# scratch IP that fir_scale_check_tb.v exercises. This is NOT part of the real
# design (see rx_cic_decimator's real fir_compensator_0/1 instances in
# adi_cic_filter_bd.tcl for that) - it exists purely so the output-scaling
# fix (Output_Width=24 + fir_out_sat.v, see README.md) can be re-verified in
# isolation without touching the real project, the same way it was originally
# diagnosed.
#
# Usage: with any Vivado project open (any project - this IP is generated
# out-of-context and doesn't depend on what else is in the project), run
# from the Tcl console:
#
#   source fir_scale_check_ip.tcl
#   generate_target {all} [get_files fir_scale_check.xci]
#
# Then add fir_scale_check_tb.v as a simulation source, set it as the sim
# top, and run. Expect steady-state OUTPUT ~= 989 for an INPUT of 1000
# (matches the real droop-correction coefficients' DC gain of ~0.989).
# OUTPUT ~= 4 instead means the Output_Width/fir_out_sat scaling fix has
# regressed - see README.md section 1 for why.

create_ip -name fir_compiler -vendor xilinx.com -library ip -version 7.2 -module_name fir_scale_check

set_property -dict [list \
  CONFIG.Filter_Type                 {Single_Rate} \
  CONFIG.Rate_Change_Type            {Integer} \
  CONFIG.RateSpecification           {Input_Sample_Period} \
  CONFIG.SamplePeriod                {1} \
  CONFIG.Coefficient_Reload          {true} \
  CONFIG.Num_Reload_Slots            {1} \
  CONFIG.Coefficient_Sets            {1} \
  CONFIG.CoefficientSource           {Vector} \
  CONFIG.CoefficientVector           {-133,173,-233,159,-3,-241,504,-707,739,-537,86,560,-1269,1822,-1978,1541,-419,-1332,3460,-5444,6409,-4759,-3090,25584,-3090,-4759,6409,-5444,3460,-1332,-419,1541,-1978,1822,-1269,560,86,-537,739,-707,504,-241,-3,159,-233,173,-133} \
  CONFIG.Coefficient_Width           {16} \
  CONFIG.Coefficient_Fractional_Bits {0} \
  CONFIG.Coefficient_Sign            {Signed} \
  CONFIG.Coefficient_Structure       {Symmetric} \
  CONFIG.Quantization                {Integer_Coefficients} \
  CONFIG.Data_Width                  {16} \
  CONFIG.Output_Rounding_Mode        {Symmetric_Rounding_to_Zero} \
  CONFIG.Output_Width                {24} \
  CONFIG.Filter_Architecture         {Systolic_Multiply_Accumulate} \
  CONFIG.Number_Channels             {1} \
  CONFIG.S_DATA_Has_FIFO             {false} \
  CONFIG.M_DATA_Has_TREADY           {false} \
  CONFIG.Has_ARESETn                 {true} \
  CONFIG.Has_ACLKEN                  {false} \
] [get_ips fir_scale_check]