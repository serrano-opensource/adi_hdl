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

module axi_cic_decimate_ctrl #(
  parameter RATE_WIDTH = 8,
  parameter NUM_TAPS = 24,
  parameter COEF_WIDTH = 16,
  parameter ADDR_WIDTH = 6
) (

  // decimator/FIR control interface (device clock domain)

  input                     dec_clk,
  output  [RATE_WIDTH-1:0]  dec_rate,
  output                    dec_bypass,
  input                     dec_busy,

  output                    fir_bypass,
  input                     fir_busy,
  output                    fir_load,
  input   [ADDR_WIDTH-1:0]  fir_coef_addr,
  output  [COEF_WIDTH-1:0]  fir_coef_rdata,

  // axi interface (address width widened 7->8 bits: word address is now
  // 6 bits to reach the FIR registers up to 0x24, so byte address needs
  // 2 more bits on top of that)

  input                     s_axi_aclk,
  input                     s_axi_aresetn,
  input                     s_axi_awvalid,
  input       [ 7:0]        s_axi_awaddr,
  input       [ 2:0]        s_axi_awprot,
  output                    s_axi_awready,
  input                     s_axi_wvalid,
  input       [31:0]        s_axi_wdata,
  input       [ 3:0]        s_axi_wstrb,
  output                    s_axi_wready,
  output                    s_axi_bvalid,
  output      [ 1:0]        s_axi_bresp,
  input                     s_axi_bready,
  input                     s_axi_arvalid,
  input       [ 7:0]        s_axi_araddr,
  input       [ 2:0]        s_axi_arprot,
  output                    s_axi_arready,
  output                    s_axi_rvalid,
  output      [31:0]        s_axi_rdata,
  output      [ 1:0]        s_axi_rresp,
  input                     s_axi_rready
);

  // internal signals

  wire              up_clk;
  wire              up_rstn;
  wire    [ 5:0]    up_waddr;
  wire    [31:0]    up_wdata;
  wire              up_wack;
  wire              up_wreq;
  wire              up_rack;
  wire    [31:0]    up_rdata;
  wire              up_rreq;
  wire    [ 5:0]    up_raddr;

  // signal name changes

  assign up_clk = s_axi_aclk;
  assign up_rstn = s_axi_aresetn;

  axi_cic_decimate_ctrl_reg #(
    .RATE_WIDTH (RATE_WIDTH),
    .NUM_TAPS (NUM_TAPS),
    .COEF_WIDTH (COEF_WIDTH),
    .ADDR_WIDTH (ADDR_WIDTH)
  ) i_reg (
    .clk (dec_clk),

    .dec_rate (dec_rate),
    .dec_bypass (dec_bypass),
    .dec_busy (dec_busy),

    .fir_bypass (fir_bypass),
    .fir_busy (fir_busy),
    .fir_load (fir_load),
    .fir_coef_addr (fir_coef_addr),
    .fir_coef_rdata (fir_coef_rdata),

    .up_rstn (up_rstn),
    .up_clk (up_clk),
    .up_wreq (up_wreq),
    .up_waddr (up_waddr),
    .up_wdata (up_wdata),
    .up_wack (up_wack),
    .up_rreq (up_rreq),
    .up_raddr (up_raddr),
    .up_rdata (up_rdata),
    .up_rack (up_rack));

  up_axi #(
    .AXI_ADDRESS_WIDTH(8)
  ) i_up_axi (
    .up_rstn (up_rstn),
    .up_clk (up_clk),
    .up_axi_awvalid (s_axi_awvalid),
    .up_axi_awaddr (s_axi_awaddr),
    .up_axi_awready (s_axi_awready),
    .up_axi_wvalid (s_axi_wvalid),
    .up_axi_wdata (s_axi_wdata),
    .up_axi_wstrb (s_axi_wstrb),
    .up_axi_wready (s_axi_wready),
    .up_axi_bvalid (s_axi_bvalid),
    .up_axi_bresp (s_axi_bresp),
    .up_axi_bready (s_axi_bready),
    .up_axi_arvalid (s_axi_arvalid),
    .up_axi_araddr (s_axi_araddr),
    .up_axi_arready (s_axi_arready),
    .up_axi_rvalid (s_axi_rvalid),
    .up_axi_rresp (s_axi_rresp),
    .up_axi_rdata (s_axi_rdata),
    .up_axi_rready (s_axi_rready),
    .up_wreq (up_wreq),
    .up_waddr (up_waddr),
    .up_wdata (up_wdata),
    .up_wack (up_wack),
    .up_rreq (up_rreq),
    .up_raddr (up_raddr),
    .up_rdata (up_rdata),
    .up_rack (up_rack));

endmodule