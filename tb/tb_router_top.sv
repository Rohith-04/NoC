`timescale 1ns / 1ps

//=============================================================================
// tb_router_top.sv
//
// Router-level verification: tests T1..T9 of section 8, plus the section 8
// assertions that can only be exercised with real traffic flowing through
// the assembled router.
//
//
// The three models this bench provides
// ------------------------------------
// A router by itself is not a test: it has links on both sides and every
// link has an owner. This bench supplies the two missing owners.
//
//  * UPSTREAM (the TX driver). Pushes flits into each incoming link through
//    a per-port queue, and flow-controls itself against the router's own
//    `credit_return_valid[p][k]` -- it may not have more than FIFO_DEPTH
//    flits in a given (port, VC) that the router has not credited back.
//    That is exactly what a real neighbour does, and skipping it would let
//    a bench drive the FIFO past its depth and turn every overflow into a
//    spurious failure instead of a real one.
//
//  * DOWNSTREAM (the credit-return pipe). Observes `out_flit_valid[o]` /
//    `out_vc_id[o]` and returns a credit CRED_LAT cycles later on
//    `ds_credit_valid[o][k]`, which is the loop section 6 describes:
//    grant at g, flit on the wire at g+1, downstream fetch at g+1, credit
//    visible at g+2, usable at g+3. CRED_LAT = 2 reproduces that. The pipe
//    can be switched off, which is how T7 empties the credit pool without
//    having to model a downstream that refuses to drain.
//
//  * RECEIVER (the RX logger). Records every flit that leaves the router
//    with its output port, downstream VC and payload, so tests can assert
//    on counts, order, port assignment and payload identity rather than on
//    individual signal samples.
//
//
// Everything is wired as a whole array or a plain scalar
// -------------------------------------------------------
// The DUT's ports are packed arrays and are connected as whole arrays; the
// queue/log structures live in the bench and are indexed procedurally. No
// element select ever appears in a port connection -- see README
// "Testbench Wiring Rules".
//
//
// Router under test
// -----------------
// CUR_X = 1, CUR_Y = 1, so the mesh coordinates around it are
//
//        (1,0) NORTH
//  (0,1) WEST   LOCAL(1,1)   EAST(2,1)
//        (1,2) SOUTH
//
// A LOCAL-injected flit is routed by compute_dir against those coordinates;
// a flit arriving on a directional port carries its exit direction in the
// header's ROUTE field, which the upstream router wrote as a lookahead.
//=============================================================================

module tb_router_top;

  // The flit model and the shared reporter. Everything this bench knows
  // about field positions comes from here (see the header of noc_tb_pkg.sv).
  import noc_tb_pkg::*;

  //---------------------------------------------------------------
  // 1. Parameters
  //---------------------------------------------------------------
  // FLIT_W is NOT redeclared here. noc_tb_pkg owns it, and a second
  // declaration in this scope would both hide the package's (VARHIDDEN) and
  // let the two drift apart -- a bench at 32 reading a codec at 40 fails
  // nowhere and everywhere. One definition, and it is in the file that also
  // defines the field map the width is a width *of*.

  localparam int          NUM_PORTS   = 5;
  parameter  int          NUM_VC      = 4;
  // VC index width (linnea_v2 section 1): derived rather than independent,
  // so a sideband can never be narrower than the index it carries.
  localparam int          VC_W        = (NUM_VC > 1) ? $clog2(NUM_VC) : 1;
  localparam int          LOCAL_IDX   = 0;
  localparam int          NORTH_IDX   = 1;
  localparam int          EAST_IDX    = 2;
  localparam int          WEST_IDX    = 3;
  localparam int          SOUTH_IDX   = 4;
  parameter  int          FIFO_DEPTH  = 4;
  localparam int          LOCAL_CRED  = 4;
  localparam realtime     CLK_PERIOD  = 10ns;

  // Downstream credit-return latency in cycles, per section 6.
  localparam int          CRED_LAT    = 2;

  localparam logic [2:0]  CUR_X = 3'd1;
  localparam logic [2:0]  CUR_Y = 3'd1;

  // FLIT_HEAD / FLIT_BODY / FLIT_TAIL / FLIT_HEAD_TAIL come from the package.

  localparam logic [3:0]  DIR_LOCAL = 4'b0000;
  localparam logic [3:0]  DIR_NORTH = 4'b0001;
  localparam logic [3:0]  DIR_EAST  = 4'b0010;
  localparam logic [3:0]  DIR_WEST  = 4'b0100;
  localparam logic [3:0]  DIR_SOUTH = 4'b1000;

  //---------------------------------------------------------------
  // 2. DUT signals -- whole arrays at every endpoint
  //---------------------------------------------------------------
  logic                            clk;
  logic                            rst_n;

  logic [NUM_PORTS-1:0][FLIT_W-1:0]      in_flit_data;
  logic [NUM_PORTS-1:0]            in_flit_valid;
  logic [NUM_PORTS-1:0][VC_W-1:0]       in_vc_id;

  logic [NUM_PORTS-1:0][FLIT_W-1:0]      out_flit_data;
  logic [NUM_PORTS-1:0]            out_flit_valid;
  logic [NUM_PORTS-1:0][VC_W-1:0]       out_vc_id;

  logic [NUM_PORTS-1:0][NUM_VC-1:0] credit_return_valid;
  logic [NUM_PORTS-1:0][NUM_VC-1:0] ds_credit_valid;

  //---------------------------------------------------------------
  // 3. Bookkeeping
  //
  // `checks`, `errors` and the `check`/`check_true` tasks come from
  // noc_tb_pkg -- one reporter for every bench.
  //---------------------------------------------------------------

  //---------------------------------------------------------------
  // 4. Clock
  //---------------------------------------------------------------
  initial clk = 0;
  always #(CLK_PERIOD / 2) clk = ~clk;

  //---------------------------------------------------------------
  // 5. DUT
  //---------------------------------------------------------------
  router_top #(
      .NUM_PORTS   (NUM_PORTS),
      .NUM_VC      (NUM_VC),
      .LOCAL_IDX   (LOCAL_IDX),
      .FIFO_DEPTH  (FIFO_DEPTH),
      .LOCAL_CREDITS(LOCAL_CRED),
      .CUR_X       (CUR_X),
      .CUR_Y       (CUR_Y),
      .HAS_LOCAL   (1'b1),
      .HAS_NORTH   (1'b1),
      .HAS_EAST    (1'b1),
      .HAS_WEST    (1'b1),
      .HAS_SOUTH   (1'b1)
  ) dut (
      .clk                  (clk),
      .rst_n                (rst_n),
      .in_flit_data         (in_flit_data),
      .in_flit_valid        (in_flit_valid),
      .in_vc_id             (in_vc_id),
      .out_flit_data        (out_flit_data),
      .out_flit_valid       (out_flit_valid),
      .out_vc_id            (out_vc_id),
      .credit_return_valid  (credit_return_valid),
      .ds_credit_valid      (ds_credit_valid)
  );

  //---------------------------------------------------------------
  // 6. Check helpers
  //
  // `check` and `check_true` -- and the `checks`/`errors` counters they
  // bump -- live in noc_tb_pkg now, so every bench reports in the same
  // format and a bench cannot quietly grow its own reporter.
  //---------------------------------------------------------------

  //---------------------------------------------------------------
  // 7. Flit constructors
  //
  // mk_head / mk_ht / mk_body / mk_tail come from noc_tb_pkg. They used to
  // be duplicated here and in tb_router_chain, with a comment in the chain
  // bench warning that the two copies "must stay identical ... because the
  // chain tests compare a received body against the one that was sent".
  // There is one copy now, so the warning has nothing to guard against.
  //---------------------------------------------------------------

  //---------------------------------------------------------------
  // 8. Receiver: log everything that leaves the router
  //---------------------------------------------------------------
  typedef struct {
    int          port;
    int          vc;
    logic [FLIT_W-1:0] data;
  } rx_t;

  rx_t rx[$];

  always @(posedge clk) begin : rx_logger
    rx_t e;
    if (rst_n) begin
      for (int o = 0; o < NUM_PORTS; o++) begin
        if (out_flit_valid[o]) begin
          // Built field by field rather than as an assignment pattern:
          // this toolchain does not accept '{...} as an argument.
          e.port = o;
          e.vc   = int'(out_vc_id[o]);
          e.data = out_flit_data[o];
          rx.push_back(e);
        end
      end
    end
  end

  task automatic clear_rx();
    rx.delete();
  endtask

  function automatic int rx_n();
    return rx.size();
  endfunction

  // Payload tag of received flit i -- the reserved upper region heads and
  // HEAD_TAILs carry, which is what every packet in this bench is
  // identified by.
  function automatic logic [TAG_W-1:0] rx_tag(input int i);
    return flit_tag(rx[i].data);
  endfunction

  function automatic logic [1:0] rx_type(input int i);
    return flit_type(rx[i].data);
  endfunction

  // Which port the packet came from. The bench borrows the header's BURST
  // slot -- the top two bits of the 18-bit tag it writes -- because a router
  // only reports the output port it used, so attribution has to ride in the
  // data itself. A router never reads BURST (section 3.2), which is exactly
  // what makes it free to borrow.
  function automatic logic [1:0] rx_origin(input int i);
    return flit_burst(rx[i].data);
  endfunction

  function automatic int rx_port(input int i);
    return rx[i].port;
  endfunction

  // The route field of an arriving header. A single router never consumes
  // its own outgoing route field, so this is how the header merge (the
  // lookup a downstream router will do) is observed from outside.
  function automatic logic [3:0] rx_route(input int i);
    return flit_route(rx[i].data);
  endfunction

  //---------------------------------------------------------------
  // 9. Downstream credit-return pipe (section 6)
  //
  // credit_en lets a test close the loop entirely, which is how T7 drains
  // the downstream credit pool without modelling a downstream that simply
  // refuses to consume.  Closing the loop delays each credit; it never
  // cancels one (see held_credits below).
  //---------------------------------------------------------------
  bit credit_en = 1'b1;

  logic [CRED_LAT:0][NUM_PORTS-1:0][NUM_VC-1:0] cr_pipe;

  // Credits the neighbour owes us but has not been allowed to send back
  // yet.  A credit that arrives while the loop is closed is collected here
  // and paid out one per cycle once it reopens.  Discarding it instead
  // would leave the router's credit pool short for ever: the downstream
  // really has consumed the flit, so the flits still parked in the input
  // FIFO would never be granted again after recovery.
  int held_credits [NUM_PORTS][NUM_VC];

  always @(posedge clk) begin : credit_pipe
    if (!rst_n) begin
      cr_pipe <= '0;
      for (int o = 0; o < NUM_PORTS; o++) begin
        for (int k = 0; k < NUM_VC; k++) held_credits[o][k] <= 0;
      end
    end else begin
      cr_pipe[0] <= '0;
      for (int o = 0; o < NUM_PORTS; o++) begin
        // Index by an explicit compare rather than by out_vc_id[o] directly:
        // the sideband is 2 bits wide while the row index is clog2(NUM_VC)
        // wide, and an out-of-range value would select past the end.
        for (int k = 0; k < NUM_VC; k++) begin
          if (out_flit_valid[o] && (out_vc_id[o] == VC_W'(k))) cr_pipe[0][o][k] <= 1'b1;
        end
      end
      for (int i = 1; i <= CRED_LAT; i++) begin
        cr_pipe[i] <= cr_pipe[i-1];
      end
      // Collect the credits the pipe just produced while the loop is shut;
      // while it is open, pay the backlog down at one per cycle (a cycle
      // that already carries a fresh credit spends that one instead, so the
      // backlog simply follows behind).
      for (int o = 0; o < NUM_PORTS; o++) begin
        for (int k = 0; k < NUM_VC; k++) begin
          if (!credit_en) begin
            if (cr_pipe[CRED_LAT][o][k]) held_credits[o][k] <= held_credits[o][k] + 1;
          end else if ((held_credits[o][k] != 0) && !cr_pipe[CRED_LAT][o][k]) begin
            held_credits[o][k] <= held_credits[o][k] - 1;
          end
        end
      end
    end
  end

  // ds_credit_valid is a whole array at the DUT endpoint; the gating lives
  // in this one continuous assign.
  always_comb begin : credit_gate
    for (int o = 0; o < NUM_PORTS; o++) begin
      for (int k = 0; k < NUM_VC; k++) begin
        ds_credit_valid[o][k] = credit_en &
                                (cr_pipe[CRED_LAT][o][k] | (held_credits[o][k] != 0));
      end
    end
  end

  //---------------------------------------------------------------
  // 10. Upstream link driver
  //
  // One queue per incoming port. Flits are put on the link at a negedge and
  // held for exactly one cycle, or run back to back while the queue has
  // more. Flow control mirrors a real neighbour: no more than FIFO_DEPTH
  // flits in flight per (port, VC), because credit_return_valid marks the
  // fetch that freed a FIFO slot and the slot is writable the same cycle.
  //---------------------------------------------------------------
  //
  // The TX queue is ONE queue carrying its destination port alongside the
  // flit, not an array of queues (`tx_t q[NUM_PORTS][$]`).  An array of
  // queues with a variable index corrupts silently in this simulator
  // (push_back writes the wrong element), whereas a single queue indexed
  // by a variable is well behaved.  The oldest entry for a given port is
  // found by a scan, which is exactly the "oldest packet first" order a
  // real link needs anyway.
  typedef struct {
    int          port;
    logic [VC_W-1:0] vc;
    logic [FLIT_W-1:0] data;
  } tx_t;

  tx_t tx_q[$];
  int  inflight[NUM_PORTS][NUM_VC];

  initial begin
    for (int p = 0; p < NUM_PORTS; p++) begin
      in_flit_data[p]  = '0;
      in_flit_valid[p] = 1'b0;
      in_vc_id[p]      = '0;
      for (int k = 0; k < NUM_VC; k++) inflight[p][k] = 0;
    end
  end

  // Push a flit onto a port's incoming link queue.
  task automatic send(input int port, input logic [FLIT_W-1:0] data, input logic [VC_W-1:0] vc);
    tx_t t;
    // The guard reads the whole 32-bit index rather than letting it decay
    // into an array subscript, and it turns a mistyped port number in a
    // test into a reported failure instead of a silently indexed queue.
    if ((port < 0) || (port >= NUM_PORTS)) begin
      $display("[FAIL] send(): port %0d out of range 0..%0d", port, NUM_PORTS - 1);
      errors++;
      return;
    end
    t.port = port;
    t.vc   = vc;
    t.data = data;
    // One shared queue, destination carried in the entry (see the tx_t
    // comment): a per-port array of queues does not survive a variable
    // index in this simulator.
    tx_q.push_back(t);
  endtask

  int drv_vc;
  int drv_idx;

  always @(negedge clk) begin : tx_driver
    if (!rst_n) begin
      for (int p = 0; p < NUM_PORTS; p++) begin
        in_flit_valid[p] = 1'b0;
        for (int k = 0; k < NUM_VC; k++) inflight[p][k] = 0;
      end
    end else begin
      // Credits returned during this cycle free a FIFO slot that is
      // writable from the posedge at the end of this same cycle, so they
      // are accounted before the drive decision below. Reading them at the
      // negedge (rather than at the posedge) is what keeps the count exact
      // instead of one cycle conservative.
      for (int p = 0; p < NUM_PORTS; p++) begin
        for (int k = 0; k < NUM_VC; k++) begin
          if (credit_return_valid[p][k] && inflight[p][k] > 0) inflight[p][k]--;
        end
      end

      for (int p = 0; p < NUM_PORTS; p++) begin
        in_flit_valid[p] = 1'b0;
        // Oldest queued flit owed to this port. The linear scan preserves
        // arrival order, so a port can never overtake its own earlier
        // packet, and it keeps every queue index a plain variable read of
        // the one shared queue.
        drv_idx = -1;
        for (int i = 0; i < tx_q.size(); i++) begin
          if (tx_q[i].port == p) begin
            drv_idx = i;
            break;
          end
        end
        if (drv_idx >= 0) begin
          drv_vc = int'(tx_q[drv_idx].vc);
          // The sideband is wider than NUM_VC needs. Making the range check
          // explicit keeps every bit of the index observable and stops a
          // malformed sideband from selecting past the end of inflight.
          if (drv_vc >= NUM_VC) begin
            $display("[FAIL] tx driver saw out-of-range vc_id %0d on port %0d",
                     drv_vc, p);
            errors++;
          end else if (inflight[p][drv_vc] < FIFO_DEPTH) begin
            in_flit_data[p]  = tx_q[drv_idx].data;
            in_vc_id[p]      = tx_q[drv_idx].vc;
            in_flit_valid[p] = 1'b1;
            inflight[p][drv_vc]++;
            tx_q.delete(drv_idx);
          end
        end
      end
    end
  end

  //---------------------------------------------------------------
  // 11. Wait helpers
  //---------------------------------------------------------------

  // Block until the router has drained everything the bench owes it (or
  // until the watchdog fires, so a stall fails the test rather than
  // hanging the run).
  task automatic drain(input int max_cycles);
    int n;
    int left;
    n = 0;
    left = 1;
    while ((left != 0) && (n < max_cycles)) begin
      left = tx_q.size();
      if (left != 0) begin
        @(negedge clk);
        n++;
      end
    end
    // Then give the router a few more cycles to move whatever it has left
    // from its FIFOs out onto a link.
    repeat (20) @(negedge clk);
    check_true($sformatf("drain completed within %0d cycles", max_cycles), left == 0);
  endtask

  // Run the clock with no stimulus until nothing moves, for tests that only
  // care about a settled result.
  task automatic settle();
    repeat (10) @(negedge clk);
  endtask

  //---------------------------------------------------------------
  // 12. Tests
  //---------------------------------------------------------------

  // T1: a single HEAD_TAIL, the simplest complete packet there is.
  //
  //   a) LOCAL -> EAST   : route_compute computes the direction from the
  //                        destination coordinates, because on the LOCAL
  //                        port there is no incoming header yet.
  //   b) EAST  -> WEST    : the direction comes out of the header's ROUTE
  //                        field, because the upstream router already
  //                        computed it as a lookahead.
  //
  // The two paths through route_compute are mutually exclusive per port
  // (IS_LOCAL_PORT), so both have to be exercised or one of them can be
  // wrong without anything else noticing.
  task automatic t1_single_head_tail();
    clear_rx();

    // (a) LOCAL -> EAST: dest (2,1) is east of (1,1).
    send(LOCAL_IDX, mk_ht(3'd2, 3'd1, DIR_EAST, 2'd0, 18'h1_A11A), VC_W'(0));
    drain(200);

    check("T1a flit count", rx_n(), 1);
    if (rx_n() >= 1) begin
      check("T1a left through EAST", rx_port(0), EAST_IDX);
      check("T1a type is HEAD_TAIL", rx_type(0), FLIT_HEAD_TAIL);
      check("T1a payload survived", rx_tag(0), 18'h1_A11A);
      // The outgoing header must carry the NEXT hop's route, not this
      // router's own decision. T1a entered with DIR_EAST and its
      // destination is (2,1) -- exactly the router on the far side of the
      // east link -- so the merged field has to read DIR_LOCAL. Nothing
      // inside a single router ever looks at the route field it just
      // wrote, which makes this the only outside observation of the merge.
      check("T1a outgoing route is the next hop", rx_route(0), DIR_LOCAL);
    end

    clear_rx();

    // (b) EAST -> WEST: arrived on the east link, header says exit WEST.
    send(EAST_IDX, mk_ht(3'd0, 3'd1, DIR_WEST, 2'd0, 18'h1_B22B), VC_W'(0));
    drain(200);

    check("T1b flit count", rx_n(), 1);
    if (rx_n() >= 1) begin
      check("T1b left through WEST", rx_port(0), WEST_IDX);
      check("T1b type is HEAD_TAIL", rx_type(0), FLIT_HEAD_TAIL);
      check("T1b payload survived", rx_tag(0), 18'h1_B22B);
    end

    clear_rx();

    // (c) NORTH -> SOUTH: a pass-through across the mesh rather than a turn
    // or an ejection, so the exit port is the one directly opposite the
    // input. Dest (1,2) is south of (1,1); the header's ROUTE field is what
    // selects it, since this flit arrived on a directional port.
    send(NORTH_IDX, mk_ht(3'd1, 3'd2, DIR_SOUTH, 2'd0, 18'h1_C33C), VC_W'(0));
    drain(200);

    check("T1c flit count", rx_n(), 1);
    if (rx_n() >= 1) begin
      check("T1c left through SOUTH", rx_port(0), SOUTH_IDX);
      check("T1c type is HEAD_TAIL", rx_type(0), FLIT_HEAD_TAIL);
      check("T1c payload survived", rx_tag(0), 18'h1_C33C);
      // Same merge on the other RC path: T1c arrived on a directional port
      // (route_self is just the header's own route there) with DIR_SOUTH,
      // and (1,2) is the destination, so the neighbour must be told
      // DIR_LOCAL. Covers the non-local branch of the lookahead as well.
      check("T1c outgoing route is the next hop", rx_route(0), DIR_LOCAL);
    end
  endtask


  // T2: the reference timeline of section 3 -- a 3-flit packet H, B, T
  // arriving back to back on the EAST input VC0 for the WEST output.
  //
  // Section 3 makes three promises here: the flits arrive in order (HEAD,
  // BODY, TAIL), all three take the same route, and no extras appear. The
  // other two promises of that timeline -- the 3-cycle hop latency and the
  // three grants landing on consecutive cycles -- are sharp enough to deserve
  // their own measurements, so they live in T9 and T8 respectively rather
  // than being inferred from a count that would look identical either way.
  task automatic t2_three_flit_packet();
    int n0;
    int n1;
    logic [FLIT_W-15:0] tag;
    logic [FLIT_W-1:0] sent_body;
    logic [FLIT_W-1:0] sent_tail;
    tag = 18'h2_3F17;

    clear_rx();
    // The destination is one hop BEYOND the exit port on purpose: the flit
    // leaves west towards (0,1) but terminates at (0,2), so the merged
    // route field must be DIR_SOUTH -- the turn the neighbour will make.
    // That also gives the BODY and TAIL a non-zero route_next to be
    // protected from: with a destination right at the next router the
    // lookahead would be DIR_LOCAL and a merge applied to every flit would
    // rewrite them with the value they already carry.
    send(EAST_IDX, mk_head(3'd0, 3'd2, DIR_WEST, 2'd0, tag), VC_W'(0));
    send(EAST_IDX, mk_body(tag), VC_W'(0));
    send(EAST_IDX, mk_tail(tag), VC_W'(0));

    // Wait for the first flit to leave, measuring from the cycle the head
    // was actually put on the link.
    n0 = 0;
    while ((rx_n() == 0) && (n0 < 60)) begin
      @(negedge clk);
      n0++;
    end
    check_true("T2 output appeared within 60 cycles", rx_n() > 0);

    // The BODY and TAIL leave on the two cycles right behind the HEAD, so
    // count only once the whole packet has been logged -- stopping at the
    // first arrival would report a 1-flit packet no matter what the router
    // did with the rest.
    n1 = 0;
    while ((rx_n() < 3) && (n1 < 16)) begin
      @(negedge clk);
      n1++;
    end

    check("T2 all three flits arrived", rx_n(), 3);

    if (rx_n() >= 3) begin
      // Order and type sequence: HEAD, BODY*, TAIL.
      check("T2 flit 0 is the HEAD", rx_type(0), FLIT_HEAD);
      check("T2 flit 1 is the BODY", rx_type(1), FLIT_BODY);
      check("T2 flit 2 is the TAIL", rx_type(2), FLIT_TAIL);

      // Every flit took the same route.
      check("T2 flit 0 exit port", rx_port(0), WEST_IDX);
      check("T2 flit 1 exit port", rx_port(1), WEST_IDX);
      check("T2 flit 2 exit port", rx_port(2), WEST_IDX);

      // ...and the header leaving carries the neighbour's next move, not
      // this router's: west to (0,1), then south to (0,2).
      check("T2 outgoing route is the next hop", rx_route(0), DIR_SOUTH);

      // The output port is only allowed to touch the header's [13:10]
      // route field, and only on a head. A BODY and a TAIL must therefore
      // come out bit-for-bit identical to what went in -- this catches the
      // merge being applied to every flit rather than just to heads, which
      // corrupts payload silently and is invisible in a count or a type.
      sent_body = mk_body(tag);
      sent_tail = mk_tail(tag);
      check("T2 BODY flit left unmodified", rx[1].data, sent_body);
      check("T2 TAIL flit left unmodified", rx[2].data, sent_tail);
    end
  endtask


  // T3: two packets back to back in the SAME VC.
  //
  // The second packet's HEAD has to be accepted into a VC whose
  // assignment_valid only cleared at the previous TAIL's grant, which is
  // seam 8 -- output VC reuse. If the reservation were released one cycle
  // late the second packet would stall behind it; one cycle early and it
  // would be routed while the first was still in flight.
  task automatic t3_back_to_back_packets();
    clear_rx();

    send(EAST_IDX, mk_head(3'd0, 3'd1, DIR_WEST, 2'd0, 18'h3_AA01), VC_W'(0));
    send(EAST_IDX, mk_body(18'h3_AA01), VC_W'(0));
    send(EAST_IDX, mk_tail(18'h3_AA01), VC_W'(0));
    send(EAST_IDX, mk_head(3'd0, 3'd1, DIR_WEST, 2'd0, 18'h3_BB02), VC_W'(0));
    send(EAST_IDX, mk_tail(18'h3_BB02), VC_W'(0));
    drain(400);

    check("T3 both packets arrived (5 flits)", rx_n(), 5);
    if (rx_n() >= 5) begin
      check("T3 p1 HEAD", rx_tag(0), 18'h3_AA01);
      check("T3 p1 BODY", rx_type(1), FLIT_BODY);
      check("T3 p1 TAIL", rx_type(2), FLIT_TAIL);
      check("T3 p2 HEAD follows immediately", rx_tag(3), 18'h3_BB02);
      check("T3 p2 TAIL", rx_type(4), FLIT_TAIL);
      for (int i = 0; i < 5; i++) check($sformatf("T3 flit %0d exit port", i),
                                        rx_port(i), WEST_IDX);
    end
  endtask


  // T4: two VCs on ONE input port, heading to different outputs.
  //
  // An input port has a single 32-bit datapath, so stage 1 must pick at most
  // one VC per cycle even though both have a right to go. VC0 goes EAST and
  // VC1 goes NORTH, and both streams must arrive intact -- if stage 1 could
  // pick two, one of them would be switched with the other's payload.
  //
  // The two next hops must also be a legal XY pair for a WEST input
  // (EAST/NORTH/SOUTH/LOCAL, never WEST): a flit that has already arrived
  // from the west has no business being sent back west, and the arbiter
  // says so out loud.
  task automatic t4_two_vcs_one_port();
    clear_rx();

    // VC0 -> EAST, three flits.
    send(WEST_IDX, mk_head(3'd2, 3'd1, DIR_EAST, 2'd0, 18'h4_C000), VC_W'(0));
    send(WEST_IDX, mk_body(18'h4_C000), VC_W'(0));
    send(WEST_IDX, mk_tail(18'h4_C000), VC_W'(0));
    // VC1 -> NORTH, three flits.
    send(WEST_IDX, mk_head(3'd1, 3'd2, DIR_NORTH, 2'd1, 18'h4_C111), VC_W'(1));
    send(WEST_IDX, mk_body(18'h4_C111), VC_W'(1));
    send(WEST_IDX, mk_tail(18'h4_C111), VC_W'(1));
    drain(400);

    check("T4 both VC streams arrived (6 flits)", rx_n(), 6);
    if (rx_n() >= 6) begin : t4_stats
      int n_east, n_north;
      n_east = 0; n_north = 0;
      for (int i = 0; i < rx_n(); i++) begin
        if (rx_port(i) == EAST_IDX) n_east++;
        if (rx_port(i) == NORTH_IDX) n_north++;
      end
      check("T4 three flits left via EAST", n_east, 3);
      check("T4 three flits left via NORTH", n_north, 3);
    end
    // Payloads must not have crossed between the two streams, and each
    // packet must ride one downstream VC for its whole length. Stage 1 is
    // allowed to interleave them, so neither property can be read off the
    // arrival order: pull each packet back out by its tag and check it is
    // still HEAD, BODY, TAIL in order with every flit on the same VC. A VC
    // change mid-packet is how head-of-line blocking turns into
    // reordering, and a swapped payload shows up as the wrong type here.
    //
    // The downstream VC is deliberately NOT required to equal the input
    // VC: the two streams leave through different output ports, and each
    // output port allocates its own VC rows from its own free list.
    if (rx_n() >= 6) begin : t4_stream_check
      int n_ok, seen, vc_a;
      n_ok = 1;
      for (int s = 0; s < 2; s++) begin
        seen = 0;
        vc_a = -1;
        for (int i = 0; i < rx_n(); i++) begin
          if (rx_tag(i) == ((s == 0) ? 18'h4_C000 : 18'h4_C111)) begin
            case (seen)
              0: if (rx_type(i) != FLIT_HEAD)  n_ok = 0;
              1: if (rx_type(i) != FLIT_BODY)  n_ok = 0;
              2: if (rx_type(i) != FLIT_TAIL)  n_ok = 0;
              default: n_ok = 0;
            endcase
            if (vc_a < 0) vc_a = rx[i].vc;
            else if (rx[i].vc != vc_a) n_ok = 0;
            seen++;
          end
        end
        if (seen != 3) n_ok = 0;
      end
      check_true("T4 no payload crossed streams", n_ok != 0);
    end
  endtask


  // T5: two input ports competing for the SAME output -- stage 2 fairness.
  //
  // NORTH and EAST both want LOCAL. Stage 1 has already picked within each
  // port by the time they meet, so this is purely the rr2 round-robin, and
  // both streams must arrive with neither side starved.
  //
  // Both sides send one SIX-flit packet rather than a run of single-flit
  // packets, and that is the whole point of the test. Single-flit packets
  // pace themselves: after a grant the port spends a cycle fetching its
  // next flit, so the two sides drift into opposite phases, stage 2 never
  // sees two requesters in the same cycle, and an arbiter that simply
  // latched the lowest requesting port every time would look perfectly
  // fair. Inside a packet fetch and grant share a cycle (section 9), so
  // `sa_req` stays asserted on every cycle of the packet -- both ports
  // then ask on the same cycles, over and over, and only the round-robin
  // pointer can keep them interleaved.
  task automatic t5_two_inputs_one_output();
    int n_from_north;
    int n_from_east;
    int first_six_north;
    int first_six_east;

    clear_rx();

    // One packet from each side, same shape, same cycle. The tags differ in
    // their top two bits so the receiver can attribute an arrival to the
    // port that sent it -- which is the only way to observe fairness from
    // outside the router.
    //
    // The two sides are deliberately NOT on the same input VC. Under a
    // VC-matched allocator (linnea_v2 section 4.4) input VC v can only ever
    // be reserved as output VC v, so a second packet arriving on VC0 while
    // VC0's row is held would simply wait for the first to finish -- one
    // stream after the other, and stage 2 would never see two requesters at
    // once. Putting the second on VC1 is what lets both be allocated in the
    // same cycle and genuinely contend from here down, which is the whole
    // condition this test exists to create. (Before section 4.4 the separable
    // VA did that remapping for us, which is why this used to read VC0.)
    send(NORTH_IDX, mk_head(3'd1, 3'd1, DIR_LOCAL, 2'd0, 18'h1_0001), VC_W'(0));
    for (int i = 0; i < 4; i++) send(NORTH_IDX, mk_body(18'h1_0001), VC_W'(0));
    send(NORTH_IDX, mk_tail(18'h1_0001), VC_W'(0));

    send(EAST_IDX, mk_head(3'd1, 3'd1, DIR_LOCAL, 2'd0, 18'h2_0002), VC_W'(1));
    for (int i = 0; i < 4; i++) send(EAST_IDX, mk_body(18'h2_0002), VC_W'(1));
    send(EAST_IDX, mk_tail(18'h2_0002), VC_W'(1));

    drain(600);

    check("T5 both packets arrived (12 flits)", rx_n(), 12);

    if (rx_n() >= 12) begin : t5_stats
      logic [1:0] origin;   // tag's top two bits: which port sent it
      n_from_north = 0;
      n_from_east  = 0;
      first_six_north = 0;
      first_six_east  = 0;
      for (int i = 0; i < rx_n(); i++) begin
        origin = rx_origin(i);
        if (origin == 2'b01) n_from_north++;
        else if (origin == 2'b10) n_from_east++;
        if (i < 6) begin
          if (origin == 2'b01) first_six_north++;
          if (origin == 2'b10) first_six_east++;
        end
      end
      check("T5 six from NORTH", n_from_north, 6);
      check("T5 six from EAST", n_from_east, 6);
      // Fairness under genuine contention: with both ports requesting on
      // the same cycle for six cycles straight, a stage 2 that latched the
      // first requester it saw would hand the output to one side for all
      // six leading flits. Both sides must therefore be inside the first
      // half of the stream.
      check_true("T5 stage-2 alternated between the two ports",
                 (first_six_north >= 2) && (first_six_east >= 2));
      for (int i = 0; i < rx_n(); i++) check($sformatf("T5 flit %0d exit port", i),
                                             rx_port(i), LOCAL_IDX);
    end
  endtask


  // T6: VA contention -- three requesters, two output VCs, and the
  // HEAD_TAIL tier bit.
  //
  // NORTH and EAST each send a multi-flit packet (HEAD to be followed by a
  // TAIL), WEST sends a single-flit HEAD_TAIL. With two rows and three
  // candidates the allocator must leave one out, and section 4.3 says the
  // single-flit request is picked first in every row. The row pointers here
  // start at 0, which without the tier would hand row 0 to NORTH (the
  // lowest port index at or after 0) -- so WEST arriving in the first two
  // flits out is a direct observation of the tier bit doing its job.
  task automatic t6_va_contention();
    clear_rx();

    send(NORTH_IDX, mk_head(3'd1, 3'd1, DIR_LOCAL, 2'd0, 18'h6_A0FF), VC_W'(0));
    send(NORTH_IDX, mk_tail(18'h6_A0FF), VC_W'(0));
    send(EAST_IDX,  mk_head(3'd1, 3'd1, DIR_LOCAL, 2'd0, 18'h6_B0FF), VC_W'(0));
    send(EAST_IDX,  mk_tail(18'h6_B0FF), VC_W'(0));
    send(WEST_IDX,  mk_ht  (3'd1, 3'd1, DIR_LOCAL, 2'd0, 18'h6_C1EE), VC_W'(0));
    drain(600);

    // Total: 2 + 2 + 1 = 5 flits (N: H+T, E: H+T, W: HEAD_TAIL).
    check("T6 all three packets arrived (5 flits)", rx_n(), 5);

    if (rx_n() >= 5) begin : t6_stats
      int w_pos;
      int n_north, n_east, n_west;

      w_pos   = -1;
      n_north = 0; n_east = 0; n_west = 0;
      for (int i = 0; i < rx_n(); i++) begin
        if (rx_tag(i) == 18'h6_C1EE) w_pos = i;
        if (rx_tag(i) == 18'h6_A0FF) n_north++;
        if (rx_tag(i) == 18'h6_B0FF) n_east++;
        if (rx_tag(i) == 18'h6_C1EE) n_west++;
      end

      // The tier bit is what guarantees this: with two rows and three
      // candidates one request loses, and section 4.3 says the single-flit
      // one is chosen first in every row.
      check_true("T6 the single-flit HEAD_TAIL was served", w_pos >= 0);
      check_true("T6 HEAD_TAIL beat the multi-flit requests (first two out)",
                 (w_pos == 0) || (w_pos == 1));
      if (w_pos >= 0) check("T6 WEST's flit left via LOCAL", rx_port(w_pos), LOCAL_IDX);

      // Every requester must eventually be served -- a tier that starved
      // the losers entirely would pass the two checks above.
      check("T6 NORTH's two flits arrived", n_north, 2);
      check("T6 EAST's two flits arrived", n_east, 2);
      check("T6 WEST's one flit arrived", n_west, 1);
    end
  endtask


  // T7: credit exhaustion, recovery, and the same-cycle +1/-1.
  //
  // The downstream credit pool for an output is FIFO_DEPTH wide. Close the
  // return loop, push FIFO_DEPTH + 4 flits through, and exactly FIFO_DEPTH
  // of them must leave -- the router has to stop granting rather than
  // over-run the neighbour. Then reopen the loop and the remaining four
  // must flow, which also exercises a credit arriving in the same cycle a
  // flit leaves (they must net to zero, not to -1 or +2).
  task automatic t7_credit_exhaustion();
    int before_reopen;

    credit_en = 1'b0;
    clear_rx();

    for (int i = 0; i < FIFO_DEPTH + 4; i++) begin
      send(LOCAL_IDX, mk_ht(3'd2, 3'd1, DIR_EAST, 2'd0, 18'(18'h7_0000 + i)), VC_W'(0));
    end

    // Let it run long enough that any over-grant would have happened.
    repeat (120) @(negedge clk);

    before_reopen = rx_n();
    check("T7 exactly FIFO_DEPTH flits left before credits returned",
          before_reopen, FIFO_DEPTH);

    // The block has to be a block, not a slowdown: nothing more may escape
    // while the credits are held. Without this, a router that merely ran
    // slowly would pass the count above by luck of when we looked.
    repeat (40) @(negedge clk);
    check("T7 no further flits escaped while credits were held", rx_n(), FIFO_DEPTH);

    // Reopen the loop: credits now come back and the rest must drain.
    credit_en = 1'b1;
    drain(400);

    check("T7 every flit eventually left", rx_n(), FIFO_DEPTH + 4);
    if (rx_n() >= FIFO_DEPTH + 4) begin
      check("T7 flit 0 tag", rx_tag(0), 18'h7_0000);
      check("T7 last flit tag", rx_tag(FIFO_DEPTH + 3), 18'(18'h7_0000 + (FIFO_DEPTH + 3)));
      for (int i = 0; i < rx_n(); i++) check($sformatf("T7 flit %0d exit port", i),
                                             rx_port(i), EAST_IDX);
    end
    credit_en = 1'b1;
  endtask


  // T8: fetch and grant in the same cycle -- the collision case.
  //
  // section 3, cycle c2: `sa_gnt` retires head_valid for the flit on
  // data_out while `fetch` is pulling the next one out of the FIFO. Spec
  // section 9 is explicit that fetch must WIN here; under the old ordering
  // the grant overwrote the fetch, head_valid dropped to 0, and the packet
  // advanced one flit every three cycles instead of one per cycle.
  //
  // The observable is therefore a bubble: three flits of one packet must
  // leave on three consecutive cycles. This test watches the output cycle
  // by cycle rather than only counting arrivals, because a count would be
  // identical either way.
  task automatic t8_fetch_grant_collision();
    int n;
    int lat_first;

    clear_rx();

    // Queue the whole packet at once so the driver puts the three flits on
    // the link back to back. That is what guarantees the collision: when
    // flit 0 is granted, flit 1 is already in the FIFO and must be fetched
    // in the very same cycle.
    send(EAST_IDX, mk_head(3'd0, 3'd1, DIR_WEST, 2'd0, 18'h8_C011), VC_W'(0));
    send(EAST_IDX, mk_body(18'h8_C011), VC_W'(0));
    send(EAST_IDX, mk_tail(18'h8_C011), VC_W'(0));

    // Walk to the cycle where the head appears on the output link.
    n = 0;
    while (!out_flit_valid[WEST_IDX] && (n < 80)) begin
      @(negedge clk);
      n++;
    end
    check_true("T8 the head reached the output link",
               out_flit_valid[WEST_IDX] === 1'b1);
    lat_first = n;
    check("T8 the head is the first flit out", flit_type(out_flit_data[WEST_IDX]),
          FLIT_HEAD);

    // From here, the BODY and the TAIL must follow on the very next two
    // cycles. Under the old grant-wins-over-fetch ordering, head_valid
    // would drop, the fetch would be lost, and the packet would advance one
    // flit every three cycles -- which is exactly an idle cycle appearing
    // somewhere in these next two samples.
    @(negedge clk);
    check("T8 BODY on the very next cycle", out_flit_valid[WEST_IDX], 1'b1);
    check("T8 BODY payload is from the same packet", flit_tag(out_flit_data[WEST_IDX]),
          18'h8_C011);
    check("T8 BODY type", flit_type(out_flit_data[WEST_IDX]), FLIT_BODY);

    @(negedge clk);
    check("T8 TAIL on the cycle after that", out_flit_valid[WEST_IDX], 1'b1);
    check("T8 TAIL type", flit_type(out_flit_data[WEST_IDX]), FLIT_TAIL);

    // And the arrival log agrees that exactly three left -- no duplicates
    // from a double fetch. One more cycle first: the logger samples at the
    // posedge that closes a cycle, so the third flit is only in the log
    // after the posedge following the negedge we just observed it on.
    @(negedge clk);
    check("T8 exactly three flits left", rx_n(), 3);
    check_true("T8 first flit appeared within a sane time", lat_first < 80);
  endtask


  // T9: empty-FIFO bypass.
  //
  // A flit landing on an empty VC goes straight through the FIFO's write
  // bypass onto data_out on the very next cycle -- it is never written to
  // RAM and read back. The cost of getting this wrong is one extra cycle of
  // per-hop latency, which is invisible in any count-based test, so it is
  // measured directly: input link to output link must be exactly 3 cycles.
  //
  //   c0  flit on the input link, FIFO empty -> fetch (bypass)
  //   c1  flit on data_out, VA grants
  //   c2  SA grants, flit crosses the crossbar, link register loads
  //   c3  flit on the output link
  task automatic t9_empty_fifo_bypass();
    int c_in;
    int c_out;
    int lat;

    clear_rx();
    send(LOCAL_IDX, mk_ht(3'd2, 3'd1, DIR_EAST, 2'd0, 18'h9_B995), VC_W'(0));

    // Both ends of the hop are sampled at the posedge that closes each
    // cycle -- the same edge the RX logger uses, so both readings are "the
    // value this cycle carried".  Watching negedges instead would make the
    // answer depend on whether this process or the driver gets to run first
    // at the negedge where the flit is presented, and that single cycle of
    // slack is the entire thing being measured.
    c_in  = -1;
    c_out = -1;
    for (int c = 0; c < 40; c++) begin
      @(posedge clk);
      if ((c_in  < 0) && (in_flit_valid[LOCAL_IDX] === 1'b1)) c_in  = c;
      if ((c_out < 0) && (out_flit_valid[EAST_IDX] === 1'b1)) c_out = c;
      if ((c_in >= 0) && (c_out >= 0)) break;
    end

    check_true("T9 the flit reached the input link", c_in  >= 0);
    check_true("T9 the flit reached the output link", c_out >= 0);
    if ((c_in >= 0) && (c_out >= 0)) begin
      lat = c_out - c_in;
      check("T9 bypass hop latency is 3 cycles", lat, 3);
    end

    // The logger took the flit on the same edge that reported c_out, but
    // it and this process race inside that edge -- so look one negedge
    // later, when there is no doubt it has run.
    @(negedge clk);
    check("T9 flit arrived", rx_n(), 1);
    if (rx_n() >= 1) begin
      check("T9 payload survived the bypass", rx_tag(0), 18'h9_B995);
      check("T9 type is HEAD_TAIL", rx_type(0), FLIT_HEAD_TAIL);
      check("T9 exit port", rx_port(0), EAST_IDX);
    end
  endtask


  //---------------------------------------------------------------
  // 13. Edge-of-mesh check
  //
  // A router on the boundary has HAS_WEST = 0. Nothing may be routed out
  // of it, and no credit may come back as though a link were there. This
  // is the second half of section 4.6's instruction -- the tie-off itself
  // is inside router_top; what is verified here is that the tie is never
  // load-bearing for a legal packet.
  //---------------------------------------------------------------
  task automatic t_edge_ports();
    // In-range destinations simply never choose an absent direction: with
    // HAS_WEST = 0 a packet bound for (2,1) still leaves via EAST and one
    // bound for (1,0) still leaves via NORTH.
    clear_rx();
    send(LOCAL_IDX, mk_ht(3'd2, 3'd1, DIR_EAST, 2'd0, 18'hA_0001), VC_W'(0));
    send(LOCAL_IDX, mk_ht(3'd1, 3'd0, DIR_NORTH, 2'd0, 18'hA_0002), VC_W'(0));
    drain(300);
    check("E1 both edge-legal packets arrived", rx_n(), 2);
    if (rx_n() >= 2) begin
      check("E1 first left via EAST", rx_port(0), EAST_IDX);
      check("E1 second left via NORTH", rx_port(1), NORTH_IDX);
    end
  endtask


  //---------------------------------------------------------------
  // 14. Reset
  //---------------------------------------------------------------
  task automatic reset_dut();
    rst_n = 1'b0;
    repeat (5) @(posedge clk);
    @(negedge clk);
    rst_n = 1'b1;
    @(negedge clk);
    clear_rx();
  endtask


  //---------------------------------------------------------------
  // 15. Main
  //---------------------------------------------------------------
  initial begin : main
    if ($test$plusargs("vcd")) begin
      $dumpfile("sim/router_top.vcd");
      $dumpvars(0, tb_router_top);
    end

    reset_dut();

    $display("---- T1  single HEAD_TAIL, LOCAL->EAST and EAST->WEST ----");
    t1_single_head_tail();

    $display("---- T2  the section 3 three-flit packet ----");
    t2_three_flit_packet();

    $display("---- T3  two packets back to back in the same VC ----");
    t3_back_to_back_packets();

    $display("---- T4  two VCs on one input port, different outputs ----");
    t4_two_vcs_one_port();

    $display("---- T5  two inputs competing for one output ----");
    t5_two_inputs_one_output();

    $display("---- T6  VA contention: three requesters, two output VCs ----");
    t6_va_contention();

    $display("---- T7  credit exhaustion and recovery ----");
    t7_credit_exhaustion();

    $display("---- T8  fetch and grant in the same cycle ----");
    t8_fetch_grant_collision();

    $display("---- T9  empty-FIFO bypass ----");
    t9_empty_fifo_bypass();

    $display("---- edge-of-mesh ports ----");
    t_edge_ports();

    $display("");
    if (errors == 0) $display("ALL %0d CHECKS PASSED", checks);
    else $display("%0d/%0d CHECKS FAILED", errors, checks);

    $finish;
  end

endmodule
