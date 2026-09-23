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
//
// Reset/config ordering: the reset pulse issued here (cic_aresetn) does not
// reach the CIC cores directly. The block design passes it through a
// proc_sys_reset (cic_rstgen), which delays and stretches it, so the cores'
// own reset (core_aresetn, fed back into this module) asserts several cycles
// AFTER cic_aresetn and stays asserted for tens of cycles. A config beat sent
// as soon as cic_aresetn is released is accepted BEFORE that reset asserts,
// and the core's own reset then erases it, leaving the core at its power-up
// rate while this sequencer is already idle. So after the reset pulse the
// sequencer waits in ST_WAIT until it has seen core_aresetn assert and
// release again, and only then sends the config. WAIT_CYCLES bounds that wait:
// if the core reset is never observed (for example core_aresetn is tied off)
// the config is sent anyway after WAIT_CYCLES clocks, so the sequencer cannot
// deadlock.
//
// rate_d is reset to a plain constant (the initial rate, 4), not to "rate":
// resetting a register to the (multi-bit, data-dependent) value of another
// signal makes its per-bit async clear/preset depend on that signal's value,
// which Vivado's STA cannot verify recovery/removal timing for (flagged as
// "cannot be timed accurately" on synthesis). Because rate_d only feeds the
// ST_IDLE change-comparison (not the actual config value sent to the CIC
// cores -- the config value is taken from the live "rate" input when it is
// sent), starting rate_d from 4 is safe: if the live rate differs from 4 after
// reset, the first ST_IDLE comparison sees a "changed" rate and runs one
// harmless extra reset/wait/config pass, re-applying the already-correct rate
// a second time before settling.

module cic_cfg_seq #(
  parameter RATE_WIDTH = 8,
  parameter RESET_CYCLES = 4,
  parameter WAIT_CYCLES = 256
) (

  input                     clk,
  input                     aresetn,

  input   [RATE_WIDTH-1:0]  rate,

  output                    cic_aresetn,
  input                     core_aresetn,
  output  [RATE_WIDTH-1:0]  cfg_tdata,
  output                    cfg_tvalid,
  input                     cfg_tready,

  output                    busy,
  output  [RATE_WIDTH-1:0]  active_rate  // rate the core has actually adopted; latched in ST_CFG once cfg_tready fires
);

  localparam ST_RST  = 3'd0;
  localparam ST_WAIT = 3'd1;
  localparam ST_CFG  = 3'd2;
  localparam ST_IDLE = 3'd3;

  reg [2:0]                          state = ST_RST;
  reg [$clog2(RESET_CYCLES+1)-1:0]   rst_cnt = 'd0;
  reg [$clog2(WAIT_CYCLES+1)-1:0]    wait_cnt = 'd0;
  reg                                seen_low = 1'b0;
  reg [RATE_WIDTH-1:0]               rate_d = 'd4;
  reg                                cic_aresetn_r = 1'b0;
  reg                                cfg_tvalid_r = 1'b0;
  reg [RATE_WIDTH-1:0]               cfg_tdata_r = 'd0;
  reg [RATE_WIDTH-1:0]               active_rate_r = 'd4;  // power-up default, same as rate_d

  assign cic_aresetn = cic_aresetn_r;
  assign cfg_tdata = cfg_tdata_r;
  assign cfg_tvalid = cfg_tvalid_r;
  assign active_rate = active_rate_r;
  assign busy = (state != ST_IDLE);

  always @(posedge clk) begin
    if (aresetn == 1'b0) begin
      rate_d <= 'd4;
    end else if (state == ST_IDLE) begin
      rate_d <= rate;
    end
  end

  always @(posedge clk or negedge aresetn) begin
    if (aresetn == 1'b0) begin
      state <= ST_RST;
      rst_cnt <= 'd0;
      wait_cnt <= 'd0;
      seen_low <= 1'b0;
      cic_aresetn_r <= 1'b0;
      cfg_tvalid_r <= 1'b0;
      cfg_tdata_r <= 'd0;
      active_rate_r <= 'd4;
    end else begin
      case (state)
        ST_RST: begin
          cic_aresetn_r <= 1'b0;
          cfg_tvalid_r <= 1'b0;
          if (rst_cnt == RESET_CYCLES-1) begin
            rst_cnt <= 'd0;
            cic_aresetn_r <= 1'b1;
            wait_cnt <= 'd0;
            seen_low <= 1'b0;
            state <= ST_WAIT;
          end else begin
            rst_cnt <= rst_cnt + 1'b1;
          end
        end
        ST_WAIT: begin
          cic_aresetn_r <= 1'b1;
          wait_cnt <= wait_cnt + 1'b1;
          if (core_aresetn == 1'b0) begin
            seen_low <= 1'b1;
          end
          if ((seen_low && core_aresetn) || (wait_cnt == WAIT_CYCLES-1)) begin
            cfg_tdata_r <= rate;
            cfg_tvalid_r <= 1'b1;
            state <= ST_CFG;
          end
        end
        ST_CFG: begin
          cic_aresetn_r <= 1'b1;
          if (cfg_tready == 1'b1) begin
            cfg_tvalid_r <= 1'b0;
            state <= ST_IDLE;
            active_rate_r <= cfg_tdata_r;  // core has now adopted this rate
          end
        end
        default: begin // ST_IDLE
          cic_aresetn_r <= 1'b1;
          if (rate_d != rate) begin
            rst_cnt <= 'd0;
            state <= ST_RST;
          end
        end
      endcase
    end
  end

endmodule
