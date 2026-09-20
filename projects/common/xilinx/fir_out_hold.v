`timescale 1ns/100ps

// Holds the last valid FIR output until the next one arrives, so the
// downstream CIC (which samples only on its own tready) always sees a
// stable value regardless of FIR latency.
module fir_out_hold #(
  parameter DATA_WIDTH = 16
) (
  input                       clk,
  input                       aresetn,
  input                       en,
  input  [DATA_WIDTH-1:0]     din,
  output reg [DATA_WIDTH-1:0] dout
);

  always @(posedge clk) begin
    if (aresetn == 1'b0)
      dout <= {DATA_WIDTH{1'b0}};
    else if (en == 1'b1)
      dout <= din;
  end

endmodule
