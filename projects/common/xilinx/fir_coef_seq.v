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

// Drives the shared fir_compiler S_AXIS_RELOAD and S_AXIS_CONFIG channels
// (broadcast to every per-channel instance, since all channels always share
// one coefficient set). Modeled on cic_cfg_seq.v's FSM shape, but adapted to
// PG149's actual reload protocol rather than the CIC's single-beat config:
//
//  - Since this core is generated with a single coefficient set
//    (Coefficient_Sets = 1), PG149 confirms the reload packet carries no
//    filter-set-index prefix - just NUM_TAPS raw coefficient beats, tlast on
//    the last one.
//  - A reload packet alone does not take effect: per PG149, "receipt of a
//    filter configuration packet... activates reloaded filter coefficients".
//    So after streaming all NUM_TAPS beats, this sequencer also issues one
//    S_AXIS_CONFIG beat to trigger the switch-over. With a single filter and
//    a single channel there is nothing meaningful to select, so
//    config_tdata is driven to 0.
//
// No reset pulse is issued to the FIR core(s) as part of a reload (unlike
// cic_cfg_seq's rate-change reset for the CIC) - PG149's reload/config
// mechanism is designed to be applied live, and resetting the FIR core here
// would itself be unsafe: a documented AMD/Xilinx report shows resetting
// after a config packet has been sent but before data has flowed can leave
// s_axis_reload_tready stuck permanently. See adi_cic_filter_bd.tcl's
// fir_rstgen, which is intentionally decoupled from any rate-change/reload
// event and only resets once, at system power-up.
//
// Coefficient values are read from an external register file (expected to
// be axi_cic_decimate_ctrl's NUM_TAPS-entry coefficient array) via a simple
// address/data interface: coef_addr is driven combinationally from the
// current reload index, and coef_rdata is expected to reflect that address
// combinationally (or within the same cycle) - i.e. the register file is a
// plain read-only-here memory, not a handshaked bus. If the eventual
// register-file implementation has read latency, an extra wait state will
// need to be added here.
//
// Only channel 0's s_axis_reload_tready/s_axis_config_tready are watched,
// matching cic_cfg_seq's convention: all channel instances share identical
// configuration and timing, so they are expected to assert tready together.

module fir_coef_seq #(
  parameter DATA_WIDTH = 16,
  parameter NUM_TAPS = 47,
  parameter ADDR_WIDTH = 6,
  parameter CONFIG_WIDTH = 8
) (

  input                         clk,
  input                         aresetn,

  input                         load,
  output                        busy,

  // read port into the coefficient register file
  output  [ADDR_WIDTH-1:0]      coef_addr,
  input   [DATA_WIDTH-1:0]      coef_rdata,

  // S_AXIS_RELOAD, broadcast to every fir_compiler instance
  output  [DATA_WIDTH-1:0]      reload_tdata,
  output                        reload_tvalid,
  output                        reload_tlast,
  input                         reload_tready,

  // S_AXIS_CONFIG, broadcast to every fir_compiler instance
  output  [CONFIG_WIDTH-1:0]    config_tdata,
  output                        config_tvalid,
  input                         config_tready
);

  localparam ST_IDLE   = 2'd0;
  localparam ST_RELOAD = 2'd1;
  localparam ST_CONFIG = 2'd2;

  reg [1:0]                     state = ST_IDLE;
  reg [ADDR_WIDTH-1:0]          addr = 'd0;
  reg                           reload_tvalid_r = 1'b0;
  reg                           reload_tlast_r = 1'b0;
  reg                           config_tvalid_r = 1'b0;

  assign coef_addr = addr;
  assign reload_tdata = coef_rdata;
  assign reload_tvalid = reload_tvalid_r;
  assign reload_tlast = reload_tlast_r;
  assign config_tdata = {CONFIG_WIDTH{1'b0}};
  assign config_tvalid = config_tvalid_r;
  assign busy = (state != ST_IDLE);

  always @(posedge clk or negedge aresetn) begin
    if (aresetn == 1'b0) begin
      state <= ST_IDLE;
      addr <= 'd0;
      reload_tvalid_r <= 1'b0;
      reload_tlast_r <= 1'b0;
      config_tvalid_r <= 1'b0;
    end else begin
      case (state)
        ST_IDLE: begin
          reload_tvalid_r <= 1'b0;
          reload_tlast_r <= 1'b0;
          config_tvalid_r <= 1'b0;
          if (load == 1'b1) begin
            addr <= 'd0;
            reload_tvalid_r <= 1'b1;
            reload_tlast_r <= (NUM_TAPS == 1);
            state <= ST_RELOAD;
          end
        end
        ST_RELOAD: begin
          reload_tvalid_r <= 1'b1;
          if (reload_tready == 1'b1) begin
            if (addr == NUM_TAPS-1) begin
              reload_tvalid_r <= 1'b0;
              reload_tlast_r <= 1'b0;
              config_tvalid_r <= 1'b1;
              state <= ST_CONFIG;
            end else begin
              addr <= addr + 1'b1;
              reload_tlast_r <= (addr + 1'b1 == NUM_TAPS-1);
            end
          end
        end
        default: begin // ST_CONFIG
          config_tvalid_r <= 1'b1;
          if (config_tready == 1'b1) begin
            config_tvalid_r <= 1'b0;
            state <= ST_IDLE;
          end
        end
      endcase
    end
  end

endmodule
