// Selects input flits and lookahead routes for five physical outputs.

`timescale 1ns / 1ps

module crossbar #(
    parameter int NUM_PORTS = 5,

    parameter int FLIT_W    = 40
) (

    input logic clk,
    input logic rst_n,

    input  logic [NUM_PORTS-1:0][FLIT_W-1:0] xbar_in_data,
    input  logic [NUM_PORTS-1:0][3:0]  xbar_in_route_next,

    input  logic [NUM_PORTS-1:0][2:0]  xbar_sel,
    input  logic [NUM_PORTS-1:0]       st_valid,

    output logic [NUM_PORTS-1:0][FLIT_W-1:0] xbar_out_data,
    output logic [NUM_PORTS-1:0][3:0]  xbar_out_route_next
);

  always_comb begin : mux5
    logic [FLIT_W-1:0] d;
    logic [3:0]  r;

    xbar_out_data       = '0;
    xbar_out_route_next = '0;

    for (int o = 0; o < NUM_PORTS; o++) begin

      d = '0;
      r = '0;
      if (st_valid[o] && (xbar_sel[o] < 3'(NUM_PORTS))) begin
        d = xbar_in_data[xbar_sel[o]];
        r = xbar_in_route_next[xbar_sel[o]];
      end
      xbar_out_data[o]       = d;
      xbar_out_route_next[o] = r;
    end
  end

  generate
    for (genvar o = 0; o < NUM_PORTS; o++) begin : gen_xbar_assert

      assert property (@(posedge clk) disable iff (!rst_n)
                       st_valid[o] |-> (xbar_sel[o] < 3'(NUM_PORTS)))
        else $error("crossbar: output %0d granted input index %0d, out of range 0..%0d",
                    o, xbar_sel[o], NUM_PORTS - 1);

      assert property (@(posedge clk) disable iff (!rst_n)
                       !st_valid[o] |->
                         ((xbar_out_data[o] == FLIT_W'(0)) &&
                          (xbar_out_route_next[o] == 4'b0)))
        else $error("crossbar: idle output %0d drove data=%h route=%h",
                    o, xbar_out_data[o], xbar_out_route_next[o]);

      assert property (@(posedge clk) disable iff (!rst_n)
                       (st_valid[o] && (xbar_sel[o] < 3'(NUM_PORTS))) |->
                         ((xbar_out_data[o] == xbar_in_data[xbar_sel[o]]) &&
                          (xbar_out_route_next[o] == xbar_in_route_next[xbar_sel[o]])))
        else $error("crossbar: output %0d does not track its selection (%0d)",
                    o, xbar_sel[o]);

    end
  endgenerate

endmodule
