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
//
// fir_scale_check_tb.v - standalone testbench verifying the FIR compensation
// filter's output scaling is correct.
//
// THIS IS A DIAGNOSTIC/VERIFICATION TOOL, NOT PART OF THE REAL DESIGN. It
// exercises a standalone scratch instance of the fir_compiler IP
// (fir_scale_check, see the companion fir_scale_check_ip.tcl), configured
// identically to the real fir_compensator_0/1 instances in
// adi_cic_filter_bd.tcl, seeded with the real droop-correction coefficients.
//
// Background: the FIR core's accumulator is sized for worst-case bit growth
// (since Coefficient_Reload=true), independent of the coefficients' actual
// magnitude. The coefficients here are Q1.14 fixed-point (14 fractional
// bits) - if Output_Width doesn't correctly account for that scale, the
// core silently produces an output that's wrong by a power-of-two factor
// (this project hit exactly that: Output_Width=16 produced an output
// ~256x too small). See README.md section 1 for the full explanation and
// the fix (Output_Width=24 + fir_out_sat.v).
//
// SETUP: source fir_scale_check_ip.tcl first (in any open Vivado project -
// this generates out-of-context, it doesn't need to be added to the real
// block design), then generate_target on it, then add this file as a
// simulation source and set it as the sim top.
//
// EXPECTED RESULT: a constant DC input of 1000 should produce a
// steady-state output of ~989 (the real coefficients' DC gain is
// 16200/16384 ~= 0.989). If OUTPUT instead reads ~4, the output-scaling
// fix has regressed - Output_Width on the real fir_compensator_0/1
// instances (or on this scratch IP, if that's what changed) is back to a
// value that doesn't match the coefficients' Q1.14 scale.
//
// NOTE ON TEST METHODOLOGY: the first several output beats reflect the
// FIR's internal delay line still filling (mostly zeros/early samples),
// not steady-state behavior - reading OUTPUT too early will show a
// near-zero value that looks like a scaling bug but isn't. This testbench
// feeds 150 beats (well past the 47-tap fill point) and captures the
// 100th valid output sample specifically to avoid that trap.
//
// NOTE ON AXI4-STREAM PORTS: every input port on the DUT is explicitly
// tied to a defined value below, including ones this test doesn't
// otherwise use (s_axis_config_t*, s_axis_reload_t*). Leaving any
// AXI4-Stream input on this core unconnected causes it to read as X in
// simulation, which corrupts the core's internal FIFO pointer logic and
// produces confusing failures ("add_1 must be in range [-1,DEPTH-1]",
// "empty_1 and not_empty_1 are inconsistent") that look unrelated to the
// actual cause. Any future testbench against this core should do the same.

`timescale 1ns/1ps

module fir_scale_check_tb;

  reg                clk = 0;
  reg                aresetn = 0;
  reg                s_axis_data_tvalid = 0;
  reg  signed [15:0] s_axis_data_tdata = 0;
  wire               s_axis_data_tready;
  wire               m_axis_data_tvalid;
  wire signed [23:0] m_axis_data_tdata;
  wire               event_s_reload_tlast_missing;
  wire               event_s_reload_tlast_unexpected;
  wire               s_axis_config_tready;
  wire               s_axis_reload_tready;
  integer            in_count = 0;
  integer            out_count = 0;

  always #5 clk = ~clk;   // 100 MHz

  fir_scale_check dut (
    .aresetn                          (aresetn),
    .aclk                              (clk),
    .s_axis_data_tvalid               (s_axis_data_tvalid),
    .s_axis_data_tready               (s_axis_data_tready),
    .s_axis_data_tdata                (s_axis_data_tdata),
    .s_axis_config_tvalid             (1'b0),
    .s_axis_config_tready             (s_axis_config_tready),
    .s_axis_config_tdata              (8'd0),
    .s_axis_reload_tvalid             (1'b0),
    .s_axis_reload_tready             (s_axis_reload_tready),
    .s_axis_reload_tlast              (1'b0),
    .s_axis_reload_tdata              (16'd0),
    .m_axis_data_tvalid               (m_axis_data_tvalid),
    .m_axis_data_tdata                (m_axis_data_tdata),
    .event_s_reload_tlast_missing     (event_s_reload_tlast_missing),
    .event_s_reload_tlast_unexpected  (event_s_reload_tlast_unexpected)
  );

  initial begin
    #100;
    aresetn = 1;
    #20;
    s_axis_data_tvalid = 1;
    s_axis_data_tdata  = 16'sd1000;
  end

  // feed 150 beats of constant input - comfortably more than NUM_TAPS(47)
  // so the delay line is genuinely full of x=1000 before we read output
  always @(posedge clk) begin
    if (s_axis_data_tvalid && s_axis_data_tready) begin
      in_count <= in_count + 1;
      if (in_count >= 149)
        s_axis_data_tvalid <= 0;
    end
  end

  // capture the 100th valid output sample - well past the 47-tap fill point,
  // genuine steady state, not the ramp-up transient
  always @(posedge clk) begin
    if (m_axis_data_tvalid) begin
      out_count <= out_count + 1;
      if (out_count == 99) begin
        $display("INPUT  = %0d", 1000);
        $display("OUTPUT = %0d", m_axis_data_tdata);
        $display("GAIN   = %f", $itor(m_axis_data_tdata) / 1000.0);
        $finish;
      end
    end
  end

endmodule