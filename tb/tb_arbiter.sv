// Self-checking tests for arbiter.

`timescale 1ns / 1ps

module tb_arbiter;

  import noc_tb_pkg::*;

  localparam int NUM_PORTS     = 5;
  parameter  int NUM_VC        = 4;

  localparam int VC_W          = (NUM_VC > 1) ? $clog2(NUM_VC) : 1;
  localparam int LOCAL_IDX     = 0;
  parameter  int FIFO_DEPTH   = 4;
  localparam int LOCAL_CREDITS = 4;

  localparam int P_LOCAL  = 0;
  localparam int P_NORTH  = 1;
  localparam int P_EAST   = 2;
  localparam int P_WEST   = 3;
  localparam int P_SOUTH  = 4;

  localparam logic [3:0] DIR_LOCAL = 4'b0000;
  localparam logic [3:0] DIR_NORTH = 4'b0001;
  localparam logic [3:0] DIR_EAST  = 4'b0010;
  localparam logic [3:0] DIR_WEST  = 4'b0100;
  localparam logic [3:0] DIR_SOUTH = 4'b1000;

  localparam time CLK_HALF = 5;
  localparam time SETTLE   = 2;

  logic clk = 0;
  logic rst_n = 0;

  always #(CLK_HALF) clk = ~clk;

  logic [NUM_PORTS-1:0][NUM_VC-1:0]      va_req;
  logic [NUM_PORTS-1:0][NUM_VC-1:0][3:0] va_req_out_port;
  logic [NUM_PORTS-1:0][NUM_VC-1:0]      va_req_single;
  logic [NUM_PORTS-1:0][NUM_VC-1:0]      va_gnt;
  logic [NUM_PORTS-1:0][NUM_VC-1:0][VC_W-1:0] va_gnt_out_vc;

  logic [NUM_PORTS-1:0][NUM_VC-1:0]      sa_req;
  logic [NUM_PORTS-1:0][NUM_VC-1:0][3:0] sa_req_out_port;
  logic [NUM_PORTS-1:0][NUM_VC-1:0][VC_W-1:0] sa_req_out_vc;
  logic [NUM_PORTS-1:0][NUM_VC-1:0]      sa_req_last;
  logic [NUM_PORTS-1:0][NUM_VC-1:0]      sa_gnt;
  logic [NUM_PORTS-1:0][NUM_VC-1:0]      sa_pick;

  logic [NUM_PORTS-1:0][2:0] xbar_sel;
  logic [NUM_PORTS-1:0]      st_valid;
  logic [NUM_PORTS-1:0][VC_W-1:0] st_out_vc;

  logic [NUM_PORTS-1:0][NUM_VC-1:0] ds_credit_valid;

  arbiter #(
      .NUM_PORTS    (NUM_PORTS),
      .NUM_VC       (NUM_VC),
      .LOCAL_IDX    (LOCAL_IDX),
      .DIR_CREDITS  (FIFO_DEPTH),
      .LOCAL_CREDITS(LOCAL_CREDITS)
  ) u_arb (
      .clk              (clk),
      .rst_n            (rst_n),

      .va_req           (va_req),
      .va_req_out_port  (va_req_out_port),
      .va_req_single    (va_req_single),
      .va_gnt           (va_gnt),
      .va_gnt_out_vc    (va_gnt_out_vc),

      .sa_req           (sa_req),
      .sa_req_out_port  (sa_req_out_port),
      .sa_req_out_vc    (sa_req_out_vc),
      .sa_req_last      (sa_req_last),
      .sa_gnt           (sa_gnt),
      .sa_pick          (sa_pick),

      .xbar_sel         (xbar_sel),
      .st_valid         (st_valid),
      .st_out_vc        (st_out_vc),

      .ds_credit_valid  (ds_credit_valid)
  );

  function automatic int gnt_port();
    gnt_port = -1;
    for (int p = 0; p < NUM_PORTS; p++)
      if (|sa_gnt[p] && (gnt_port == -1)) gnt_port = p;
  endfunction

  function automatic logic [FLIT_W-1:0] gmask(input int p, input int v);
    return FLIT_W'(1) << (p * NUM_VC + v);
  endfunction

  function automatic logic [2:0] pidx(input logic [3:0] dir);
    case (dir)
      DIR_LOCAL: pidx = 3'd0;
      DIR_NORTH: pidx = 3'd1;
      DIR_EAST:  pidx = 3'd2;
      DIR_WEST:  pidx = 3'd3;
      DIR_SOUTH: pidx = 3'd4;
      default:   pidx = 3'd0;
    endcase
  endfunction

  task automatic idle_inputs();
    va_req           = '0;
    va_req_out_port  = '0;
    va_req_single    = '0;
    sa_req           = '0;
    sa_req_out_port  = '0;
    sa_req_out_vc    = '0;
    sa_req_last      = '0;
    ds_credit_valid  = '0;
  endtask

  task automatic next_cycle();
    @(negedge clk);
  endtask

  task automatic settle();
    #SETTLE;
  endtask

  generate
    for (genvar gp = 0; gp < NUM_PORTS; gp++) begin : gen_gp
      for (genvar gv = 0; gv < NUM_VC; gv++) begin : gen_gv

        assert property (@(posedge clk) disable iff (!rst_n)
                         sa_gnt[gp][gv] |-> sa_req[gp][gv])
          else $error("tb: sa_gnt without sa_req on port %0d vc %0d", gp, gv);

        assert property (@(posedge clk) disable iff (!rst_n)
                         $countones(sa_gnt[gp]) <= 1)
          else $error("tb: more than one grant on input port %0d: %b", gp, sa_gnt[gp]);

      end
    end
  endgenerate

  logic [NUM_PORTS-1:0][NUM_VC-1:0] gnt_to_out [NUM_PORTS];

  always_comb begin
    for (int o = 0; o < NUM_PORTS; o++)
      for (int p = 0; p < NUM_PORTS; p++)
        for (int v = 0; v < NUM_VC; v++)
          gnt_to_out[o][p][v] = sa_gnt[p][v] && (pidx(sa_req_out_port[p][v]) == 3'(o));
  end

  generate
    for (genvar go = 0; go < NUM_PORTS; go++) begin : gen_go

      assert property (@(posedge clk) disable iff (!rst_n)
                       $countones(gnt_to_out[go]) <= 1)
        else $error("tb: more than one grant into output port %0d: %b",
                    go, gnt_to_out[go]);
    end
  endgenerate

  task automatic reset_arb();
    idle_inputs();
    rst_n = 0;
    repeat (2) next_cycle();
    rst_n = 1;
    next_cycle();
    settle();
  endtask

  task automatic dynamic_va_tests();
    logic [NUM_PORTS-1:0][NUM_VC-1:0] accepted;
    int k;
    $display("---- Dynamic VA: matching, classes, priority, release, credits ----");

    va_req[P_NORTH][0] = 1;
    va_req[P_WEST][0] = 1;
    va_req_single[P_WEST][0] = 1;
    va_req[P_EAST][NUM_VC/2] = 1;
    va_req_out_port[P_NORTH][0] = DIR_LOCAL;
    va_req_out_port[P_WEST][0] = DIR_LOCAL;
    va_req_out_port[P_EAST][NUM_VC/2] = DIR_LOCAL;
    settle();
    check("D1 HEAD_TAIL wins first request VC", va_gnt_out_vc[P_WEST][0], 0);
    check("D1 HEAD_TAIL granted", va_gnt[P_WEST][0], 1);
    check("D1 concurrent request and response", $countones(va_gnt), (NUM_VC == 2) ? 2 : 3);
    check("D1 response stays in response class", va_gnt_out_vc[P_EAST][NUM_VC/2], NUM_VC/2);
    if (NUM_VC > 2) begin
      check("D1 second VC0 requester granted", va_gnt[P_NORTH][0], 1);
      check("D1 second requester dynamically remapped", va_gnt_out_vc[P_NORTH][0], 1);
    end
    accepted = va_gnt;
    next_cycle();
    va_req &= ~accepted;
    settle();
    check("D1 accepted requesters reserve separate rows", $countones(u_arb.alloc_busy), (NUM_VC == 2) ? 2 : 3);
    check("D1 unaccepted request waits on full class", va_gnt, '0);

    reset_arb();

    for (int p = P_NORTH; p <= P_SOUTH; p++)
      for (int v = 0; v < NUM_VC/2; v++) begin
        va_req[p][v] = 1;
        va_req_out_port[p][v] = DIR_LOCAL;
        va_req_single[p][v] = 1;
      end
    va_req_single[P_NORTH][0] = 0;
    settle();
    check("D2 maximal matching under oversubscription", $countones(va_gnt), NUM_VC/2);
    check("D2 HEAD waits behind available HEAD_TAILs", va_gnt[P_NORTH][0], 0);
    accepted = va_gnt;
    next_cycle();
    va_req &= ~accepted;
    settle();
    check("D2 reserved class cannot be reallocated", va_gnt, '0);
    check("D2 response resources untouched", u_arb.alloc_busy[P_LOCAL] >> (NUM_VC/2), 0);

    reset_arb();

    for (int v = 0; v < NUM_VC/2-1; v++) begin
      va_req[P_EAST][v] = 1;
      va_req_out_port[P_EAST][v] = DIR_LOCAL;
      settle();
      check("D3 one requester cannot win several rows", $countones(va_gnt), 1);
      next_cycle();
      va_req = '0;
    end
    k = NUM_VC/2-1;
    va_req[P_NORTH][0] = 1;
    va_req[P_WEST][0] = 1;
    va_req_out_port[P_NORTH][0] = DIR_LOCAL;
    va_req_out_port[P_WEST][0] = DIR_LOCAL;
    va_req_single[P_WEST][0] = 1;
    settle();
    check("D3 exactly one available VC gives one grant", va_gnt, gmask(P_WEST, 0));
    check("D3 assigned the only free row", va_gnt_out_vc[P_WEST][0], k);
    next_cycle();
    va_req = '0;

    sa_req[P_WEST][0] = 1;
    sa_req_out_port[P_WEST][0] = DIR_LOCAL;
    sa_req_out_vc[P_WEST][0] = VC_W'(k);
    repeat (2) begin
      next_cycle();
      check("D3 nonfinal transfer retains reservation", u_arb.alloc_busy[P_LOCAL][k], 1);
    end

    sa_req_last[P_WEST][0] = 1;
    sa_req[P_NORTH][0] = 1;
    sa_req_out_port[P_NORTH][0] = DIR_LOCAL;
    sa_req_out_vc[P_NORTH][0] = VC_W'(0);
    settle();
    check("D3 tail selected at stage 1", sa_pick[P_WEST][0], 1);
    check("D3 tail denied stage 2", sa_gnt[P_WEST][0], 0);
    next_cycle();
    check("D3 denied tail retains reservation", u_arb.alloc_busy[P_LOCAL][k], 1);
    sa_req[P_NORTH][0] = 0;
    va_req[P_SOUTH][0] = 1;
    va_req_out_port[P_SOUTH][0] = DIR_LOCAL;
    settle();
    check("D3 tail actually traverses", sa_gnt[P_WEST][0], 1);
    check("D3 releasing row unavailable to same-cycle VA", va_gnt, '0);
    next_cycle();
    sa_req = '0;
    settle();
    check("D3 release registered", u_arb.alloc_busy[P_LOCAL][k], 0);
    check("D3 newly free row allocated next cycle", va_gnt[P_SOUTH][0], 1);
    check("D3 reallocation uses freed row", va_gnt_out_vc[P_SOUTH][0], k);
    next_cycle();
    va_req = '0;

    sa_req[P_SOUTH][0] = 1;
    sa_req_out_port[P_SOUTH][0] = DIR_LOCAL;
    sa_req_out_vc[P_SOUTH][0] = VC_W'(k);
    sa_req_last[P_SOUTH][0] = 0;
    while (u_arb.credit_count[P_LOCAL][k] != 0) next_cycle();
    settle();
    check("D4 zero-credit reservation persists", u_arb.alloc_busy[P_LOCAL][k], 1);
    check("D4 zero credit blocks SA", sa_gnt, '0);
    sa_req_last[P_SOUTH][0] = 1;
    next_cycle();
    check("D4 stalled tail does not release", u_arb.alloc_busy[P_LOCAL][k], 1);
    ds_credit_valid[P_LOCAL][k] = 1;
    next_cycle();
    settle();
    check("D4 returned credit unblocks mapped VC", sa_gnt[P_SOUTH][0], 1);
    check("D4 output sideband uses allocation", st_out_vc[P_LOCAL], k);

    next_cycle();
    idle_inputs();
    settle();
    check("D4 simultaneous increment/decrement nets zero", u_arb.credit_count[P_LOCAL][k], 1);
    check("D4 final transfer releases mapped row", u_arb.alloc_busy[P_LOCAL][k], 0);

    reset_arb();

    sa_req[P_LOCAL][0] = 1;
    sa_req_out_port[P_LOCAL][0] = DIR_EAST;
    sa_req_out_vc[P_LOCAL][0] = 0;
    repeat (FIFO_DEPTH) next_cycle();
    sa_req = '0;
    va_req[P_WEST][0] = 1;
    va_req_out_port[P_WEST][0] = DIR_EAST;
    va_req_single[P_WEST][0] = 1;
    settle();
    check("D5 zero credit does not gate VA", va_gnt[P_WEST][0], 1);
    check("D5 zero-credit VC selected", va_gnt_out_vc[P_WEST][0], 0);
    next_cycle();
    va_req = '0;
    sa_req[P_WEST][0] = 1;
    sa_req_out_port[P_WEST][0] = DIR_EAST;
    sa_req_out_vc[P_WEST][0] = 0;
    sa_req_last[P_WEST][0] = 1;
    settle();
    check("D5 allocated HEAD_TAIL stalls without credit", sa_gnt, '0);
    ds_credit_valid[P_EAST][0] = 1;
    next_cycle();
    ds_credit_valid = '0;
    settle();
    check("D5 HEAD_TAIL transmits after return", sa_gnt[P_WEST][0], 1);
    next_cycle();
    idle_inputs();
    settle();
    check("D5 HEAD_TAIL releases immediately on traversal", u_arb.alloc_busy[P_EAST][0], 0);

    reset_arb();
    for (int k2 = 0; k2 < NUM_VC/2; k2++) begin
      va_req[P_NORTH][k2] = 1;
      va_req_out_port[P_NORTH][k2] = DIR_LOCAL;
    end
    next_cycle();
    va_req = '0;
    sa_req[P_NORTH][0] = 1;
    sa_req_out_port[P_NORTH][0] = DIR_LOCAL;
    sa_req_out_vc[P_NORTH][0] = 0;
    sa_req_last[P_NORTH][0] = 1;
    next_cycle();
    sa_req = '0;
    va_req[P_NORTH][0] = 1;
    va_req[P_EAST][0] = 1;
    va_req_out_port[P_NORTH][0] = DIR_LOCAL;
    va_req_out_port[P_EAST][0] = DIR_LOCAL;
    settle();
    check("D6 round robin advances past previous owner", va_gnt, gmask(P_EAST, 0));
    next_cycle();
    idle_inputs();
  endtask

  initial begin : main

    idle_inputs();
    rst_n = 0;

    repeat (3) @(negedge clk);
    rst_n = 1;
    @(negedge clk);
    settle();

    $display("---- R0  reset state ----");

    check("R0 credit_count[EAST][0]  = FIFO_DEPTH", u_arb.credit_count[P_EAST][0],
          FIFO_DEPTH);
    check("R0 credit_count[LOCAL][0] = LOCAL_CREDITS", u_arb.credit_count[P_LOCAL][0],
          LOCAL_CREDITS);
    check("R0 credit_count[SOUTH][1] = FIFO_DEPTH", u_arb.credit_count[P_SOUTH][1],
          FIFO_DEPTH);
    check("R0 alloc_busy[LOCAL][0] clear", u_arb.alloc_busy[P_LOCAL][0], 1'b0);
    check("R0 no VA grants", va_gnt, '0);
    check("R0 no SA grants", sa_gnt, '0);
    check("R0 no switch valid", st_valid, '0);

    dynamic_va_tests();
    reset_arb();

    $display("---- T4  two VCs on one input port, different outputs ----");

    sa_req[P_LOCAL][0] = 1'b1;
    sa_req_out_port[P_LOCAL][0] = DIR_EAST;
    sa_req_out_vc[P_LOCAL][0]   = VC_W'(0);
    sa_req_last[P_LOCAL][0]     = 1'b0;

    sa_req[P_LOCAL][1] = 1'b1;
    sa_req_out_port[P_LOCAL][1] = DIR_WEST;
    sa_req_out_vc[P_LOCAL][1]   = VC_W'(0);
    sa_req_last[P_LOCAL][1]     = 1'b0;
    settle();

    check("T4 c1 stage-1 pick is VC0", sa_pick[P_LOCAL], 2'b01);
    check("T4 c1 grant is VC0 (one grant, one input)", sa_gnt[P_LOCAL], 2'b01);
    check("T4 c1 only the picked VC's output switches", st_valid, 5'b00100);
    check("T4 c1 crossbar selects the presenting port", xbar_sel[P_EAST], 0);
    check("T4 c1 downstream VC sideband", st_out_vc[P_EAST], 2'd0);
    next_cycle();
    settle();

    check("T4 c2 stage-1 pick rotated to VC1", sa_pick[P_LOCAL], 2'b10);
    check("T4 c2 grant is VC1", sa_gnt[P_LOCAL], 2'b10);
    check("T4 c2 only WEST switches", st_valid, 5'b01000);
    check("T4 c2 crossbar selects the presenting port", xbar_sel[P_WEST], 0);
    check("T4 c2 downstream VC sideband", st_out_vc[P_WEST], 2'd0);
    next_cycle();
    settle();

    sa_req_out_port[P_LOCAL][1] = DIR_EAST;
    settle();
    check("T4 c3 both VCs want EAST -> still one pick", sa_pick[P_LOCAL], 2'b01);
    check("T4 c3 exactly one grant", $countones(sa_gnt), 1);
    check("T4 c3 that grant is VC0", sa_gnt[P_LOCAL], 2'b01);
    next_cycle();
    settle();

    sa_req = '0;
    sa_req_out_port = '0;
    sa_req_out_vc = '0;
    sa_req_last = '0;
    next_cycle();
    settle();

    $display("---- T5  two inputs competing for LOCAL, stage-2 fairness ----");

    sa_req[P_NORTH][0] = 1'b1;
    sa_req_out_port[P_NORTH][0] = DIR_LOCAL;
    sa_req_out_vc[P_NORTH][0]   = VC_W'(0);
    sa_req[P_NORTH][1] = 1'b1;
    sa_req_out_port[P_NORTH][1] = DIR_LOCAL;
    sa_req_out_vc[P_NORTH][1]   = VC_W'(1);

    sa_req[P_EAST][0] = 1'b1;
    sa_req_out_port[P_EAST][0] = DIR_LOCAL;
    sa_req_out_vc[P_EAST][0]   = VC_W'(0);
    sa_req[P_EAST][1] = 1'b1;
    sa_req_out_port[P_EAST][1] = DIR_LOCAL;
    sa_req_out_vc[P_EAST][1]   = VC_W'(1);
    settle();

    begin : t5_seq
      int expect_port [4];
      logic [1:0] expect_mask [4];
      logic [VC_W-1:0] expect_svc  [4];
      int got_port;

      expect_port[0] = P_NORTH; expect_mask[0] = 2'b01; expect_svc[0] = VC_W'(0);
      expect_port[1] = P_EAST;  expect_mask[1] = 2'b01; expect_svc[1] = VC_W'(0);
      expect_port[2] = P_NORTH; expect_mask[2] = 2'b10; expect_svc[2] = VC_W'(1);
      expect_port[3] = P_EAST;  expect_mask[3] = 2'b10; expect_svc[3] = VC_W'(1);

      for (int c = 0; c < 4; c++) begin
        if (c > 0) begin
          next_cycle();
          settle();
        end

        got_port = gnt_port();
        check($sformatf("T5 c%0d exactly one grant into LOCAL", c + 1),
              $countones(gnt_to_out[P_LOCAL]), 1);
        check($sformatf("T5 c%0d granted port", c + 1), got_port, expect_port[c]);
        check($sformatf("T5 c%0d granted VC", c + 1), sa_gnt[expect_port[c]], expect_mask[c]);
        check($sformatf("T5 c%0d LOCAL is the only switching output", c + 1),
              st_valid, 5'b00001);
        check($sformatf("T5 c%0d crossbar points at the granted port", c + 1),
              xbar_sel[P_LOCAL], expect_port[c]);

        check($sformatf("T5 c%0d downstream VC sideband", c + 1),
              st_out_vc[P_LOCAL], expect_svc[c]);
      end
    end

    next_cycle();
    settle();
    sa_req = '0;
    sa_req_out_port = '0;
    sa_req_out_vc = '0;
    next_cycle();
    settle();

    $display("---- T7  credit exhaustion, recovery, same-cycle +1/-1 ----");

    check("T7 SOUTH starts full", u_arb.credit_count[P_SOUTH][0], FIFO_DEPTH);

    sa_req[P_NORTH][0] = 1'b1;
    sa_req_out_port[P_NORTH][0] = DIR_SOUTH;
    sa_req_out_vc[P_NORTH][0]   = VC_W'(0);
    sa_req_last[P_NORTH][0]     = 1'b0;
    settle();

    for (int c = 0; c < FIFO_DEPTH; c++) begin
      if (c > 0) next_cycle();
      check($sformatf("T7 drain c%0d credits before this grant", c + 1),
            u_arb.credit_count[P_SOUTH][0], FIFO_DEPTH - c);
      settle();
      check($sformatf("T7 drain c%0d grant with credit left", c + 1),
            $countones(sa_gnt), 1);
    end

    next_cycle();
    check("T7 exhausted: credit is 0", u_arb.credit_count[P_SOUTH][0], 0);
    settle();

    check("T7 exhausted: no grant", sa_gnt, '0);
    check("T7 exhausted: nothing switches", st_valid, '0);
    check("T7 exhausted: sideband cleared too", st_out_vc[P_SOUTH], '0);

    next_cycle();
    ds_credit_valid[P_SOUTH][0] = 1'b1;
    settle();
    check("T7 credit still 0 during the return cycle", u_arb.credit_count[P_SOUTH][0], 0);
    check("T7 a return alone does not grant", sa_gnt, '0);

    next_cycle();
    check("T7 credit recovered to 1", u_arb.credit_count[P_SOUTH][0], 1);
    settle();
    check("T7 same-cycle grant happens", $countones(sa_gnt), 1);
    next_cycle();
    check("T7 same-cycle +1/-1 nets to 0 (still 1)", u_arb.credit_count[P_SOUTH][0], 1);

    ds_credit_valid[P_SOUTH][0] = 1'b0;
    settle();
    check("T7 one more grant from the surviving credit", $countones(sa_gnt), 1);
    next_cycle();
    check("T7 counter back to 0", u_arb.credit_count[P_SOUTH][0], 0);
    settle();
    check("T7 then correctly refuses", sa_gnt, '0);

    $display("----------------------------------------");
    if (errors == 0) $display("ALL %0d CHECKS PASSED", checks);
    else $display("%0d / %0d CHECKS FAILED", errors, checks);
    $display("----------------------------------------");

    $finish;
  end

  initial begin
    #50000;
    $display("ERROR: tb_arbiter timed out");
    $finish;
  end

  initial begin
    $dumpfile("sim/arbiter.vcd");
    $dumpvars(0, tb_arbiter);
  end

endmodule
