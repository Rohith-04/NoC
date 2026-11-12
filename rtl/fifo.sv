// Synchronous FIFO with registered output and empty-FIFO bypass.

`timescale 1ns / 1ps

module fifo #(

    parameter int WIDTH = 40,

    parameter int DEPTH = 4
) (
    input logic clk,
    input logic rst_n,

    input logic             wr_enable,
    input logic             rd_enable,
    input logic [WIDTH-1:0] data_in,

    output logic [WIDTH-1:0] data_out,
    output logic             empty,
    output logic             full,
    output logic             err
);

  initial begin
    assert (WIDTH > 0)
    else $fatal(1, "fifo: WIDTH must be greater than 0, got %0d", WIDTH);

    assert ((DEPTH >= 2) && ((DEPTH & (DEPTH - 1)) == 0))
    else $fatal(1, "fifo: DEPTH must be a power of two >= 2, got %0d", DEPTH);
  end

  localparam int ADDRWIDTH = $clog2(DEPTH);

  logic [WIDTH-1:0] mem[DEPTH];

  logic [ADDRWIDTH:0] w_ptr;
  logic [ADDRWIDTH:0] r_ptr;

  assign empty = (w_ptr == r_ptr);

  assign full =
        (w_ptr[ADDRWIDTH] != r_ptr[ADDRWIDTH]) &&
        (w_ptr[ADDRWIDTH-1:0] == r_ptr[ADDRWIDTH-1:0]);

  assign err = (wr_enable && full) || (rd_enable && empty && !wr_enable);

  always_ff @(posedge clk) begin

    if (!rst_n) begin

      w_ptr    <= '0;
      r_ptr    <= '0;
      data_out <= '0;

    end else begin

      // Bypass storage when an empty FIFO is written and fetched together.
      if (empty && wr_enable && rd_enable) begin

        data_out <= data_in;

      end

      else begin

        if (rd_enable && !empty) begin

          data_out <= mem[r_ptr[ADDRWIDTH-1:0]];
          r_ptr    <= r_ptr + 1'b1;

        end

        if (wr_enable && !full) begin

          mem[w_ptr[ADDRWIDTH-1:0]] <= data_in;
          w_ptr <= w_ptr + 1'b1;

        end

      end

    end

  end

endmodule
