// ***************************************************************************
// ***************************************************************************
// Copyright (C) 2026 Analog Devices, Inc. All rights reserved.
//
// In this HDL repository, there are many different and unique modules, consisting
// of various HDL (Verilog or VHDL) components. The individual modules are
// developed independently, and may be accompanied by separate and unique license
// terms.
//
// The user should read each of these license terms, and understand the
// freedoms and responsibilities that he or she has by using this source/core.
//
// This core is distributed in the hope that it will be useful, but WITHOUT ANY
// WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
// A PARTICULAR PURPOSE.
//
// Redistribution and use of source or resulting binaries, with or without modification
// of this file, are permitted under one of the following two license terms:
//
//   1. The GNU General Public License version 2 as published by the
//      Free Software Foundation, which can be found in the top level directory
//      of this repository (LICENSE_GPL2), and also online at:
//      <https://www.gnu.org/licenses/old-licenses/gpl-2.0.html>
//
// OR
//
//   2. An ADI specific BSD license, which can be found in the top level directory
//      of this repository (LICENSE_ADIBSD), and also on-line at:
//      https://github.com/analogdevicesinc/hdl/blob/main/LICENSE_ADIBSD
//      This will allow to generate bit files and not release the source code,
//      as long as it attaches to an ADI device.
//
// ***************************************************************************
// ***************************************************************************

`timescale 1ns/100ps

// Purely combinational (no clock, adds zero pipeline latency). Exists
// because the FIR core's Output_Width was widened from 16 to 24 bits to
// correctly extract the accumulator at the coefficients' real Q1.14 scale
// (see fir_scale_check simulation results) - the core's own Output_Width
// truncation only handles accumulator->output_width, it doesn't saturate
// against a *different*, narrower downstream width. This module is that
// final 24->16 step: pass through unchanged when the value already fits in
// 16 bits (the overwhelmingly common case for real signal levels), clamp
// to the 16-bit signed extremes rather than silently wrap on the rare
// transient that doesn't.

module fir_out_sat #(
  parameter IN_WIDTH  = 24,
  parameter OUT_WIDTH = 16
) (
  input  wire signed [IN_WIDTH-1:0]  din,
  output wire signed [OUT_WIDTH-1:0] dout
);

  wire signed [IN_WIDTH-1:0] max_out = (1 <<< (OUT_WIDTH-1)) - 1;
  wire signed [IN_WIDTH-1:0] min_out = -(1 <<< (OUT_WIDTH-1));

  assign dout = (din > max_out) ? max_out[OUT_WIDTH-1:0] :
                (din < min_out) ? min_out[OUT_WIDTH-1:0] :
                din[OUT_WIDTH-1:0];

endmodule