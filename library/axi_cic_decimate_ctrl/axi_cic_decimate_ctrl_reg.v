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

module axi_cic_decimate_ctrl_reg #(
  parameter RATE_WIDTH = 8
) (

  input                     clk,

  output  [RATE_WIDTH-1:0]  dec_rate,
  output                    dec_bypass,
  input                     dec_busy,

  // bus interface

  input                     up_rstn,
  input                     up_clk,
  input                     up_wreq,
  input       [ 4:0]        up_waddr,
  input       [31:0]        up_wdata,
  output  reg               up_wack,
  input                     up_rreq,
  input       [ 4:0]        up_raddr,
  output  reg [31:0]        up_rdata,
  output  reg               up_rack
);

  // internal registers

  reg     [31:0]            up_version = 32'h00010000;
  reg     [31:0]            up_scratch = 32'h0;

  reg     [RATE_WIDTH-1:0]  up_cic_rate = 'd4;
  reg                       up_cic_bypass = 1'b1;   // bypass enabled by default/reset

  // busy status readback (dec_clk -> up_clk, single bit, plain 2-FF sync)

  reg                       up_busy_m1 = 1'b0;
  reg                       up_busy_m2 = 1'b0;

  always @(posedge up_clk) begin
    up_busy_m1 <= dec_busy;
    up_busy_m2 <= up_busy_m1;
  end

  always @(negedge up_rstn or posedge up_clk) begin
    if (up_rstn == 0) begin
      up_wack <= 'd0;
      up_scratch <= 'd0;
      up_cic_rate <= 'd4;
      up_cic_bypass <= 1'b1;
    end else begin
      up_wack <= up_wreq;
      if ((up_wreq == 1'b1) && (up_waddr[4:0] == 5'h01)) begin
        up_scratch <= up_wdata;
      end
      if ((up_wreq == 1'b1) && (up_waddr[4:0] == 5'h10)) begin
        up_cic_rate <= up_wdata[RATE_WIDTH-1:0];
      end
      if ((up_wreq == 1'b1) && (up_waddr[4:0] == 5'h11)) begin
        up_cic_bypass <= up_wdata[0];
      end
    end
  end

  // processor read interface

  always @(negedge up_rstn or posedge up_clk) begin
    if (up_rstn == 0) begin
      up_rack <= 'd0;
      up_rdata <= 'd0;
    end else begin
      up_rack <= up_rreq;
      if (up_rreq == 1'b1) begin
        case (up_raddr[4:0])
          5'h00: up_rdata <= up_version;
          5'h01: up_rdata <= up_scratch;
          5'h10: up_rdata <= {{(32-RATE_WIDTH){1'b0}}, up_cic_rate};
          5'h11: up_rdata <= {30'h0, up_busy_m2, up_cic_bypass};
          default: up_rdata <= 32'h0;
        endcase
      end else begin
        up_rdata <= 32'd0;
      end
    end
  end

  // up_clk -> dec_clk transfer of {bypass, rate}, atomic multi-bit CDC

  up_xfer_cntrl #(
    .DATA_WIDTH (RATE_WIDTH + 1)
  ) i_xfer_cntrl (
    .up_rstn (up_rstn),
    .up_clk (up_clk),
    .up_data_cntrl ({up_cic_bypass, up_cic_rate}),
    .up_xfer_done (),
    .d_rst (1'b0),
    .d_clk (clk),
    .d_data_cntrl ({dec_bypass, dec_rate}));

endmodule
