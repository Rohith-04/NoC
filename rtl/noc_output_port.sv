// Updates header lookahead and registers the outgoing flit and VC sideband.

`timescale 1ns / 1ps

module noc_output_port #(

    parameter int FLIT_W = 40,
    parameter int NUM_VC = 4
) (
    input logic clk,
    input logic rst_n,

    input  logic [FLIT_W-1:0] xbar_out_data,
    input  logic [3:0]  xbar_out_route_next,

    input  logic        st_valid,
    input  logic [VC_W-1:0]  st_out_vc,

    output logic [FLIT_W-1:0] flit_data,
    output logic        flit_valid,
    output logic [VC_W-1:0]  vc_id
);

  localparam int VC_W = (NUM_VC > 1) ? $clog2(NUM_VC) : 1;

  logic [FLIT_W-1:0] merged;

  localparam logic [FLIT_W-1:0] ROUTE_BITS = 'h3C00;

  always_comb begin : header_merge

    merged = xbar_out_data;

    // Only headers contain a ROUTE field; BODY/TAIL bits are payload.
    if (xbar_out_data[0]) begin

      merged[13:10] = xbar_out_route_next;
    end
  end

  always_ff @(posedge clk) begin : link_reg
    if (!rst_n) begin
      flit_data  <= '0;
      flit_valid <= 1'b0;
      vc_id      <= '0;
    end else begin

      flit_data  <= st_valid ? merged : '0;
      flit_valid <= st_valid;
      vc_id      <= st_valid ? st_out_vc : '0;
    end
  end

  assert property (@(posedge clk) disable iff (!rst_n)
                   (st_valid && xbar_out_data[0]) |->
                     ((xbar_out_route_next == 4'b0000) || (xbar_out_route_next == 4'b0001) ||
                      (xbar_out_route_next == 4'b0010) || (xbar_out_route_next == 4'b0100) ||
                      (xbar_out_route_next == 4'b1000)))
    else $error("noc_output_port: route_next %b is not a legal direction",
                xbar_out_route_next);

  assert property (@(posedge clk) disable iff (!rst_n)
                   (st_valid && xbar_out_data[0]) |->
                     (merged[13:10] == xbar_out_route_next))
    else $error("noc_output_port: HEAD route not updated (have %h, want %h)",
                merged[13:10], xbar_out_route_next);

  assert property (@(posedge clk) disable iff (!rst_n)
                   (st_valid && !xbar_out_data[0]) |->
                     (merged[13:10] == xbar_out_data[13:10]))
    else $error("noc_output_port: non-HEAD payload [13:10] was overwritten");

  assert property (@(posedge clk) disable iff (!rst_n)
                   merged[3:2] == xbar_out_data[3:2])
    else $error("noc_output_port: KIND field [3:2] was modified by the merge");

  assert property (@(posedge clk) disable iff (!rst_n)
                   (merged & ~ROUTE_BITS) == (xbar_out_data & ~ROUTE_BITS))
    else $error("noc_output_port: merge modified bits outside [13:10]");

  assert property (@(posedge clk) disable iff (!rst_n)
                   st_valid |=> flit_valid)
    else $error("noc_output_port: flit_valid did not follow a grant");

  assert property (@(posedge clk) disable iff (!rst_n)
                   !st_valid |=> !flit_valid)
    else $error("noc_output_port: flit_valid asserted without a grant");

  assert property (@(posedge clk) disable iff (!rst_n)
                   st_valid |=> (flit_valid && (vc_id == $past(st_out_vc))))
    else $error("noc_output_port: vc_id sideband did not travel with its flit");

endmodule
