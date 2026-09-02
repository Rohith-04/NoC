`timescale 1ns / 1ps

//------------------------------------------------------------------------------
// Synchronous FIFO
//
// Features
// --------
// - Pointer-based implementation using wrap-bit pointers.
// - Power-of-two depth.
// - Simultaneous read/write support.
// - Empty FIFO bypass to eliminate an unnecessary cycle of latency.
// - Protocol violation detection.
//
// Protocol
// --------
// - A write while full is rejected and asserts 'err'.
// - A read while empty is rejected and asserts 'err'.
// - If write and read are both asserted while full:
//     * the write is rejected,
//     * 'err' is asserted,
//     * the read proceeds normally.
// - If write and read are both asserted while empty:
//     * data_in is bypassed directly to data_out,
//     * FIFO occupancy remains unchanged.
//
// Notes
// -----
// The empty FIFO bypass is NOT a First-Word Fall-Through (FWFT)
// implementation. It forwards data directly from data_in to data_out when
// both read and write are asserted while the FIFO is empty.
//
// The interface exposes full/empty status; credit accounting is expected
// to be handled by the surrounding NoC logic.
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

  //-------------------------------------------------------------------------
  // Parameter checks
  //-------------------------------------------------------------------------

  initial begin
    assert (WIDTH > 0)
    else $fatal(1, "fifo: WIDTH must be greater than 0, got %0d", WIDTH);

    assert ((DEPTH >= 2) && ((DEPTH & (DEPTH - 1)) == 0))
    else $fatal(1, "fifo: DEPTH must be a power of two >= 2, got %0d", DEPTH);
  end

  localparam int ADDRWIDTH = $clog2(DEPTH);

  //-------------------------------------------------------------------------
  // Memory
  //-------------------------------------------------------------------------

  logic [WIDTH-1:0] mem[DEPTH];

  //-------------------------------------------------------------------------
  // Pointers
  //
  // Pointer width is ADDRWIDTH+1.
  // MSB = wrap bit
  // Lower ADDRWIDTH bits = memory index
  //-------------------------------------------------------------------------

  logic [ADDRWIDTH:0] w_ptr;
  logic [ADDRWIDTH:0] r_ptr;

  //-------------------------------------------------------------------------
  // Status
  //-------------------------------------------------------------------------

  assign empty = (w_ptr == r_ptr);

  assign full =
        (w_ptr[ADDRWIDTH] != r_ptr[ADDRWIDTH]) &&
        (w_ptr[ADDRWIDTH-1:0] == r_ptr[ADDRWIDTH-1:0]);

  //-------------------------------------------------------------------------
  // Protocol error
  //
  // A write while full is illegal.
  // A read while empty is illegal unless it is the empty FIFO bypass case.
  //-------------------------------------------------------------------------

  assign err = (wr_enable && full) || (rd_enable && empty && !wr_enable);

  //-------------------------------------------------------------------------
  // Sequential Logic
  //-------------------------------------------------------------------------

  always_ff @(posedge clk) begin

    if (!rst_n) begin

      w_ptr    <= '0;
      r_ptr    <= '0;
      data_out <= '0;

    end else begin

      //-----------------------------------------------------------------
      // Empty FIFO bypass
      //
      // WR + RD while empty:
      // - data does not enter storage
      // - data goes directly to output
      // - pointers remain unchanged
      //-----------------------------------------------------------------

      if (empty && wr_enable && rd_enable) begin

        data_out <= data_in;

      end  //-----------------------------------------------------------------
           // Normal / independent read and write handling
           //-----------------------------------------------------------------

      else begin

        //-------------------------------------------------------------
        // READ
        //
        // A read is allowed whenever the FIFO is not empty.
        // This deliberately executes even when the FIFO is full and
        // wr_enable is also asserted.
        //-------------------------------------------------------------

        if (rd_enable && !empty) begin

          data_out <= mem[r_ptr[ADDRWIDTH-1:0]];
          r_ptr    <= r_ptr + 1'b1;

        end

        //-------------------------------------------------------------
        // WRITE
        //
        // A write is allowed whenever the FIFO is not full.
        //
        // If full:
        //   write is rejected
        //   r_ptr may still advance because the read above is
        //   independent of the write decision.
        //-------------------------------------------------------------

        if (wr_enable && !full) begin

          mem[w_ptr[ADDRWIDTH-1:0]] <= data_in;
          w_ptr <= w_ptr + 1'b1;

        end

      end

    end

  end

endmodule
