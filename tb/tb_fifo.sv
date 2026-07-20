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
    #(4 * CLK_PERIOD);  //Waiting for 4 clock cycles
    rst_n = 1;

    //Clear the reference model
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
  task automatic drive_write(input logic [WIDTH-1:0] data);
    logic exp_err;

    @(negedge clk);
    wr_enable = 1'b1;
    rd_enable = 1'b0;
    data_in   = data;
    exp_err   = (ref_model.size() == DEPTH);

    #0;  // yield so the continuous assignment (err) gets to settle first
    check("Write: err flag", err == exp_err);

    @(posedge clk);
    #1;  // Check after positive edge

    if (!exp_err) begin
      ref_model.push_back(data);
    end

    check("Write: empty flag", empty == (ref_model.size() == 0));
    check("Write: full flag", full == (ref_model.size() == DEPTH));

    @(negedge clk);
    wr_enable = 1'b0;
  endtask

  task automatic drive_read();
    logic [WIDTH-1:0] exp_data;
    bit was_empty;

    @(negedge clk);
    wr_enable = 1'b0;
    rd_enable = 1'b1;
    was_empty = (ref_model.size() == 0);

    @(posedge clk);
    #1;  // Check after positive edge

    if (!was_empty) begin
      exp_data = ref_model.pop_front();
    end

    check("Read: err flag", err == 1'b0);
    check("Read: empty flag", empty == (ref_model.size() == 0));
    check("Read: full flag", full == (ref_model.size() == DEPTH));

    if (!was_empty) begin
      check("Read: data_out", data_out == exp_data);
    end

    @(negedge clk);
    rd_enable = 1'b0;
  endtask

  task automatic drive_read_write(input logic [WIDTH-1:0] data);
    logic [WIDTH-1:0] exp_data;
    logic [WIDTH-1:0] prev_data_out;  // THis is used when we do simultaneous read and write on full
    //fifo
    // According to the RTL the read should also get blocked so verifying if the read is holding the previous value or not
    bit was_empty;
    bit was_full;

    @(negedge clk);
    wr_enable = 1'b1;
    rd_enable = 1'b1;
    data_in = data;

    was_empty = (ref_model.size() == 0);
    was_full = (ref_model.size() == DEPTH);
    prev_data_out = data_out;

    @(posedge clk);
    #1;  // Check after positive edge

    if (was_empty) begin
      check("R/W bypass: err flag", err == 1'b0);
      check("R/W bypass: empty flag", empty == 1'b1);
      check("R/W bypass: full flag", full == 1'b0);
      check("R/W bypass: data_out", data_out == data);
    end else if (was_full) begin
      check("R/W full: err flag", err == 1'b1);
      check("R/W full: empty flag", empty == 1'b0);
      check("R/W full: full flag", full == 1'b1);
      check("R/W full: data_out_held", data_out == prev_data_out);
    end else begin
      exp_data = ref_model.pop_front();
      ref_model.push_back(data);
      check("R/W normal: err flag", err == 1'b0);
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

  task automatic test_write_only();
    $display("--- Running test_write_only ---");
    reset_dut();
    for (int i = 0; i < DEPTH; i++) begin
      drive_write($urandom);
    end
  endtask

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

  task automatic test_full();
    $display("--- Running test_full ---");
    reset_dut();
    for (int i = 0; i < DEPTH; i++) begin
      drive_write($urandom);
    end
    check("Test Full: full flag asserted", full == 1'b1);
  endtask

  task automatic test_empty();
    $display("--- Running test_empty ---");
    reset_dut();
    drive_read();
    check("Test Empty: empty flag asserted", empty == 1'b1);
  endtask

  task automatic test_simultaneous_read_write();
    $display("--- Running test_simultaneous_read_write ---");
    reset_dut();
    // Partially fill the FIFO first
    drive_write($urandom);
    drive_write($urandom);
    for (int i = 0; i < 5; i++) begin
      drive_read_write($urandom);
    end
  endtask

  task automatic test_empty_bypass();
    $display("--- Running test_empty_bypass ---");
    reset_dut();
    drive_read_write($urandom);
  endtask

  task automatic test_protocol_violation();
    $display("--- Running test_protocol_violation ---");
    reset_dut();
    // Fill the FIFO completely
    for (int i = 0; i < DEPTH; i++) begin
      drive_write($urandom);
    end
    // Attempt to write when full
    drive_write($urandom);
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
