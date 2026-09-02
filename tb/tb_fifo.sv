`timescale 1ns / 1ps

module tb_fifo;

  //---------------------------------------------------------------
  // 1. Parameters
  //---------------------------------------------------------------
  localparam int WIDTH = 32;
  localparam int DEPTH = 8;
  localparam realtime CLK_PERIOD = 10ns;

  //---------------------------------------------------------------
  // 2. DUT I/O Signals
  //---------------------------------------------------------------
  logic             clk;
  logic             rst_n;

  logic             wr_enable;
  logic             rd_enable;
  logic [WIDTH-1:0] data_in;

  logic [WIDTH-1:0] data_out;
  logic             empty;
  logic             full;
  logic             err;

  //---------------------------------------------------------------
  // 3. Reference Model State
  //---------------------------------------------------------------
  logic [WIDTH-1:0] ref_model  [$];

  //---------------------------------------------------------------
  // 4. Bookkeeping
  //---------------------------------------------------------------
  int               checks = 0;
  int               errors = 0;

  //---------------------------------------------------------------
  // 5. Clock Generation
  //---------------------------------------------------------------
  initial clk = 0;
  always #(CLK_PERIOD / 2) clk = ~clk;

  //---------------------------------------------------------------
  // 6. Reset Task
  //---------------------------------------------------------------
  task automatic reset_dut();
    wr_enable = 1'b0;
    rd_enable = 1'b0;
    data_in = '0;

    rst_n = 0;
    #(4 * CLK_PERIOD);

    rst_n = 1;

    ref_model.delete();
  endtask

  //---------------------------------------------------------------
  // 7. DUT Instantiation
  //---------------------------------------------------------------
  fifo #(
      .WIDTH(WIDTH),
      .DEPTH(DEPTH)
  ) dut (
      .clk      (clk),
      .rst_n    (rst_n),
      .wr_enable(wr_enable),
      .rd_enable(rd_enable),
      .data_in  (data_in),
      .data_out (data_out),
      .empty    (empty),
      .full     (full),
      .err      (err)
  );

  //---------------------------------------------------------------
  // 8. Check Task
  //---------------------------------------------------------------
  task automatic check(string name, bit cond);
    checks++;

    if (cond) $display("[PASS] %s", name);
    else begin
      $display("[FAIL] %s", name);
      errors++;
    end
  endtask

  //---------------------------------------------------------------
  // 9. Driver Tasks
  //---------------------------------------------------------------

  //---------------------------------------------------------------
  // WRITE ONLY
  //
  // Normal write:
  //   - write accepted
  //   - FIFO occupancy increases
  //
  // Write while full:
  //   - write rejected
  //   - err asserted
  //   - occupancy unchanged
  //---------------------------------------------------------------
  task automatic drive_write(input logic [WIDTH-1:0] data);
    bit was_full;
    bit exp_err;

    @(negedge clk);

    wr_enable = 1'b1;
    rd_enable = 1'b0;
    data_in   = data;

    was_full  = (ref_model.size() == DEPTH);
    exp_err   = was_full;

    #0;

    check("Write: err flag", err == exp_err);

    @(posedge clk);
    #1;

    if (!was_full) ref_model.push_back(data);

    check("Write: empty flag", empty == (ref_model.size() == 0));

    check("Write: full flag", full == (ref_model.size() == DEPTH));

    @(negedge clk);

    wr_enable = 1'b0;
  endtask

  //---------------------------------------------------------------
  // READ ONLY
  //
  // Normal read:
  //   - read accepted
  //   - oldest element returned
  //   - occupancy decreases
  //
  // Read while empty:
  //   - read rejected
  //   - err asserted
  //   - data_out unchanged
  //---------------------------------------------------------------
  task automatic drive_read();
    logic [WIDTH-1:0] exp_data;
    logic [WIDTH-1:0] prev_data_out;
    bit was_empty;
    bit exp_err;

    @(negedge clk);

    wr_enable     = 1'b0;
    rd_enable     = 1'b1;

    was_empty     = (ref_model.size() == 0);
    prev_data_out = data_out;
    exp_err       = was_empty;

    #0;

    check("Read: err flag", err == exp_err);

    @(posedge clk);
    #1;

    if (!was_empty) begin

      exp_data = ref_model.pop_front();

      check("Read: data_out", data_out == exp_data);

    end else begin

      check("Read: data_out held", data_out == prev_data_out);
    end

    check("Read: empty flag", empty == (ref_model.size() == 0));

    check("Read: full flag", full == (ref_model.size() == DEPTH));

    @(negedge clk);

    rd_enable = 1'b0;
  endtask

  //---------------------------------------------------------------
  // SIMULTANEOUS READ + WRITE
  //
  // Case 1: EMPTY
  //   - bypass data_in -> data_out
  //   - no memory write
  //   - no pointer movement
  //   - occupancy remains zero
  //   - err = 0
  //
  // Case 2: FULL
  //   - read proceeds
  //   - write is rejected
  //   - err = 1
  //   - occupancy decreases by one
  //
  // Case 3: NORMAL
  //   - read oldest element
  //   - write new element
  //   - occupancy unchanged
  //   - err = 0
  //---------------------------------------------------------------
  task automatic drive_read_write(input logic [WIDTH-1:0] data);
    logic [WIDTH-1:0] exp_data;
    bit was_empty;
    bit was_full;

    @(negedge clk);

    wr_enable = 1'b1;
    rd_enable = 1'b1;
    data_in   = data;

    was_empty = (ref_model.size() == 0);
    was_full  = (ref_model.size() == DEPTH);

    //-------------------------------------------------------------
    // Check combinational protocol signals BEFORE clock edge
    //-------------------------------------------------------------
    #0;

    if (was_empty) begin

      check("R/W empty bypass: err flag", err == 1'b0);

    end else if (was_full) begin

      check("R/W full: err flag", err == 1'b1);

    end else begin

      check("R/W normal: err flag", err == 1'b0);

    end

    //-------------------------------------------------------------
    // Clock edge: transaction occurs
    //-------------------------------------------------------------
    @(posedge clk);
    #1;

    //-------------------------------------------------------------
    // EMPTY + R/W: bypass
    //-------------------------------------------------------------
    if (was_empty) begin

      check("R/W empty bypass: empty flag", empty == 1'b1);

      check("R/W empty bypass: full flag", full == 1'b0);

      check("R/W empty bypass: data_out", data_out == data);

      // Reference model remains empty.
    end  //-------------------------------------------------------------
         // FULL + R/W:
         // read succeeds, write is rejected
         //-------------------------------------------------------------
    else if (was_full) begin

      exp_data = ref_model.pop_front();

      check("R/W full: empty flag", empty == 1'b0);

      check("R/W full: full flag", full == 1'b0);

      check("R/W full: data_out", data_out == exp_data);

      // No push_back(data).
    end  //-------------------------------------------------------------
         // NORMAL + R/W:
         // read and write both succeed
         //-------------------------------------------------------------
    else begin

      exp_data = ref_model.pop_front();
      ref_model.push_back(data);

      check("R/W normal: empty flag", empty == (ref_model.size() == 0));

      check("R/W normal: full flag", full == (ref_model.size() == DEPTH));

      check("R/W normal: data_out", data_out == exp_data);

    end

    @(negedge clk);

    wr_enable = 1'b0;
    rd_enable = 1'b0;

  endtask

  //---------------------------------------------------------------
  // 10. Directed Tests
  //---------------------------------------------------------------

  task automatic test_reset();
    $display("--- Running test_reset ---");

    reset_dut();

    check("Reset: empty", empty == 1'b1);

    check("Reset: full", full == 1'b0);

    check("Reset: err", err == 1'b0);
  endtask

  //---------------------------------------------------------------
  // Fill FIFO with writes
  //---------------------------------------------------------------
  task automatic test_write_only();
    $display("--- Running test_write_only ---");

    reset_dut();

    for (int i = 0; i < DEPTH; i++) begin
      drive_write($urandom);
    end
  endtask

  //---------------------------------------------------------------
  // Fill then drain FIFO
  //---------------------------------------------------------------
  task automatic test_read_only();
    $display("--- Running test_read_only ---");

    reset_dut();

    for (int i = 0; i < DEPTH; i++) begin
      drive_write($urandom);
    end

    for (int i = 0; i < DEPTH; i++) begin
      drive_read();
    end
  endtask

  //---------------------------------------------------------------
  // Explicit full condition
  //---------------------------------------------------------------
  task automatic test_full();
    $display("--- Running test_full ---");

    reset_dut();

    for (int i = 0; i < DEPTH; i++) begin
      drive_write($urandom);
    end

    check("Test Full: full flag asserted", full == 1'b1);

    check("Test Full: empty flag deasserted", empty == 1'b0);
  endtask

  //---------------------------------------------------------------
  // Explicit empty read violation
  //---------------------------------------------------------------
  task automatic test_empty();
    $display("--- Running test_empty ---");

    reset_dut();

    drive_read();

    check("Test Empty: empty flag asserted", empty == 1'b1);

    check("Test Empty: full flag deasserted", full == 1'b0);

    check("Test Empty: err asserted", err == 1'b1);
  endtask

  //---------------------------------------------------------------
  // Normal simultaneous read/write
  //---------------------------------------------------------------
  task automatic test_simultaneous_read_write();
    $display("--- Running test_simultaneous_read_write ---");

    reset_dut();

    // Partially fill FIFO.
    drive_write($urandom);
    drive_write($urandom);

    for (int i = 0; i < 5; i++) begin
      drive_read_write($urandom);
    end
  endtask

  //---------------------------------------------------------------
  // Empty FIFO bypass
  //---------------------------------------------------------------
  task automatic test_empty_bypass();
    $display("--- Running test_empty_bypass ---");

    reset_dut();

    drive_read_write($urandom);

    check("Test Bypass: reference model remains empty", ref_model.size() == 0);
  endtask

  //---------------------------------------------------------------
  // Full FIFO + simultaneous read/write
  //
  // This specifically verifies the new protocol:
  //
  //   READ  -> accepted
  //   WRITE -> rejected
  //   ERR   -> asserted
  //---------------------------------------------------------------
  task automatic test_full_read_write();
    $display("--- Running test_full_read_write ---");

    reset_dut();

    // Fill FIFO completely.
    for (int i = 0; i < DEPTH; i++) begin
      drive_write(i);
    end

    check("Full R/W: FIFO initially full", full == 1'b1);

    // Read + write while full.
    drive_read_write(32'hDEAD_BEEF);

    check("Full R/W: FIFO no longer full", full == 1'b0);

    check("Full R/W: occupancy reduced", ref_model.size() == DEPTH - 1);
  endtask

  //---------------------------------------------------------------
  // Write while full
  //---------------------------------------------------------------
  task automatic test_protocol_violation();
    $display("--- Running test_protocol_violation ---");

    reset_dut();

    // Fill FIFO completely.
    for (int i = 0; i < DEPTH; i++) begin
      drive_write($urandom);
    end

    // Attempt illegal write.
    drive_write($urandom);

    check("Protocol Violation: FIFO remains full", full == 1'b1);

    check("Protocol Violation: occupancy unchanged", ref_model.size() == DEPTH);
  endtask

  //---------------------------------------------------------------
  // 11. Randomized Test
  //---------------------------------------------------------------
  task automatic test_random(input int num_transactions);
    int op;

    $display("--- Running test_random ---");

    reset_dut();

    for (int i = 0; i < num_transactions; i++) begin

      op = $urandom_range(0, 2);

      case (op)

        0: drive_write($urandom);

        1: drive_read();

        2: drive_read_write($urandom);

      endcase

    end
  endtask

  //---------------------------------------------------------------
  // 12. Top-Level Test Sequence
  //---------------------------------------------------------------
  initial begin

    test_reset();

    test_write_only();
    test_read_only();

    test_full();
    test_empty();

    test_simultaneous_read_write();
    test_empty_bypass();
    test_full_read_write();

    test_protocol_violation();

    test_random(200);

    $display("----------------------------------------");
    $display("Checks : %0d", checks);
    $display("Errors : %0d", errors);

    if (errors == 0) $display("ALL TESTS PASSED");
    else $display("TEST FAILED");

    $finish;
  end

  //---------------------------------------------------------------
  // 13. Waveform Dump
  //---------------------------------------------------------------
  initial begin
    $dumpfile("sim/fifo.vcd");
    $dumpvars(0, tb_fifo);
  end

endmodule
