###############################################################################
## Copyright (C) 2026 Analog Devices, Inc. All rights reserved.
### SPDX short identifier: ADIBSD
###############################################################################

# ip
source ../../scripts/adi_env.tcl
source $ad_hdl_dir/library/scripts/adi_ip_xilinx.tcl

global VIVADO_IP_LIBRARY

adi_ip_create axi_cic_decimate_ctrl
adi_ip_files axi_cic_decimate_ctrl [list \
  "$ad_hdl_dir/library/common/up_axi.v" \
  "$ad_hdl_dir/library/common/up_xfer_cntrl.v" \
  "axi_cic_decimate_ctrl_reg.v" \
  "axi_cic_decimate_ctrl.v" ]

adi_ip_properties axi_cic_decimate_ctrl

set_property company_url {https://wiki.analog.com/resources/fpga/docs/axi_cic_decimate_ctrl} [ipx::current_core]

ipx::infer_bus_interface dec_clk xilinx.com:signal:clock_rtl:1.0 [ipx::current_core]
ipx::infer_bus_interface tx_clk xilinx.com:signal:clock_rtl:1.0 [ipx::current_core]

ipx::save_core [ipx::current_core]
