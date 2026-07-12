`timescale 1ns / 1ps
//Synchronours FIFO

module fifo #(
    parameter int WIDTH = 32,
    parameter int DEPTH = 8
) (
    input logic               clk,
    input logic               rst_n,
    input logic               wr_enable,
    input logic               rd_enable,
    input logic [WIDTH-1 : 0] data_in,

    output logic [WIDTH-1 : 0] data_out,
    output logic               empty,
    output logic               full
);

  logic [WIDTH-1:0] mem[DEPTH];
  logic [$clog2(DEPTH):0] w_ptr;
  logic [$clog2(DEPTH):0] r_ptr;

  always_ff @(posedge clk) begin
    if (rst_n) begin
      w_ptr <= 0;
      r_ptr <= 0;
    end

    if (wr_enable && !full) begin
      mem[w_ptr] <= data_in;
      w_ptr <= w_ptr + 1;
    end

    if (rd_enable && !empty) begin
      data_out <= mem[r_ptr];
      r_ptr    <= r_ptr + 1;
    end

  end

  assign empty = (w_ptr == r_ptr);
  assign full  = (w_ptr + 1 == r_ptr);


endmodule


