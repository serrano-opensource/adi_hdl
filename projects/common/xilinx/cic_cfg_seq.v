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

// Drives the shared cic_compiler s_axis_config channel (broadcast to every
// per-channel instance, since all channels always share one decimation
// rate) and issues a reset pulse to the CIC cores whenever the rate
// changes. A reset is not mandated by pg140 for a live rate change, but the
// resulting output-gain/truncation transient length isn't bounded in the
// datasheet either, so resetting sidesteps having to reason about it: the
// CIC's own m_axis_data_tvalid already stays low correctly while the
// datapath refills after reset, so no extra output gating is needed here.
// A bypass-mode change does not go through this sequencer: the CIC cores
// keep running continuously regardless of which path the downstream
// bypass mux selects, so toggling bypass never needs a reset/reconfig.

module cic_cfg_seq #(
  parameter RATE_WIDTH = 8,
  parameter RESET_CYCLES = 4
) (

  input                     clk,
  input                     aresetn,

  input   [RATE_WIDTH-1:0]  rate,

  output                    cic_aresetn,
  output  [RATE_WIDTH-1:0]  cfg_tdata,
  output                    cfg_tvalid,
  input                     cfg_tready,

  output                    busy
);

  localparam ST_RST = 2'd0;
  localparam ST_CFG = 2'd1;
  localparam ST_IDLE = 2'd2;

  reg [1:0]                          state = ST_RST;
  reg [$clog2(RESET_CYCLES+1)-1:0]   rst_cnt = 'd0;
  reg [RATE_WIDTH-1:0]               rate_d = 'd0;
  reg                                cic_aresetn_r = 1'b0;
  reg                                cfg_tvalid_r = 1'b0;
  reg [RATE_WIDTH-1:0]               cfg_tdata_r = 'd0;

  assign cic_aresetn = cic_aresetn_r;
  assign cfg_tdata = cfg_tdata_r;
  assign cfg_tvalid = cfg_tvalid_r;
  assign busy = (state != ST_IDLE);

  always @(posedge clk or negedge aresetn) begin
    if (aresetn == 1'b0) begin
      state <= ST_RST;
      rst_cnt <= 'd0;
      cic_aresetn_r <= 1'b0;
      cfg_tvalid_r <= 1'b0;
      cfg_tdata_r <= 'd0;
      rate_d <= rate;
    end else begin
      case (state)
        ST_RST: begin
          cic_aresetn_r <= 1'b0;
          cfg_tvalid_r <= 1'b0;
          if (rst_cnt == RESET_CYCLES-1) begin
            rst_cnt <= 'd0;
            cic_aresetn_r <= 1'b1;
            cfg_tdata_r <= rate_d;
            cfg_tvalid_r <= 1'b1;
            state <= ST_CFG;
          end else begin
            rst_cnt <= rst_cnt + 1'b1;
          end
        end
        ST_CFG: begin
          cic_aresetn_r <= 1'b1;
          if (cfg_tready == 1'b1) begin
            cfg_tvalid_r <= 1'b0;
            state <= ST_IDLE;
          end
        end
        default: begin // ST_IDLE
          cic_aresetn_r <= 1'b1;
          rate_d <= rate;
          if (rate_d != rate) begin
            rst_cnt <= 'd0;
            state <= ST_RST;
          end
        end
      endcase
    end
  end

endmodule
