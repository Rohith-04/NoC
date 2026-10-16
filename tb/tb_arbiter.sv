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
//   T6   VA contention: three requesters on VC0, HEAD_TAIL beats HEAD.
//        Also proves that a row reserved by VA blocks further grants, that
//        a VC0 requester cannot reach a free row on any other VC (the
//        VC-matched rule of linnea_v2 section 4.4), and that each row is
//        drained only by a requester on that row's own VC index.
//   T4   two VCs on one input port pointing at different outputs: stage 1
//        collapses them to a single candidate, so the input can never
//        receive two grants in a cycle. Covers the stage-1 rotation and
//        the case where both VCs want the same output.
//   T5   two inputs competing for one output: stage-2 fairness, checked as
//        an alternating grant sequence rather than a hand-computed pointer
//        value, with the exact granted VC pinned per cycle.
//   T7   credit exhaustion, recovery from zero, and the same-cycle +1/-1
//        case. Uses the SOUTH output, which no earlier test touches, so it
//        starts from a known full count of FIFO_DEPTH.
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

  // Flit field model and the shared reporter (see noc_tb_pkg.sv).
  import noc_tb_pkg::*;

  // ---- configuration under test (section 2) ----
  // FLIT_W is owned by noc_tb_pkg, not redeclared here -- this bench carries
  // no payload, so it only ever appears as the shared checker's argument
  // width, and one definition of it means the same thing everywhere.
  localparam int NUM_PORTS     = 5;
  parameter  int NUM_VC        = 4;
  // VC index width (linnea_v2 section 1): derived rather than independent,
  // so a sideband can never be narrower than the index it carries.
  localparam int VC_W          = (NUM_VC > 1) ? $clog2(NUM_VC) : 1;
  localparam int LOCAL_IDX     = 0;
  parameter  int FIFO_DEPTH   = 4;   // = noc_input_port FIFO depth
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
  // Bookkeeping -- checks, errors and check() all come from noc_tb_pkg
  // =========================================================================

  // Which input port, if any, holds a grant this cycle. -1 for none.
  function automatic int gnt_port();
    gnt_port = -1;
    for (int p = 0; p < NUM_PORTS; p++)
      if (|sa_gnt[p] && (gnt_port == -1)) gnt_port = p;
  endfunction

  // One-hot expectation for `va_gnt`, for the VA requester (input port p,
  // input VC v). va_gnt is packed as [NUM_PORTS-1:0][NUM_VC-1:0], so the
  // bit position is p*NUM_VC+v -- the same flattening the arbiter uses for
  // its round-robin pointers. Deriving it here rather than writing a literal
  // is what lets these checks hold for any NUM_VC instead of only for the
  // two the test was first written against.
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

    // =================== T6: VA contention ===================
    // Three requesters (N, E, W -- all legally able to reach LOCAL) on VC0.
    // Port EAST's packet is HEAD_TAIL, so it sits in the single tier and
    // must win over the two HEADs.
    //
    // What this test means changed with linnea_v2 section 4.4. A row is not
    // a free slot any requester can be handed: it is indexed by an output VC,
    // and only ports asking at that same VC index are candidates. A VC0
    // requester therefore owns output VC0 and nothing else, which is why the
    // drain below raises a fresh requester per VC instead of letting the
    // VC0 winner walk down the rows the way the old separable allocator let
    // it -- and the reason there is no dropped-row behaviour left to test.
    $display("---- T6  VA contention: three requesters, HEAD_TAIL wins its own LOCAL row ----");

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

    // Only (EAST, VC0) may win, and only row (LOCAL, 0) -- the row its own
    // index names. The tiering itself is unchanged from the separable form.
    check("T6 c1 grant mask (port EAST VC0 only)", va_gnt, gmask(P_EAST, 0));
    check("T6 c1 output VC is the requester's own", u_arb.va_gnt_out_vc[P_EAST][0], 0);
    check("T6 c1 other requesters silent", va_gnt & ~gmask(P_EAST, 0), '0);
    next_cycle();
    settle();

    // The row it took is now reserved; the rest are still free. alloc_busy
    // is read here, after the posedge that set it.
    check("T6 c2 alloc_busy[LOCAL][0] set by the grant", u_arb.alloc_busy[P_LOCAL][0], 1'b1);
    check("T6 c2 alloc_busy[LOCAL][1] free", u_arb.alloc_busy[P_LOCAL][1], 1'b0);

    // The VC-matched half, stated as a negative. Rows 1.. are free and all
    // three are still asking -- but they are asking on VC0, and VC0's row is
    // the one that is taken, so nothing at all may be granted. The old
    // separable allocator handed one of them row 1 here and reserved it;
    // that cross-VC ownership is exactly what section 4.4 forbids.
    check("T6 c3 free rows unreachable from VC0", va_gnt, '0);
    next_cycle();
    settle();

    // Drain the remaining rows one VC at a time. Each row needs its OWN
    // requester, because a row's candidates are the ports asking at that
    // same VC index. The loop bound is NUM_VC, so this holds for two output
    // VCs and for eight.
    for (int k = 1; k < NUM_VC; k++) begin
      va_req[P_EAST][k] = 1'b1;
      va_req_out_port[P_EAST][k] = DIR_LOCAL;
      va_req_single[P_EAST][k]   = 1'b1;
      settle();

      // gmask(P_EAST, k) is a single bit, so an exact match proves neither a
      // neighbouring VC of EAST nor any other port was granted alongside it.
      check($sformatf("T6 row %0d grant mask (its own requester only)", k),
            va_gnt, gmask(P_EAST, k));

      // Expected value passed as the bare int, NOT as VC_W'(k): that cast
      // keeps k's signedness, so a 2-bit k of 10 becomes -2 and sign-extends
      // to the checker's 40-bit argument. k here is small and non-negative,
      // so widening it directly is the width-correct spelling.
      check($sformatf("T6 row %0d output VC == input VC", k),
            u_arb.va_gnt_out_vc[P_EAST][k], k);

      next_cycle();
      settle();
      check($sformatf("T6 row %0d alloc_busy[LOCAL][%0d] set", k, k),
            u_arb.alloc_busy[P_LOCAL][k], 1'b1);
      if (k + 1 < NUM_VC)
        check($sformatf("T6 row %0d next row still free", k),
              u_arb.alloc_busy[P_LOCAL][k + 1], 1'b0);
    end

    // Every row reserved: nobody can be granted anything this cycle, even
    // though every requester raised above is still asking.
    check("T6 c4 all rows reserved -> no grant", va_gnt, '0);
    next_cycle();
    settle();

    check("T6 c5 still no grant while rows reserved", va_gnt, '0);

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
    sa_req_out_vc[P_LOCAL][0]   = VC_W'(0);
    sa_req_last[P_LOCAL][0]     = 1'b0;

    sa_req[P_LOCAL][1] = 1'b1;
    sa_req_out_port[P_LOCAL][1] = DIR_WEST;
    sa_req_out_vc[P_LOCAL][1]   = VC_W'(0);
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
      logic [VC_W-1:0] expect_svc  [4];  // downstream VC index on the sideband
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
    // FIFO_DEPTH and the arithmetic below is independent of what the rest
    // of the bench has done.
    $display("---- T7  credit exhaustion, recovery, same-cycle +1/-1 ----");

    check("T7 SOUTH starts full", u_arb.credit_count[P_SOUTH][0], FIFO_DEPTH);

    sa_req[P_NORTH][0] = 1'b1;
    sa_req_out_port[P_NORTH][0] = DIR_SOUTH;
    sa_req_out_vc[P_NORTH][0]   = VC_W'(0);
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
