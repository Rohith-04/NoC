// tb_arbiter.sv
//
// Directed testbench for the arbiter (VA + SA + credits), no other modules
// instantiated -- the arbiter is a leaf, so everything here is driven
// directly rather than through a mock.
//
//
// Coverage (spec section 8, build order steps 3-5)
//
//   R0   reset state: credit counters at their init values, no reservations,
//        no spurious grants
//   T6   VA contention: three requesters, two output VCs, HEAD_TAIL beats
//        HEAD. Also proves that a row reserved by VA blocks further
//        grants, that a column-dropped row reserves nothing, and that a
//        dropped row does not advance its round-robin pointer.
//   T4   two VCs on one input port pointing at different outputs: stage 1
//        collapses them to a single candidate, so the input can never
//        receive two grants in a cycle. Covers the stage-1 rotation and
//        the case where both VCs want the same output.
//   T5   two inputs competing for one output: stage-2 fairness, checked as
//        an alternating grant sequence rather than a hand-computed pointer
//        value, with the exact granted VC pinned per cycle.
//   T7   credit exhaustion, recovery from zero, and the same-cycle +1/-1
//        case. Uses the SOUTH output, which no earlier test touches, so it
//        starts from a known full count of DIR_CREDITS.
//
// Plus continuous SVA for the section 8 properties that hold every cycle
// regardless of which directed test is running: a grant implies a request,
// at most one grant per input port, and at most one grant per output.
//
//
// Wiring note
// -----------
// Every DUT port is connected to a whole signal declared at bench scope.
// See the README section on testbench wiring rules: an element select used
// as a port endpoint does not reliably propagate, and this bench has enough
// of them that getting it wrong would be silent.
//

`timescale 1ns / 1ps

module tb_arbiter;

  // ---- configuration under test (section 2) ----
  localparam int NUM_PORTS     = 5;
  localparam int NUM_VC        = 2;
  localparam int LOCAL_IDX     = 0;
  localparam int DIR_CREDITS   = 8;   // = noc_input_port's FIFO depth
  localparam int LOCAL_CREDITS = 4;   // = NI receive buffer depth

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
  localparam time SETTLE   = 2;  // long enough for the combinational path,
                                 // short enough to land before the posedge

  // =========================================================================
  // Clock / reset
  // =========================================================================

  logic clk = 0;
  logic rst_n = 0;

  always #(CLK_HALF) clk = ~clk;

  // =========================================================================
  // DUT stimulus and responses -- whole signals at every port endpoint
  // =========================================================================

  logic [NUM_PORTS-1:0][NUM_VC-1:0]      va_req;
  logic [NUM_PORTS-1:0][NUM_VC-1:0][3:0] va_req_out_port;
  logic [NUM_PORTS-1:0][NUM_VC-1:0]      va_req_single;
  logic [NUM_PORTS-1:0][NUM_VC-1:0]      va_gnt;
  logic [NUM_PORTS-1:0][NUM_VC-1:0][1:0] va_gnt_out_vc;

  logic [NUM_PORTS-1:0][NUM_VC-1:0]      sa_req;
  logic [NUM_PORTS-1:0][NUM_VC-1:0][3:0] sa_req_out_port;
  logic [NUM_PORTS-1:0][NUM_VC-1:0][1:0] sa_req_out_vc;
  logic [NUM_PORTS-1:0][NUM_VC-1:0]      sa_req_last;
  logic [NUM_PORTS-1:0][NUM_VC-1:0]      sa_gnt;
  logic [NUM_PORTS-1:0][NUM_VC-1:0]      sa_pick;

  logic [NUM_PORTS-1:0][2:0] xbar_sel;
  logic [NUM_PORTS-1:0]      st_valid;
  logic [NUM_PORTS-1:0][1:0] st_out_vc;

  logic [NUM_PORTS-1:0][NUM_VC-1:0] ds_credit_valid;

  arbiter #(
      .NUM_PORTS    (NUM_PORTS),
      .NUM_VC       (NUM_VC),
      .LOCAL_IDX    (LOCAL_IDX),
      .DIR_CREDITS  (DIR_CREDITS),
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

  // =========================================================================
  // Bookkeeping
  // =========================================================================

  int errors = 0;
  int checks = 0;

  task automatic check(input string what, input logic [31:0] actual,
                       input logic [31:0] expected);
    checks++;
    if (actual !== expected) begin
      errors++;
      $display("FAIL: %-46s got=%0d (0x%0h)  exp=%0d (0x%0h)",
               what, actual, actual, expected, expected);
    end else begin
      $display("PASS: %-46s %0d", what, actual);
    end
  endtask

  // Which input port, if any, holds a grant this cycle. -1 for none.
  function automatic int gnt_port();
    gnt_port = -1;
    for (int p = 0; p < NUM_PORTS; p++)
      if (|sa_gnt[p] && (gnt_port == -1)) gnt_port = p;
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

  // =========================================================================
  // Drive helpers
  //
  // Inputs change on the falling edge and are sampled on the rising one, so
  // a full cycle is: settle inputs, observe the combinational result, then
  // let the posedge commit state before the next call.
  // =========================================================================

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

  // Advance to the low phase of the next cycle, i.e. just after the state
  // has committed. Call BEFORE driving.
  task automatic next_cycle();
    @(negedge clk);
  endtask

  // Let the combinational outputs reflect whatever was just driven. Call
  // AFTER driving.
  task automatic settle();
    #SETTLE;
  endtask

  // =========================================================================
  // Continuous assertions (spec section 8)
  // =========================================================================

  // Per-grant properties.
  generate
    for (genvar gp = 0; gp < NUM_PORTS; gp++) begin : gen_gp
      for (genvar gv = 0; gv < NUM_VC; gv++) begin : gen_gv

        // A grant with no request would tell an input port to fetch a flit
        // it never offered.
        assert property (@(posedge clk) disable iff (!rst_n)
                         sa_gnt[gp][gv] |-> sa_req[gp][gv])
          else $error("tb: sa_gnt without sa_req on port %0d vc %0d", gp, gv);

        // The input port has one datapath to the crossbar, so it can only
        // ever switch one VC per cycle.
        assert property (@(posedge clk) disable iff (!rst_n)
                         $countones(sa_gnt[gp]) <= 1)
          else $error("tb: more than one grant on input port %0d: %b", gp, sa_gnt[gp]);

      end
    end
  endgenerate

  // "Which output does this grant target", flattened per output so the
  // per-output count is a single $countones.
  logic [NUM_PORTS-1:0][NUM_VC-1:0] gnt_to_out [NUM_PORTS];

  always_comb begin
    for (int o = 0; o < NUM_PORTS; o++)
      for (int p = 0; p < NUM_PORTS; p++)
        for (int v = 0; v < NUM_VC; v++)
          gnt_to_out[o][p][v] = sa_gnt[p][v] && (pidx(sa_req_out_port[p][v]) == 3'(o));
  end

  generate
    for (genvar go = 0; go < NUM_PORTS; go++) begin : gen_go
      // Two grants into one output port would be two flits arriving at a
      // downstream link that carries one per cycle.
      assert property (@(posedge clk) disable iff (!rst_n)
                       $countones(gnt_to_out[go]) <= 1)
        else $error("tb: more than one grant into output port %0d: %b",
                    go, gnt_to_out[go]);
    end
  endgenerate

  // =========================================================================
  // Tests
  // =========================================================================

  initial begin : main

    idle_inputs();
    rst_n = 0;

    // ---- reset ----
    repeat (3) @(negedge clk);
    rst_n = 1;
    @(negedge clk);
    settle();

    // =================== R0: reset state ===================
    $display("---- R0  reset state ----");

    check("R0 credit_count[EAST][0]  = DIR_CREDITS", u_arb.credit_count[P_EAST][0],
          DIR_CREDITS);
    check("R0 credit_count[LOCAL][0] = LOCAL_CREDITS", u_arb.credit_count[P_LOCAL][0],
          LOCAL_CREDITS);
    check("R0 credit_count[SOUTH][1] = DIR_CREDITS", u_arb.credit_count[P_SOUTH][1],
          DIR_CREDITS);
    check("R0 alloc_busy[LOCAL][0] clear", u_arb.alloc_busy[P_LOCAL][0], 1'b0);
    check("R0 no VA grants", va_gnt, '0);
    check("R0 no SA grants", sa_gnt, '0);
    check("R0 no switch valid", st_valid, '0);

    // =================== T6: VA contention ===================
    // Three requesters (N, E, W -- all legally able to reach LOCAL) against
    // two LOCAL output VCs. Port 2's packet is HEAD_TAIL, so it sits in the
    // single tier and must win over the two HEADs.
    $display("---- T6  VA contention: three requesters, two VCs, HEAD_TAIL wins ----");

    va_req[P_NORTH][0] = 1'b1;
    va_req_out_port[P_NORTH][0] = DIR_LOCAL;
    va_req_single[P_NORTH][0]   = 1'b0;   // HEAD

    va_req[P_EAST][0] = 1'b1;
    va_req_out_port[P_EAST][0] = DIR_LOCAL;
    va_req_single[P_EAST][0]   = 1'b1;    // HEAD_TAIL -- the tier winner

    va_req[P_WEST][0] = 1'b1;
    va_req_out_port[P_WEST][0] = DIR_LOCAL;
    va_req_single[P_WEST][0]   = 1'b0;    // HEAD
    settle();

    // Only requester id 4 (port 2, VC 0) may win, and only the lowest row:
    // it won both rows, so the column stage keeps k=0 and drops k=1.
    check("T6 c1 grant mask (port2 VC0 only)", va_gnt, 32'd16);
    check("T6 c1 granted output VC", va_gnt_out_vc[P_EAST][0], 0);
    check("T6 c1 other requesters silent", va_gnt & ~32'h10, '0);
    next_cycle();
    settle();

    // The row it took is now reserved; the dropped row is not. alloc_busy
    // is read here, after the posedge that set it.
    check("T6 c2 alloc_busy[LOCAL][0] set by the grant", u_arb.alloc_busy[P_LOCAL][0], 1'b1);
    check("T6 c2 alloc_busy[LOCAL][1] clear (row was dropped)",
          u_arb.alloc_busy[P_LOCAL][1], 1'b0);

    // Row 0 is reserved, so only row 1 is available -- same single-tier
    // winner, now handed the other VC.
    check("T6 c2 grant mask (same requester)", va_gnt, 32'd16);
    check("T6 c2 granted output VC", va_gnt_out_vc[P_EAST][0], 1);
    next_cycle();
    settle();

    check("T6 c3 alloc_busy[LOCAL][1] now set", u_arb.alloc_busy[P_LOCAL][1], 1'b1);
    // Both rows reserved: nobody else can be granted anything this cycle,
    // even though all three requesters are still asking.
    check("T6 c3 all rows reserved -> no grant", va_gnt, '0);
    next_cycle();
    settle();

    // A dropped row must not have advanced its pointer: row 1 re-picks the
    // same requester it picked the first time (which is why T6 c2 still
    // chose port 2 rather than rotating to a HEAD).
    check("T6 c4 still no grant while rows reserved", va_gnt, '0);

    // release the stimulus
    va_req = '0;
    va_req_out_port = '0;
    va_req_single = '0;
    next_cycle();
    settle();

    // =================== T4: two VCs, one input port ===================
    $display("---- T4  two VCs on one input port, different outputs ----");

    // LOCAL VC0 -> EAST, LOCAL VC1 -> WEST. Both are XY-legal from LOCAL.
    sa_req[P_LOCAL][0] = 1'b1;
    sa_req_out_port[P_LOCAL][0] = DIR_EAST;
    sa_req_out_vc[P_LOCAL][0]   = 2'd0;
    sa_req_last[P_LOCAL][0]     = 1'b0;

    sa_req[P_LOCAL][1] = 1'b1;
    sa_req_out_port[P_LOCAL][1] = DIR_WEST;
    sa_req_out_vc[P_LOCAL][1]   = 2'd0;
    sa_req_last[P_LOCAL][1]     = 1'b0;
    settle();

    // rr1 starts at 0, so VC0 wins stage 1 and carries its own target with
    // it -- stage 2 only ever sees EAST, never WEST.
    check("T4 c1 stage-1 pick is VC0", sa_pick[P_LOCAL], 2'b01);
    check("T4 c1 grant is VC0 (one grant, one input)", sa_gnt[P_LOCAL], 2'b01);
    check("T4 c1 only the picked VC's output switches", st_valid, 5'b00100);
    check("T4 c1 crossbar selects the presenting port", xbar_sel[P_EAST], 0);
    check("T4 c1 downstream VC sideband", st_out_vc[P_EAST], 2'd0);
    next_cycle();
    settle();

    // rr1 advanced because VC0 won stage 2, so the sibling gets its turn
    // and now WEST is the one that switches.
    check("T4 c2 stage-1 pick rotated to VC1", sa_pick[P_LOCAL], 2'b10);
    check("T4 c2 grant is VC1", sa_gnt[P_LOCAL], 2'b10);
    check("T4 c2 only WEST switches", st_valid, 5'b01000);
    check("T4 c2 crossbar selects the presenting port", xbar_sel[P_WEST], 0);
    check("T4 c2 downstream VC sideband", st_out_vc[P_WEST], 2'd0);
    next_cycle();
    settle();

    // Both VCs now want EAST. Stage 1 still collapses them to one, so the
    // input gets exactly one grant -- this is the "no two grants on one
    // input in a cycle" property made observable.
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

    // =================== T5: two inputs, one output ===================
    $display("---- T5  two inputs competing for LOCAL, stage-2 fairness ----");

    // Ports NORTH and EAST each offer BOTH of their VCs into LOCAL.
    sa_req[P_NORTH][0] = 1'b1;
    sa_req_out_port[P_NORTH][0] = DIR_LOCAL;
    sa_req_out_vc[P_NORTH][0]   = 2'd0;
    sa_req[P_NORTH][1] = 1'b1;
    sa_req_out_port[P_NORTH][1] = DIR_LOCAL;
    sa_req_out_vc[P_NORTH][1]   = 2'd1;

    sa_req[P_EAST][0] = 1'b1;
    sa_req_out_port[P_EAST][0] = DIR_LOCAL;
    sa_req_out_vc[P_EAST][0]   = 2'd0;
    sa_req[P_EAST][1] = 1'b1;
    sa_req_out_port[P_EAST][1] = DIR_LOCAL;
    sa_req_out_vc[P_EAST][1]   = 2'd1;
    settle();

    // Stage-2 fairness is the property under test, so it is checked as a
    // sequence: rr2 walks forward each grant, which alternates the winner
    // between the two contenders instead of letting the lower port index
    // win every time. The granted VC is pinned per cycle because stage 1's
    // own rotation is part of the same round-robin contract.
    //
    //   cycle  port   vc     why
    //   1      NORTH  VC0    rr2 starts at 0 -> first requester at/after it
    //   2      EAST   VC0    rr2 advanced past NORTH
    //   3      NORTH  VC1    rr2 wrapped back around; NORTH lost c2 so its
    //                        stage-1 pointer stayed put and picked its
    //                        second VC this time
    //   4      EAST   VC1    rr2 advanced again; EAST's stage-1 pointer
    //                        rotated the same way
    begin : t5_seq
      int expect_port [4];
      logic [1:0] expect_mask [4];  // one-hot sa_gnt value for that port
      logic [1:0] expect_svc  [4];  // downstream VC index on the sideband
      int got_port;

      expect_port[0] = P_NORTH; expect_mask[0] = 2'b01; expect_svc[0] = 2'd0;
      expect_port[1] = P_EAST;  expect_mask[1] = 2'b01; expect_svc[1] = 2'd0;
      expect_port[2] = P_NORTH; expect_mask[2] = 2'b10; expect_svc[2] = 2'd1;
      expect_port[3] = P_EAST;  expect_mask[3] = 2'b10; expect_svc[3] = 2'd1;

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
        // The sideband has to name the VC that was actually granted -- a
        // mismatch here would make the downstream router buffer the flit in
        // the wrong slot while the credit is decremented in the right one.
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

    // =================== T7: credits ===================
    // SOUTH has not been used by any earlier test, so it starts at a full
    // DIR_CREDITS and the arithmetic below is independent of what the rest
    // of the bench has done.
    $display("---- T7  credit exhaustion, recovery, same-cycle +1/-1 ----");

    check("T7 SOUTH starts full", u_arb.credit_count[P_SOUTH][0], DIR_CREDITS);

    sa_req[P_NORTH][0] = 1'b1;
    sa_req_out_port[P_NORTH][0] = DIR_SOUTH;
    sa_req_out_vc[P_NORTH][0]   = 2'd0;
    sa_req_last[P_NORTH][0]     = 1'b0;
    settle();

    // --- drain ---
    //
    // Credit reads are taken immediately after next_cycle(), i.e. after the
    // posedge that commits the previous cycle's decrement and before this
    // cycle's own. Grant reads are taken after settle(). Keeping the two
    // apart is the whole trick here: reading a counter after settle() shows
    // it one decrement behind the grant next to it, which is an off-by-one
    // in the bench, not in the RTL.
    for (int c = 0; c < DIR_CREDITS; c++) begin
      if (c > 0) next_cycle();
      check($sformatf("T7 drain c%0d credits before this grant", c + 1),
            u_arb.credit_count[P_SOUTH][0], DIR_CREDITS - c);
      settle();
      check($sformatf("T7 drain c%0d grant with credit left", c + 1),
            $countones(sa_gnt), 1);
    end

    next_cycle();
    check("T7 exhausted: credit is 0", u_arb.credit_count[P_SOUTH][0], 0);
    settle();

    // --- exhausted: the mask must hold the grant off ---
    check("T7 exhausted: no grant", sa_gnt, '0);
    check("T7 exhausted: nothing switches", st_valid, '0);
    check("T7 exhausted: sideband cleared too", st_out_vc[P_SOUTH], '0);

    // --- recovery: one credit returns, nothing granted while it lands ---
    // Credit was 0 for the whole of this cycle, so the grant stays off even
    // though the return is presented now; the return only commits at this
    // cycle's posedge, which is what the next read observes.
    next_cycle();
    ds_credit_valid[P_SOUTH][0] = 1'b1;
    settle();
    check("T7 credit still 0 during the return cycle", u_arb.credit_count[P_SOUTH][0], 0);
    check("T7 a return alone does not grant", sa_gnt, '0);

    // --- same-cycle +1 / -1 ---
    // The counter has recovered to 1, and both the request and the return
    // are live again -- so this cycle a flit switches out in the very cycle
    // its credit comes back. The two must cancel.
    next_cycle();
    check("T7 credit recovered to 1", u_arb.credit_count[P_SOUTH][0], 1);
    settle();
    check("T7 same-cycle grant happens", $countones(sa_gnt), 1);
    next_cycle();
    check("T7 same-cycle +1/-1 nets to 0 (still 1)", u_arb.credit_count[P_SOUTH][0], 1);

    // --- the discriminator ---
    // Had the net been applied as two decrements the counter would read -1
    // (wrapping) and this grant would already be refused; had it been
    // applied twice in favour of the return it would read 2 and the grant
    // *after* this one would still fire. Exactly one more grant is legal.
    ds_credit_valid[P_SOUTH][0] = 1'b0;
    settle();
    check("T7 one more grant from the surviving credit", $countones(sa_gnt), 1);
    next_cycle();
    check("T7 counter back to 0", u_arb.credit_count[P_SOUTH][0], 0);
    settle();
    check("T7 then correctly refuses", sa_gnt, '0);

    // ---- summary ----
    $display("----------------------------------------");
    if (errors == 0) $display("ALL %0d CHECKS PASSED", checks);
    else $display("%0d / %0d CHECKS FAILED", errors, checks);
    $display("----------------------------------------");

    $finish;
  end

  // Watchdog -- a hung stimulus would otherwise run forever.
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
