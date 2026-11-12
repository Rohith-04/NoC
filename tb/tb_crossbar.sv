// Self-checking tests for crossbar.

`timescale 1ns / 1ps

module tb_crossbar;

  import noc_tb_pkg::*;

  localparam int       NUM_PORTS   = 5;
  localparam realtime  CLK_PERIOD  = 10ns;

  localparam logic [3:0] DIR [NUM_PORTS] = '{4'b0000, 4'b0001, 4'b0010, 4'b0100, 4'b1000};

  logic                     clk;
  logic                     rst_n;

  logic [NUM_PORTS-1:0][FLIT_W-1:0] xbar_in_data;
  logic [NUM_PORTS-1:0][3:0]  xbar_in_route_next;
  logic [NUM_PORTS-1:0][2:0]  xbar_sel;
  logic [NUM_PORTS-1:0]       st_valid;

  logic [NUM_PORTS-1:0][FLIT_W-1:0] xbar_out_data;
  logic [NUM_PORTS-1:0][3:0]  xbar_out_route_next;

  initial clk = 0;
  always #(CLK_PERIOD / 2) clk = ~clk;

  crossbar #(
      .NUM_PORTS(NUM_PORTS)
  ) dut (
      .clk                (clk),
      .rst_n              (rst_n),
      .xbar_in_data       (xbar_in_data),
      .xbar_in_route_next (xbar_in_route_next),
      .xbar_sel           (xbar_sel),
      .st_valid           (st_valid),
      .xbar_out_data      (xbar_out_data),
      .xbar_out_route_next(xbar_out_route_next)
  );

  task automatic tick();
    @(negedge clk);
    #1;
  endtask

  task automatic reset_dut();
    st_valid           = '0;
    xbar_sel           = '0;
    xbar_in_data       = '0;
    xbar_in_route_next = '0;
    rst_n              = 0;
    repeat (4) @(posedge clk);
    @(negedge clk);
    rst_n = 1;
    #1;
  endtask

  function automatic logic [FLIT_W-1:0] pat(input int p);
    logic [FLIT_W-1:0] v;
    v = '0;
    v = with_id   (v, 8'(7 * p + 3));
    v = with_route(v, 4'(p));
    v = with_dst  (v, 3'(p), 3'((p + 1) % 8));
    v = with_kind (v, 2'(p % 4));
    v = with_type (v, FLIT_HEAD_TAIL);
    return v;
  endfunction

  task automatic drive_inputs();
    for (int p = 0; p < NUM_PORTS; p++) begin
      xbar_in_data[p]       = pat(p);
      xbar_in_route_next[p] = DIR[p];
    end
  endtask

  task automatic t1_idle_zero();
    int other;
    drive_inputs();
    st_valid = '0;

    for (int o = 0; o < NUM_PORTS; o++) xbar_sel[o] = 3'((o + 2) % NUM_PORTS);
    tick();

    for (int o = 0; o < NUM_PORTS; o++) begin
      check($sformatf("T1 idle output %0d data is zero", o), xbar_out_data[o], 32'h0);
      check($sformatf("T1 idle output %0d route is zero", o), xbar_out_route_next[o], 32'h0);
    end

    other = 0;
    for (int p = 0; p < NUM_PORTS; p++) other |= int'(xbar_in_data[p] != 32'h0);
    check("T1 stimulus really was nonzero", other[0], 1'b1);
  endtask

  task automatic t2_exhaustive();
    for (int o = 0; o < NUM_PORTS; o++) begin
      for (int p = 0; p < NUM_PORTS; p++) begin
        drive_inputs();
        st_valid = '0;
        xbar_sel = '0;
        st_valid[o] = 1'b1;
        xbar_sel[o] = 3'(p);
        tick();

        check($sformatf("T2 out %0d sel %0d data", o, p),
              xbar_out_data[o], xbar_in_data[p]);
        check($sformatf("T2 out %0d sel %0d route_next", o, p),
              xbar_out_route_next[o], {28'h0, xbar_in_route_next[p]});

        for (int q = 0; q < NUM_PORTS; q++) begin
          if (q != o) begin
            check($sformatf("T2 out %0d quiet while out %0d is active", q, o),
                  xbar_out_data[q], 32'h0);
            check($sformatf("T2 out %0d route quiet while out %0d is active", q, o),
                  xbar_out_route_next[q], 32'h0);
          end
        end
      end
    end
  endtask

  task automatic t3_all_active();
    int sel_of [NUM_PORTS];

    drive_inputs();
    st_valid = '1;

    for (int o = 0; o < NUM_PORTS; o++) begin
      sel_of[o]     = (o + 2) % NUM_PORTS;
      xbar_sel[o]   = 3'(sel_of[o]);
    end
    tick();

    for (int o = 0; o < NUM_PORTS; o++) begin
      check($sformatf("T3 out %0d selects input %0d (data)", o, sel_of[o]),
            xbar_out_data[o], xbar_in_data[sel_of[o]]);
      check($sformatf("T3 out %0d selects input %0d (route_next)", o, sel_of[o]),
            xbar_out_route_next[o], {28'h0, xbar_in_route_next[sel_of[o]]});
    end
  endtask

  task automatic t4_reselection();

    drive_inputs();
    st_valid      = '0;
    st_valid[0]   = 1'b1;
    xbar_sel      = '0;
    xbar_sel[0]   = 3'd1;
    tick();
    check("T4 out 0 first selection (data)", xbar_out_data[0], xbar_in_data[1]);

    xbar_sel[0] = 3'd3;
    tick();
    check("T4 out 0 moved selection (data)", xbar_out_data[0], xbar_in_data[3]);
    check("T4 out 0 moved selection (route)", xbar_out_route_next[0],
          {28'h0, xbar_in_route_next[3]});

    st_valid[0] = 1'b0;
    tick();
    check("T4 out 0 drops to zero when idle", xbar_out_data[0], 32'h0);
    check("T4 out 0 route drops to zero when idle", xbar_out_route_next[0], 32'h0);

    st_valid[0] = 1'b1;
    xbar_sel[0] = 3'd4;
    tick();
    check("T4 out 0 reselects after idle (data)", xbar_out_data[0], xbar_in_data[4]);
    check("T4 out 0 reselects after idle (route)", xbar_out_route_next[0],
          {28'h0, xbar_in_route_next[4]});
  endtask

  task automatic t5_route_pairs();

    drive_inputs();
    xbar_in_data[2] = xbar_in_data[1];

    st_valid    = '0;
    st_valid[0] = 1'b1;
    xbar_sel[0] = 3'd1;
    tick();
    check("T5 data from port 1", xbar_out_data[0], xbar_in_data[1]);
    check("T5 route_next from port 1, not port 2", xbar_out_route_next[0],
          {28'h0, xbar_in_route_next[1]});

    xbar_sel[0] = 3'd2;
    tick();
    check("T5 data identical across ports 1 and 2", xbar_out_data[0], xbar_in_data[2]);
    check("T5 route_next must still differ (from port 2)", xbar_out_route_next[0],
          {28'h0, xbar_in_route_next[2]});

    xbar_in_route_next[4] = xbar_in_route_next[3];
    xbar_sel[0]           = 3'd3;
    tick();
    check("T5 data from port 3", xbar_out_data[0], xbar_in_data[3]);
    check("T5 route_next from port 3", xbar_out_route_next[0],
          {28'h0, xbar_in_route_next[3]});

    xbar_sel[0] = 3'd4;
    tick();
    check("T5 data now differs (port 4)", xbar_out_data[0], xbar_in_data[4]);
    check("T5 route_next held at the port 4 value", xbar_out_route_next[0],
          {28'h0, xbar_in_route_next[4]});
  endtask

  initial begin : main
    if ($test$plusargs("vcd")) begin
      $dumpfile($sformatf("sim/%s.vcd", "crossbar"));
      $dumpvars(0, tb_crossbar);
    end

    reset_dut();

    $display("---- T1  idle output drives zero ----");
    t1_idle_zero();

    $display("---- T2  exhaustive (output, selected input) sweep ----");
    t2_exhaustive();

    $display("---- T3  all five outputs active at once ----");
    t3_all_active();

    $display("---- T4  one output re-selecting over time ----");
    t4_reselection();

    $display("---- T5  data and route_next come from the same port ----");
    t5_route_pairs();

    $display("");
    if (errors == 0) $display("ALL %0d CHECKS PASSED", checks);
    else $display("%0d/%0d CHECKS FAILED", errors, checks);

    $finish;
  end

endmodule
