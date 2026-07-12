`timescale 1ns / 1ps

module tb_fifo;

  //--------------------------------------------------------------------------
  // Parameters
  //--------------------------------------------------------------------------

  parameter int WIDTH = 32;
  parameter int DEPTH = 8;

  //--------------------------------------------------------------------------
  // DUT Signals
  //--------------------------------------------------------------------------

  logic             clk;
  logic             rst_n;
  logic             wr_enable;
  logic             rd_enable;
  logic [WIDTH-1:0] data_in;

  logic [WIDTH-1:0] data_out;
  logic             empty;
  logic             full;

  //Golden Memory
  logic [WIDTH-1:0] fifo_mem  [$];

  //--------------------------------------------------------------------------
  // DUT Instantiation
  //--------------------------------------------------------------------------

  fifo #(
      .WIDTH(WIDTH),
      .DEPTH(DEPTH)
  ) dut (
      .clk      (clk),
      .rst_n    (rst_n),
      .wr_enable(wr_enable),
      .rd_enable(rd_enable),
      .data_in  (data_in),

      .data_out(data_out),
      .empty   (empty),
      .full    (full)
  );

  //--------------------------------------------------------------------------
  // Clock Generation
  //--------------------------------------------------------------------------

  initial begin
    clk = 0;
    forever #5 clk = ~clk;
  end

  //--------------------------------------------------------------------------
  // Test Stimulus
  //--------------------------------------------------------------------------

  initial begin
    //applying reset
    rst_n = 0;
    #20 rst_n = 1;

    wr_enable = 0;
    rd_enable = 0;
    data_in   = 0;

    //starting writing
    wr_enable = 1;
    write_fifo(32'h1234);
    write_fifo(32'h1243);
    write_fifo(32'h1532);
    write_fifo(32'h1754);
    write_fifo(32'h1274);
    write_fifo(32'h1984);
    write_fifo(32'h1235);
    write_fifo(32'h9856);
    write_fifo(32'hAE32);
    wr_enable = 0;

    rd_enable = 1;
    read_fifo();
    read_fifo();
    read_fifo();
    read_fifo();
    read_fifo();
    read_fifo();
    read_fifo();
    read_fifo();
    read_fifo();


    $finish;
  end

  //--------------------------------------------------------------------------
  // Optional Tasks
  //--------------------------------------------------------------------------

  task automatic write_fifo(input logic [WIDTH-1:0] data);
    begin
      @(posedge clk) begin
        data_in = data;
        fifo_mem.push_back(data);
        $display("memory = %p", fifo_mem);
      end
    end
  endtask


  task automatic read_fifo();
    begin
      fifo_mem.pop_front();
      $display("memory = %p", fifo_mem);
    end
  endtask

  //--------------------------------------------------------------------------
  // Optional Monitor
  //--------------------------------------------------------------------------

  initial begin
    $monitor("Time=%0t | wr=%0b rd=%0b din=%0h dout=%0h empty=%0b full=%0b", $time, wr_enable,
             rd_enable, data_in, data_out, empty, full);
  end

  //--------------------------------------------------------------------------
  // Waveform Dump
  //--------------------------------------------------------------------------

  initial begin
    $dumpfile("fifo_tb.vcd");
    $dumpvars(0, tb_fifo);
  end

endmodule

