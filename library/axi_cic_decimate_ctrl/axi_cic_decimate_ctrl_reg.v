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
  parameter RATE_WIDTH = 8,
  parameter NUM_TAPS = 24,
  parameter COEF_WIDTH = 16,
  parameter ADDR_WIDTH = 6
) (

  input                       clk,

  output  [RATE_WIDTH-1:0]    dec_rate,
  output                      dec_bypass,
  input                       dec_busy,

  output                      fir_bypass,
  input                       fir_busy,
  output                      fir_load,
  input   [ADDR_WIDTH-1:0]    fir_coef_addr,
  output  [COEF_WIDTH-1:0]    fir_coef_rdata,

  // bus interface (word address, 6 bits - covers 0x00 to 0x3F, needed
  // since the FIR registers now extend up to 0x24)

  input                       up_rstn,
  input                       up_clk,
  input                       up_wreq,
  input       [ 5:0]          up_waddr,
  input       [31:0]          up_wdata,
  output  reg                 up_wack,
  input                       up_rreq,
  input       [ 5:0]          up_raddr,
  output  reg [31:0]          up_rdata,
  output  reg                 up_rack
);

  // internal registers

  reg     [31:0]              up_version = 32'h00010000;
  reg     [31:0]              up_scratch = 32'h0;

  reg     [RATE_WIDTH-1:0]    up_cic_rate = 'd4;
  reg                         up_cic_bypass = 1'b1;   // bypass enabled by default/reset

  reg     [ADDR_WIDTH-1:0]    up_coef_ptr = 'd0;
  reg                         up_fir_bypass = 1'b1;   // bypass enabled by default/reset
  reg                         up_fir_load_tgl = 1'b0;

  // coefficient memory: write port in up_clk domain, read port in clk
  // (dec_clk) domain. Async dual-port distributed RAM - safe because
  // fir_coef_seq only reads after software has finished writing all
  // NUM_TAPS words and issued FIR_LOAD, so there is no simultaneous
  // read-during-write hazard to guard against.
  reg     [COEF_WIDTH-1:0]    coef_mem [0:NUM_TAPS-1];

  assign fir_coef_rdata = coef_mem[fir_coef_addr];

  // busy status readback (dec_clk -> up_clk, single bit, plain 2-FF sync)

  reg                         up_busy_m1 = 1'b0;
  reg                         up_busy_m2 = 1'b0;
  reg                         up_fir_busy_m1 = 1'b0;
  reg                         up_fir_busy_m2 = 1'b0;

  always @(posedge up_clk) begin
    up_busy_m1 <= dec_busy;
    up_busy_m2 <= up_busy_m1;
    up_fir_busy_m1 <= fir_busy;
    up_fir_busy_m2 <= up_fir_busy_m1;
  end

  // FIR_LOAD: up_clk-side toggle, dec_clk-side 3-FF sync + edge detect,
  // producing a single one-cycle pulse in the dec_clk domain per write -
  // the right primitive for a one-shot event, unlike up_xfer_cntrl (built
  // for level/value data, not edge events).

  reg     [2:0]                fir_load_tgl_m = 3'd0;

  always @(posedge clk) begin
    fir_load_tgl_m <= {fir_load_tgl_m[1:0], up_fir_load_tgl};
  end

  assign fir_load = fir_load_tgl_m[2] ^ fir_load_tgl_m[1];

  always @(negedge up_rstn or posedge up_clk) begin
    if (up_rstn == 0) begin
      up_wack <= 'd0;
      up_scratch <= 'd0;
      up_cic_rate <= 'd4;
      up_cic_bypass <= 1'b1;
      up_coef_ptr <= 'd0;
      up_fir_bypass <= 1'b1;
      up_fir_load_tgl <= 1'b0;
    end else begin
      up_wack <= up_wreq;
      if ((up_wreq == 1'b1) && (up_waddr[5:0] == 6'h01)) begin
        up_scratch <= up_wdata;
      end
      if ((up_wreq == 1'b1) && (up_waddr[5:0] == 6'h10)) begin
        up_cic_rate <= up_wdata[RATE_WIDTH-1:0];
      end
      if ((up_wreq == 1'b1) && (up_waddr[5:0] == 6'h11)) begin
        up_cic_bypass <= up_wdata[0];
      end
      // FIR_COEF_DATA (0x20): write one coefficient at the current pointer,
      // then advance the pointer. The pointer saturates at NUM_TAPS-1
      // rather than wrapping, so writes past the expected NUM_TAPS count
      // overwrite the last tap instead of silently corrupting an earlier
      // one or wrapping back to index 0.
      if ((up_wreq == 1'b1) && (up_waddr[5:0] == 6'h20)) begin
        coef_mem[up_coef_ptr] <= up_wdata[COEF_WIDTH-1:0];
        if (up_coef_ptr < NUM_TAPS-1) begin
          up_coef_ptr <= up_coef_ptr + 1'b1;
        end
      end
      // FIR_COEF_PTR_RST (0x21): any write resets the pointer to 0.
      // Software must write this before starting a fresh NUM_TAPS-word
      // load - the pointer is never implicitly reset any other way, so a
      // load is always restart-safe regardless of how a previous load
      // left the pointer.
      if ((up_wreq == 1'b1) && (up_waddr[5:0] == 6'h21)) begin
        up_coef_ptr <= 'd0;
      end
      // FIR_LOAD (0x22): any write triggers fir_coef_seq to stream the
      // current coef_mem contents out over S_AXIS_RELOAD/S_AXIS_CONFIG.
      if ((up_wreq == 1'b1) && (up_waddr[5:0] == 6'h22)) begin
        up_fir_load_tgl <= ~up_fir_load_tgl;
      end
      if ((up_wreq == 1'b1) && (up_waddr[5:0] == 6'h23)) begin
        up_fir_bypass <= up_wdata[0];
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
        case (up_raddr[5:0])
          6'h00: up_rdata <= up_version;
          6'h01: up_rdata <= up_scratch;
          6'h10: up_rdata <= {{(32-RATE_WIDTH){1'b0}}, up_cic_rate};
          6'h11: up_rdata <= {30'h0, up_busy_m2, up_cic_bypass};
          6'h23: up_rdata <= {30'h0, up_fir_busy_m2, up_fir_bypass};
          6'h24: up_rdata <= {{(32-ADDR_WIDTH){1'b0}}, up_coef_ptr};
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

  // up_clk -> dec_clk transfer of fir_bypass, same primitive/pattern as
  // above - a slowly-changing level value, unlike the coefficient array.

  up_xfer_cntrl #(
    .DATA_WIDTH (1)
  ) i_fir_xfer_cntrl (
    .up_rstn (up_rstn),
    .up_clk (up_clk),
    .up_data_cntrl (up_fir_bypass),
    .up_xfer_done (),
    .d_rst (1'b0),
    .d_clk (clk),
    .d_data_cntrl (fir_bypass));

endmodule