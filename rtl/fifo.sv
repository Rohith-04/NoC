`timescale 1ns / 1ps
//------------------------------------------------------------------------------
// Synchronous FIFO
//
// Features
// --------
// - Pointer-based implementation using wrap-bit pointers.
// - Credit-based flow control.
// - Simultaneous read/write support.
// - Empty FIFO bypass to eliminate an unnecessary cycle of latency.
// - Protocol violation detection.
//
// Notes
// -----
// This FIFO is intended to be used in a credit-based NoC. A write request is
// expected only when space is available in the FIFO.
//
// If a write is attempted while the FIFO is full, the FIFO treats it as a
// protocol violation, asserts 'err', and does not modify its internal state.
//
// The empty FIFO bypass is NOT a First-Word Fall-Through (FWFT)
// implementation. It simply forwards the incoming data directly to the output
// when both read and write are asserted while the FIFO is empty.
//------------------------------------------------------------------------------

module fifo #(
    parameter int WIDTH = 32,
    parameter int DEPTH = 8
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
    assert ((DEPTH > 0) && ((DEPTH & (DEPTH - 1)) == 0))
    else $fatal(1, "fifo: DEPTH must be a power of two, got %0d", DEPTH);
  end

  localparam int ADDRWIDTH = $clog2(DEPTH);

  //-------------------------------------------------------------------------
  // Memory Array
  //-------------------------------------------------------------------------

  logic [WIDTH-1:0] mem[DEPTH];

  //-------------------------------------------------------------------------
  // Read and Write Pointers
  //
  // The MSB acts as a wrap bit while the lower bits index the memory.
  //-------------------------------------------------------------------------

  logic [ADDRWIDTH:0] w_ptr;
  logic [ADDRWIDTH:0] r_ptr;

  //-------------------------------------------------------------------------
  // Sequential Logic
  //-------------------------------------------------------------------------

  always_ff @(posedge clk) begin

    if (!rst_n) begin
      w_ptr    <= '0;
      r_ptr    <= '0;
      data_out <= '0;
    end  // Protocol violation.
         // A correctly functioning credit-based system should never attempt
                                         // a write while the FIFO is full.
    else if (wr_enable && full) begin
      // Hold FIFO state.
    end  //---------------------------------------------------------------------
         // Simultaneous Read and Write
                                                                                          //---------------------------------------------------------------------
    else if (wr_enable && rd_enable) begin

      // Empty FIFO bypass.
      //
      // Instead of writing into the FIFO and reading it back one cycle
      // later, forward the incoming data directly to the output.
      //
      // Since the data never enters the FIFO storage, the pointers remain
      // unchanged.
      // Note: Credit return behavior for the empty bypass case is TBD.
      // The upstream credit counter must account for this case correctly.
      if (empty) begin
        data_out <= data_in;
      end  // Normal simultaneous read/write.
      else begin
        data_out <= mem[r_ptr[ADDRWIDTH-1:0]];
        mem[w_ptr[ADDRWIDTH-1:0]] <= data_in;

        r_ptr <= r_ptr + 1'b1;
        w_ptr <= w_ptr + 1'b1;
      end

    end  //---------------------------------------------------------------------
         // Write Only
                                                                                          //---------------------------------------------------------------------
    else if (wr_enable) begin

      mem[w_ptr[ADDRWIDTH-1:0]] <= data_in;
      w_ptr <= w_ptr + 1'b1;

    end  //---------------------------------------------------------------------
         // Read Only
                                                                                          //---------------------------------------------------------------------
    else if (rd_enable) begin

      if (!empty) begin
        data_out <= mem[r_ptr[ADDRWIDTH-1:0]];
        r_ptr <= r_ptr + 1'b1;
      end

    end

  end

  //-------------------------------------------------------------------------
  // Status Flags
  //-------------------------------------------------------------------------

  // FIFO is empty when both pointers are identical.
  assign empty = (w_ptr == r_ptr);

  // FIFO is full when the address bits are equal but the wrap bits differ.
  assign full =
        (w_ptr[ADDRWIDTH] != r_ptr[ADDRWIDTH]) &&
        (w_ptr[ADDRWIDTH-1:0] == r_ptr[ADDRWIDTH-1:0]);

  // Protocol violation.
  // Indicates an illegal write request while the FIFO is full.
  assign err = wr_enable && full;

endmodule
