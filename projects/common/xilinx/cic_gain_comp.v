// cic_gain_comp.v
//
// Applies the per-rate shift+gain from cic_gain_lut to a CIC core's
// Full_Precision (raw, unshifted) output, restoring the level the core
// already gives at R=32 to every other rate. See cic_gain_lut.v and
// docs/03_RX_CIC_FIR_TX_FIR_CIC.md for why this exists.
//
// Pipeline: gain_din (IN_WIDTH, signed, RAW Full_Precision CIC output = input * R**EXP,
//                exactly -- confirmed by direct calibration sweep, not derived)
//           >>> shift (per-rate barrel shift from cic_gain_lut; reproduces
//               exactly what the OLD truncating-mode core used to output)
//           -> MID_WIDTH signed value
//           x gain (16-bit unsigned Q1.14, from cic_gain_lut)
//           -> round to nearest (round-half-up on the discarded fraction)
//           -> saturate to OUT_WIDTH signed
//
// Ports are named gain_din/gain_dout, NOT din/dout: the full adrv9026_zcu102
// project loads the whole ADI library as an IP repository, which defines a
// custom bus interface (analog.com:interface:fifo_rd) that Vivado's IP
// packager auto-infers from ports literally named din/dout -- silently
// turning them into interface pins that then can't connect to an ordinary
// pin (confirmed by a real build failure: "ad_connect: Cannot connect
// non-interface to interface"). din_valid/dout_valid were not affected and
// are unchanged.
//
// Three pipeline stages: shift, multiply, round+saturate. dout_valid is
// din_valid delayed by the same three cycles; use it to keep any downstream
// valid tracking aligned.
//
// MID_WIDTH sizing: shift is chosen (in cic_gain_lut) so that
// gain_din >>> shift lands in the same range the CIC core's own raw output used
// to occupy before Full_Precision was enabled -- bounded by the original
// 16-bit sample's full scale, plus guard bits for intermediate rounding.
// 18 bits is 2 bits of margin over that 16-bit bound.
//
// PROD_WIDTH is sized as (MID_WIDTH+1) + 17 = MID_WIDTH+18 -- the exact
// width an (MID_WIDTH+1)-bit signed times a 17-bit signed product needs,
// with no shortfall (an earlier version of this module under-sized this by
// 2 bits; harmless there only because IN_WIDTH was large enough to absorb
// it by accident -- fixed properly here since MID_WIDTH is now tight).

module cic_gain_comp #(
  parameter IN_WIDTH    = 48,   // width of the CIC core's RAW Full_Precision output
  parameter SHIFT_WIDTH = 5,    // enough for shift values up to 25 (RX R=32)
  parameter MID_WIDTH   = 18,   // width after the per-rate shift, before the gain multiply
  parameter OUT_WIDTH   = 16    // width after this stage (16, to match everything downstream)
) (
  input                          clk,
  input                          aresetn,

  input      [IN_WIDTH-1:0]      gain_din,    // signed, RAW Full_Precision CIC output
  input                          din_valid,

  input      [SHIFT_WIDTH-1:0]   shift,       // per-rate shift from cic_gain_lut, combinational
  input      [15:0]              gain,        // unsigned Q1.14 from cic_gain_lut, combinational
                                               // (both only change when the rate changes, which
                                               //  the existing sequencer already gates safely)

  output reg [OUT_WIDTH-1:0]     gain_dout,
  output reg                     dout_valid
);

  localparam PROD_WIDTH = MID_WIDTH + 18;  // exact: (MID_WIDTH+1)-bit x 17-bit product
  localparam FRAC_BITS  = 14;              // Q1.14

  // Stage 1: per-rate right shift
  reg signed [MID_WIDTH-1:0] shifted_r;
  reg                        valid_s1;

  wire signed [IN_WIDTH-1:0] din_s = gain_din;
  wire signed [IN_WIDTH-1:0] shifted_full = din_s >>> shift;

  always @(posedge clk) begin
    if (!aresetn) begin
      shifted_r <= {MID_WIDTH{1'b0}};
      valid_s1  <= 1'b0;
    end else begin
      shifted_r <= shifted_full[MID_WIDTH-1:0];
      valid_s1  <= din_valid;
    end
  end

  // Stage 2: multiply by the Q1.14 gain
  reg signed [PROD_WIDTH-1:0] prod_r;
  reg                         valid_s2;

  wire signed [MID_WIDTH:0] shifted_ext = {shifted_r[MID_WIDTH-1], shifted_r};  // sign-extend by 1
  wire signed [16:0]        gain_ext    = {1'b0, gain};                        // zero-extend (unsigned)

  always @(posedge clk) begin
    if (!aresetn) begin
      prod_r   <= {PROD_WIDTH{1'b0}};
      valid_s2 <= 1'b0;
    end else begin
      prod_r   <= shifted_ext * gain_ext;
      valid_s2 <= valid_s1;
    end
  end

  // Stage 3: round to nearest (round-half-up), then saturate
  wire signed [PROD_WIDTH-1:0] rounded = prod_r + (1 <<< (FRAC_BITS-1));
  wire signed [PROD_WIDTH-FRAC_BITS-1:0] shifted_out = rounded >>> FRAC_BITS;

  localparam signed [OUT_WIDTH-1:0] MAX_POS = {1'b0, {(OUT_WIDTH-1){1'b1}}};
  localparam signed [OUT_WIDTH-1:0] MAX_NEG = {1'b1, {(OUT_WIDTH-1){1'b0}}};

  always @(posedge clk) begin
    if (!aresetn) begin
      gain_dout  <= {OUT_WIDTH{1'b0}};
      dout_valid <= 1'b0;
    end else begin
      if (shifted_out > $signed(MAX_POS))
        gain_dout <= MAX_POS;
      else if (shifted_out < $signed(MAX_NEG))
        gain_dout <= MAX_NEG;
      else
        gain_dout <= shifted_out[OUT_WIDTH-1:0];
      dout_valid <= valid_s2;
    end
  end

endmodule
