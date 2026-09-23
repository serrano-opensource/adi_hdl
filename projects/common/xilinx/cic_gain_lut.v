// cic_gain_lut.v
//
// Per-rate lookup for CIC output compensation. The bare cic_compiler core,
// configured for Full_Precision output, produces the RAW unshifted product
// (input * R**EXP, confirmed by direct calibration sweep against the real
// IP -- see run_tx_fp_calib.tcl / run_rx_fp_calib.tcl results). This table
// provides both pieces needed to bring that back to a correctly-scaled
// 16-bit sample:
//
//   shift: the per-rate right-shift amount (raw >>> shift reproduces
//          exactly what the OLD truncating-mode core used to output --
//          confirmed digit-for-digit against this session's original
//          sweep, e.g. TX R=5: 625000 >>> 10 = 610)
//   gain:  the Q1.14 reciprocal gain that restores THAT shifted value to
//          the same full-scale level R=32 already has (unsigned Q1.14,
//          16'd16384 = 1.000)
//
// Both are consumed by cic_gain_comp.v: shift first (a cheap barrel
// shifter, no DSP), then multiply by gain (fits a single DSP48E2 once the
// shift has reduced the operand down from 40/48 bits to ~18).
//
// Indexed directly by the same rate value already written to CIC_RATE /
// TX_CIC_RATE -- no new register, nothing visible to firmware.

module cic_gain_lut #(
  parameter EXP = 4   // 4 = TX interpolator (R^4 gain), 5 = RX decimator (R^5 gain)
) (
  input      [7:0]  rate,   // same value written to CIC_RATE / TX_CIC_RATE (4..32)
  output reg [15:0] gain,   // unsigned Q1.14, 16'd16384 = 1.000
  output reg [4:0]  shift   // per-rate right-shift amount (max 25, RX R=32)
);

  always @(*) begin
    if (EXP == 4) begin
      case (rate)
      8'd4 : begin gain = 16'd16384; shift = 5'd8; end
      8'd5 : begin gain = 16'd26844; shift = 5'd10; end
      8'd6 : begin gain = 16'd25891; shift = 5'd11; end
      8'd7 : begin gain = 16'd27950; shift = 5'd12; end
      8'd8 : begin gain = 16'd16384; shift = 5'd12; end
      8'd9 : begin gain = 16'd20457; shift = 5'd13; end
      8'd10: begin gain = 16'd26844; shift = 5'd14; end
      8'd11: begin gain = 16'd18335; shift = 5'd14; end
      8'd12: begin gain = 16'd25891; shift = 5'd15; end
      8'd13: begin gain = 16'd18797; shift = 5'd15; end
      8'd14: begin gain = 16'd27950; shift = 5'd16; end
      8'd15: begin gain = 16'd21210; shift = 5'd16; end
      8'd16: begin gain = 16'd16384; shift = 5'd16; end
      8'd17: begin gain = 16'd25712; shift = 5'd17; end
      8'd18: begin gain = 16'd20457; shift = 5'd17; end
      8'd19: begin gain = 16'd16478; shift = 5'd17; end
      8'd20: begin gain = 16'd26844; shift = 5'd18; end
      8'd21: begin gain = 16'd22084; shift = 5'd18; end
      8'd22: begin gain = 16'd18335; shift = 5'd18; end
      8'd23: begin gain = 16'd30696; shift = 5'd19; end
      8'd24: begin gain = 16'd25891; shift = 5'd19; end
      8'd25: begin gain = 16'd21990; shift = 5'd19; end
      8'd26: begin gain = 16'd18797; shift = 5'd19; end
      8'd27: begin gain = 16'd32327; shift = 5'd20; end
      8'd28: begin gain = 16'd27950; shift = 5'd20; end
      8'd29: begin gain = 16'd24290; shift = 5'd20; end
      8'd30: begin gain = 16'd21210; shift = 5'd20; end
      8'd31: begin gain = 16'd18603; shift = 5'd20; end
      8'd32: begin gain = 16'd16384; shift = 5'd20; end
        default: begin gain = 16'd16384; shift = 5'd0; end   // out-of-range rate: unity, don't scale blindly
      endcase
    end else begin // EXP == 5
      case (rate)
      8'd4 : begin gain = 16'd16384; shift = 5'd10; end
      8'd5 : begin gain = 16'd21475; shift = 5'd12; end
      8'd6 : begin gain = 16'd17261; shift = 5'd13; end
      8'd7 : begin gain = 16'd31943; shift = 5'd15; end
      8'd8 : begin gain = 16'd16384; shift = 5'd15; end
      8'd9 : begin gain = 16'd18184; shift = 5'd16; end
      8'd10: begin gain = 16'd21475; shift = 5'd17; end
      8'd11: begin gain = 16'd26668; shift = 5'd18; end
      8'd12: begin gain = 16'd17261; shift = 5'd18; end
      8'd13: begin gain = 16'd23135; shift = 5'd19; end
      8'd14: begin gain = 16'd31943; shift = 5'd20; end
      8'd15: begin gain = 16'd22624; shift = 5'd20; end
      8'd16: begin gain = 16'd16384; shift = 5'd20; end
      8'd17: begin gain = 16'd24199; shift = 5'd21; end
      8'd18: begin gain = 16'd18184; shift = 5'd21; end
      8'd19: begin gain = 16'd27753; shift = 5'd22; end
      8'd20: begin gain = 16'd21475; shift = 5'd22; end
      8'd21: begin gain = 16'd16826; shift = 5'd22; end
      8'd22: begin gain = 16'd26668; shift = 5'd23; end
      8'd23: begin gain = 16'd21354; shift = 5'd23; end
      8'd24: begin gain = 16'd17261; shift = 5'd23; end
      8'd25: begin gain = 16'd28147; shift = 5'd24; end
      8'd26: begin gain = 16'd23135; shift = 5'd24; end
      8'd27: begin gain = 16'd19157; shift = 5'd24; end
      8'd28: begin gain = 16'd31943; shift = 5'd25; end
      8'd29: begin gain = 16'd26803; shift = 5'd25; end
      8'd30: begin gain = 16'd22624; shift = 5'd25; end
      8'd31: begin gain = 16'd19203; shift = 5'd25; end
      8'd32: begin gain = 16'd16384; shift = 5'd25; end
        default: begin gain = 16'd16384; shift = 5'd0; end
      endcase
    end
  end

endmodule
