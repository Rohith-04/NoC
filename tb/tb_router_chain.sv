`timescale 1ns / 1ps

//=============================================================================
// tb_router_chain.sv
//
// Step 8: three routers wired into a line, tests T10 and T11 of section 8,
// plus the section 6 credit-loop confirmation.
//
//
// Why a chain and not another single router
// -----------------------------------------
// Everything from T1 down to T9 looks at ONE router, so every property it
// proves is a property of a block. Two things are inherently two-block
// properties and can never be observed that way:
//
//  * route_next.  A router writes the NEXT hop's direction into the header
//    it transmits, and then never looks at that field again -- its own exit
//    decision came from route_self, which it latched on arrival. The merge
//    is only meaningful to whoever receives the flit, so the check needs a
//    real sender and a real receiver. Two hops in a line give it twice.
//
//  * The credit loop of section 6.  credit_return_valid leaves one router
//    and has to arrive at the arbiter of the one that fed it, through the
//    same wires a real link would carry. A bench model of that return path
//    (what tb_router_top uses) proves the model; only router-to-router
//    wiring proves the loop itself, and only a long stream proves that the
//    loop is short enough for the credits on hand.
//
//
// Topology
// --------
// A horizontal line at Y = 1, X = 0, 1, 2. EAST is +X:
//
//    (0,1) A --EAST--> B --EAST--> C (2,1)
//    A has no WEST, C has no EAST, and nobody has a NORTH or a SOUTH.
//
// Those absent ports are declared absent (HAS_*) rather than left floating,
// which is what exercises router_top's tie-off and its two edge-port
// assertions: nothing may be routed out of a port with no neighbour, and no
// credit may come back on a link that does not exist.
//
//   A.EAST  --> B.WEST      A.ds_credit[EAST]  <-- B.credit_return[WEST]
//   B.EAST  --> C.WEST      B.ds_credit[EAST]  <-- C.credit_return[WEST]
//   B.WEST  --> A.EAST      B.ds_credit[WEST]  <-- A.credit_return[EAST]
//   C.WEST  --> B.EAST      C.ds_credit[WEST]  <-- B.credit_return[EAST]
//
// The LOCAL ports are the network interfaces: the bench injects on one and
// ejects on another, and the ejection side hands credits back through the
// NI model below (LOCAL_CREDITS = 4 is the tight pool in this design, and
// the one section 6 asks to be confirmed at full rate).
//
//
// The four models this bench provides
// -----------------------------------
//  * LINK. Every inter-router wire is a plain copy of the driving router's
//    registered outputs, taken at the negedge and held for the cycle. The
//    receiving router samples it at the following posedge, which is exactly
//    what a continuous wire would deliver, so no link latency is added.
//
//  * UPSTREAM / INJECTION. The LOCAL ports are fed through one queue with
//    the usual per-(router, VC) inflight limit of FIFO_DEPTH, released by
//    that router's own credit_return_valid[LOCAL]. Same contract as
//    tb_router_top: a bench that ignores this drives the FIFO past its
//    depth and turns every overflow into a bogus failure.
//
//  * NI (ejection credits). A flit leaving a LOCAL output returns a credit
//    two cycles later, which is section 6's own "registered credit return
//    visible g+2, usable g+3" shape. LOCAL_CREDITS = 4 against a loop of 3
//    is the case section 6 says must still sustain full rate, and the
//    full-rate test below is the confirmation it asks for.
//
//  * RECEIVER. Every flit leaving ANY router on ANY port is logged with its
//    router, port, VC, payload and cycle number, so tests can ask "where did
//    this packet go, in what order, carrying what" instead of poking at
//    wires.
//
//
// Everything is wired as a whole array or a plain scalar
// -------------------------------------------------------
// Each router owns its own set of port signals, and each set is connected
// to its instance whole. Nothing in a port connection is an element select
// -- see README "Testbench Wiring Rules". The cross-router copies and the
// per-index snooping happen on bench-side aggregates, never at an endpoint.
//=============================================================================

module tb_router_chain;

  // Flit field model and the shared reporter (see noc_tb_pkg.sv).
  import noc_tb_pkg::*;

  //---------------------------------------------------------------
  // 1. Parameters
  //---------------------------------------------------------------
  // FLIT_W is owned by noc_tb_pkg.

  localparam int          NUM_PORTS  = 5;
  parameter  int          NUM_VC     = 4;
  // VC index width (linnea_v2 section 1): derived rather than independent,
  // so a sideband can never be narrower than the index it carries.
  localparam int          VC_W       = (NUM_VC > 1) ? $clog2(NUM_VC) : 1;
  localparam int          N_RTR      = 3;     // routers in the line
  localparam int          LOCAL_IDX  = 0;
  localparam int          EAST_IDX   = 2;
  localparam int          WEST_IDX   = 3;
  parameter  int          FIFO_DEPTH = 4;
  localparam int          LOCAL_CRED = 4;
  localparam realtime     CLK_PERIOD = 10ns;

  // NI ejection credit-return latency in cycles, BEYOND the NI's own receive
  // register. 0 is section 6's own arithmetic: the flit is on the LOCAL
  // output during cycle g+1, the NI registers the credit at the end of that
  // cycle so it is visible during g+2, and the arbiter counts it at the end
  // of g+2 so it is usable from g+3 -- "a loop of about 3 cycles against 4
  // credits". 1 already makes the loop 4 against 4 and costs a cycle at the
  // fourth flit; 2 costs one at the fourth and settles afterwards. The
  // full-rate test below is what pins this down.
  localparam int          NI_LAT     = 0;

  // Deadlock watchdog: no flit anywhere, nothing queued, for this long while
  // work is still outstanding, and the run is stuck.
  localparam int          MAX_STALL  = 500;

  // Length of the single packet used by the section 6 credit-loop test.
  localparam int          PKT_FLITS  = 16;

  // Coordinates of the three routers. Y is the same for all of them; only X
  // varies, so every legal route in this test set is EAST, WEST or LOCAL.
  localparam logic [2:0]  Y_COORD    = 3'd1;
  localparam logic [2:0]  X_A        = 3'd0;
  localparam logic [2:0]  X_B        = 3'd1;
  localparam logic [2:0]  X_C        = 3'd2;

  // FLIT_HEAD / FLIT_BODY / FLIT_TAIL / FLIT_HEAD_TAIL come from the package.

  localparam logic [3:0]  DIR_LOCAL = 4'b0000;
  localparam logic [3:0]  DIR_EAST  = 4'b0010;
  localparam logic [3:0]  DIR_WEST  = 4'b0100;

  //---------------------------------------------------------------
  // 2. Typedefs (declared first: the logger and the scoreboard below
  //    are both built out of them)
  //---------------------------------------------------------------

  // One entry per flit observed leaving a router.
  typedef struct {
    int          rtr;    // which router in the line (0 = A, 1 = B, 2 = C)
    int          port;   // its output port
    int          vc;     // downstream VC the flit was switched onto
    int          cyc;    // cycle it was sampled on, for gap measurements
    logic [FLIT_W-1:0] data;
  } rx_t;

  // One entry per injected packet, i.e. the reference the ejection log is
  // scored against. Deliberately does NOT record an expected arrival slot:
  // two packets may legally take different VCs at an intermediate hop and
  // overtake each other, so the order of independent packets is not a
  // property of this design. What IS a property is that each packet's own
  // flits arrive, in order, at the right router, exactly once -- which is
  // what got/len/dest check.
  typedef struct {
    logic [TAG_W-1:0] tag;
    int          src;
    int          dest;
    int          len;
    int          vc;
    // KIND -- the 2-bit field at [3:2] of the header (linnea_v2 section
    // 3.2). Deliberately NOT the VC: the VC is link sideband and changes at
    // every hop, whereas KIND is written once by the source NI and routers
    // are required to leave it alone. Scoring it is how that is proved.
    int          kind;
    int          got;    // flits of this packet received so far
  } exp_t;

  // The TX queue is ONE queue carrying the destination router alongside the
  // flit, not an array of queues (`tx_t q[N_RTR][$]`).  An array of queues
  // with a variable index corrupts silently in this simulator (push_back
  // writes the wrong element); a single queue indexed by a variable is well
  // behaved.  The oldest entry for a given router is found by a scan, which
  // is exactly the "oldest packet first" order a real link needs anyway.
  typedef struct {
    int          rtr;
    int          vc;
    logic [FLIT_W-1:0] data;
  } tx_t;

  // Declared here, next to its type, rather than down with the driver: the
  // scoreboard's work_pending() reads it and is defined well before the
  // negedge process that fills it.
  tx_t tx_q[$];

  //---------------------------------------------------------------
  // 3. DUT signals -- one whole set of port arrays per router
  //---------------------------------------------------------------
  logic                            clk;
  logic                            rst_n;

  // Router A -- west end of the line.
  logic [NUM_PORTS-1:0][FLIT_W-1:0]      a_in_data;
  logic [NUM_PORTS-1:0]            a_in_valid;
  logic [NUM_PORTS-1:0][VC_W-1:0]       a_in_vc;
  logic [NUM_PORTS-1:0][FLIT_W-1:0]      a_out_data;
  logic [NUM_PORTS-1:0]            a_out_valid;
  logic [NUM_PORTS-1:0][VC_W-1:0]       a_out_vc;
  logic [NUM_PORTS-1:0][NUM_VC-1:0] a_cred_ret;
  logic [NUM_PORTS-1:0][NUM_VC-1:0] a_ds_cred;

  // Router B -- the middle of the line, the only one with both directional
  // neighbours, and therefore the one every through-packet crosses.
  logic [NUM_PORTS-1:0][FLIT_W-1:0]      b_in_data;
  logic [NUM_PORTS-1:0]            b_in_valid;
  logic [NUM_PORTS-1:0][VC_W-1:0]       b_in_vc;
  logic [NUM_PORTS-1:0][FLIT_W-1:0]      b_out_data;
  logic [NUM_PORTS-1:0]            b_out_valid;
  logic [NUM_PORTS-1:0][VC_W-1:0]       b_out_vc;
  logic [NUM_PORTS-1:0][NUM_VC-1:0] b_cred_ret;
  logic [NUM_PORTS-1:0][NUM_VC-1:0] b_ds_cred;

  // Router C -- east end of the line.
  logic [NUM_PORTS-1:0][FLIT_W-1:0]      c_in_data;
  logic [NUM_PORTS-1:0]            c_in_valid;
  logic [NUM_PORTS-1:0][VC_W-1:0]       c_in_vc;
  logic [NUM_PORTS-1:0][FLIT_W-1:0]      c_out_data;
  logic [NUM_PORTS-1:0]            c_out_valid;
  logic [NUM_PORTS-1:0][VC_W-1:0]       c_out_vc;
  logic [NUM_PORTS-1:0][NUM_VC-1:0] c_cred_ret;
  logic [NUM_PORTS-1:0][NUM_VC-1:0] c_ds_cred;

  //---------------------------------------------------------------
  // 4. Indexed views over all three routers
  //
  // The logger, the NI pipe and the credit assembly all need "router r,
  // port p" with r picked at run time. Three separate signal groups cannot
  // be indexed that way, so each group is folded into one packed aggregate
  // with a CONTINUOUS ASSIGN of the whole DUT array -- never an element
  // select at a port connection, which is the pattern README warns about.
  //---------------------------------------------------------------
  logic [N_RTR-1:0][NUM_PORTS-1:0][FLIT_W-1:0]        r_out_data;
  logic [N_RTR-1:0][NUM_PORTS-1:0]              r_out_valid;
  logic [N_RTR-1:0][NUM_PORTS-1:0][VC_W-1:0]         r_out_vc;
  logic [N_RTR-1:0][NUM_PORTS-1:0][NUM_VC-1:0]  r_cred_ret;

  assign r_out_data[0]  = a_out_data;
  assign r_out_data[1]  = b_out_data;
  assign r_out_data[2]  = c_out_data;

  assign r_out_valid[0] = a_out_valid;
  assign r_out_valid[1] = b_out_valid;
  assign r_out_valid[2] = c_out_valid;

  assign r_out_vc[0]    = a_out_vc;
  assign r_out_vc[1]    = b_out_vc;
  assign r_out_vc[2]    = c_out_vc;

  assign r_cred_ret[0]  = a_cred_ret;
  assign r_cred_ret[1]  = b_cred_ret;
  assign r_cred_ret[2]  = c_cred_ret;

  //---------------------------------------------------------------
  // 5. Bookkeeping
  //
  // `checks` and `errors` come from noc_tb_pkg.
  //---------------------------------------------------------------
  int    cyc        = 0;   // free-running cycle counter, sampled pre-edge
  logic [TAG_W-1:0] tag_seq = 18'h0001;

  //---------------------------------------------------------------
  // 6. Clock
  //---------------------------------------------------------------
  initial clk = 1'b0;
  always #(CLK_PERIOD / 2) clk = ~clk;

  always @(posedge clk) cyc <= cyc + 1;

  //---------------------------------------------------------------
  // 7. DUTs -- three instances, identical but for coordinates and the
  //    HAS_* profile of their edge.
  //---------------------------------------------------------------
  router_top #(
      .NUM_PORTS    (NUM_PORTS),
      .NUM_VC       (NUM_VC),
      .LOCAL_IDX    (LOCAL_IDX),
      .FIFO_DEPTH   (FIFO_DEPTH),
      .LOCAL_CREDITS(LOCAL_CRED),
      .CUR_X        (X_A),
      .CUR_Y        (Y_COORD),
      .HAS_LOCAL    (1'b1),
      .HAS_NORTH    (1'b0),   // nobody is above or below this line
      .HAS_EAST     (1'b1),   // but A has no neighbour to its WEST
      .HAS_WEST     (1'b0),
      .HAS_SOUTH    (1'b0)
  ) u_a (
      .clk                (clk),
      .rst_n              (rst_n),
      .in_flit_data       (a_in_data),
      .in_flit_valid      (a_in_valid),
      .in_vc_id           (a_in_vc),
      .out_flit_data      (a_out_data),
      .out_flit_valid     (a_out_valid),
      .out_vc_id          (a_out_vc),
      .credit_return_valid(a_cred_ret),
      .ds_credit_valid    (a_ds_cred)
  );

  router_top #(
      .NUM_PORTS    (NUM_PORTS),
      .NUM_VC       (NUM_VC),
      .LOCAL_IDX    (LOCAL_IDX),
      .FIFO_DEPTH   (FIFO_DEPTH),
      .LOCAL_CREDITS(LOCAL_CRED),
      .CUR_X        (X_B),
      .CUR_Y        (Y_COORD),
      .HAS_LOCAL    (1'b1),
      .HAS_NORTH    (1'b0),
      .HAS_EAST     (1'b1),
      .HAS_WEST     (1'b1),   // B is the only router with both neighbours
      .HAS_SOUTH    (1'b0)
  ) u_b (
      .clk                (clk),
      .rst_n              (rst_n),
      .in_flit_data       (b_in_data),
      .in_flit_valid      (b_in_valid),
      .in_vc_id           (b_in_vc),
      .out_flit_data      (b_out_data),
      .out_flit_valid     (b_out_valid),
      .out_vc_id          (b_out_vc),
      .credit_return_valid(b_cred_ret),
      .ds_credit_valid    (b_ds_cred)
  );

  router_top #(
      .NUM_PORTS    (NUM_PORTS),
      .NUM_VC       (NUM_VC),
      .LOCAL_IDX    (LOCAL_IDX),
      .FIFO_DEPTH   (FIFO_DEPTH),
      .LOCAL_CREDITS(LOCAL_CRED),
      .CUR_X        (X_C),
      .CUR_Y        (Y_COORD),
      .HAS_LOCAL    (1'b1),
      .HAS_NORTH    (1'b0),
      .HAS_EAST     (1'b0),   // C has no neighbour to its EAST
      .HAS_WEST     (1'b1),
      .HAS_SOUTH    (1'b0)
  ) u_c (
      .clk                (clk),
      .rst_n              (rst_n),
      .in_flit_data       (c_in_data),
      .in_flit_valid      (c_in_valid),
      .in_vc_id           (c_in_vc),
      .out_flit_data      (c_out_data),
      .out_flit_valid     (c_out_valid),
      .out_vc_id          (c_out_vc),
      .credit_return_valid(c_cred_ret),
      .ds_credit_valid    (c_ds_cred)
  );

  //---------------------------------------------------------------
  // 8. Check helpers
  //
  // check() and check_true() come from noc_tb_pkg.
  //---------------------------------------------------------------

  //---------------------------------------------------------------
  // 9. Flit constructors
  //
  // mk_head / mk_ht / mk_body / mk_tail now come from noc_tb_pkg. Their
  // bodies used to be duplicated here and in tb_router_top, guarded by a
  // comment warning that they "must stay identical ... because the chain
  // tests compare a received body against the one that was sent". There is
  // one copy, so the guard has nothing left to enforce.
  //
  // One test-design note survives the move: the route argument of the
  // header is passed but deliberately filled with DIR_LOCAL by every test
  // below. On a LOCAL input port route_compute ignores route_in entirely and
  // computes from the destination, so the injected value is the one thing
  // in the header that must NOT survive to the wire. If the output-port
  // merge ever stopped happening, the header would leave with DIR_LOCAL
  // instead of the next hop and T10 would say so.
  //---------------------------------------------------------------

  //---------------------------------------------------------------
  // 10. Scoreboard
  //
  // Every packet the bench injects gets an entry here. As flits are
  // ejected from a router's LOCAL port they are matched back to their
  // packet and checked. Nothing about arrival ORDER between independent
  // packets is checked -- see the exp_t comment.
  //---------------------------------------------------------------
  exp_t exp_q[$];

  // The scoreboard is only armed for the test that fills it. T10 and the
  // credit-loop test inject packets without registering them -- their
  // expectations are written out by hand in the test itself -- so scoring
  // every ejection unconditionally would report each of those as "a flit
  // nobody injected".
  bit    sb_en = 1'b0;

  // Running totals, so that "is anything left?" and "what did T11 get?" are
  // plain reads instead of a walk of exp_q. sb_outstanding is the number of
  // registered packets that have not yet delivered their last flit; it is
  // incremented where an entry is created and decremented in sb_eject the
  // moment an entry reaches len.
  //
  // The walk this replaces was not just slow -- it was the thing that hung
  // this bench. work_pending() is a function inlined into the coroutine
  // running the tests, and this toolchain hoisted that loop's `i++` out of
  // the loop, so `i` was set once from an uninitialised value and never
  // moved again: the loop spun forever on i == 1. A counter has no loop to
  // miscompile.
  int sb_outstanding = 0;
  int sb_got_flits   = 0;
  int sb_complete    = 0;
  int sb_total_flits = 0;

  // Hop tallies, counted by the receiver as it logs each flit rather than by
  // re-walking the log at the end of the test. Same reason as above: the
  // end-of-test walk was another queue-indexing loop in the coroutine, and
  // these numbers are needed exactly once anyway.
  //
  //   eject_cnt[r] -- flits that left router r on its LOCAL port, i.e. were
  //                   delivered to r's network interface;
  //   east_cnt / west_cnt -- flits that crossed a PRESENT east- or westbound
  //                   link;
  //   bad_port_cnt -- flits seen leaving a port that THIS router has no
  //                   neighbour on: A's west, C's east, anybody's north or
  //                   south. Must be zero -- the chain ties those ports off
  //                   in the DUT, so a flit leaving through one means the
  //                   routing or the tie-off failed, and neither a sum over
  //                   east_cnt + west_cnt nor the scoreboard (which only
  //                   follows packets that arrived) would see it.
  //
  // Presence is restated here rather than read back from the DUT instances
  // because the `HAS_*` parameters are constants on those instances and
  // their elaborated values are not reachable from bench code.
  localparam bit HAS_EAST_P [N_RTR] = '{1'b1, 1'b1, 1'b0};   // A, B, C
  localparam bit HAS_WEST_P [N_RTR] = '{1'b0, 1'b1, 1'b1};
  int eject_cnt  [N_RTR];
  int east_cnt   = 0;
  int west_cnt   = 0;
  int bad_port_cnt = 0;

  task automatic sb_eject(input int rtr, input logic [FLIT_W-1:0] data);
    logic [TAG_W-1:0] t;
    int          idx;
    int          pos;
    exp_t        pe;
    logic [1:0]  typ;

    t   = flit_tag(data);
    idx = -1;
    for (int i = 0; i < exp_q.size(); i++) begin
      if (exp_q[i].tag == t) begin
        idx = i;
        break;
      end
    end

    if (idx < 0) begin
      checks++;
      $display("[FAIL] %-64s tag %h at router %0d", "scoreboard: flit nobody injected",
               t, rtr);
      errors++;
      return;
    end

    // Read the entry, check it, write the whole thing back: one queue, one
    // computed index, no in-place field write on a queue element.
    pe   = exp_q[idx];
    pos  = pe.got;
    typ  = flit_type(data);

    if (pos >= pe.len) begin
      checks++;
      $display("[FAIL] %-64s tag %h router %0d", "scoreboard: more flits than sent",
               t, rtr);
      errors++;
      return;
    end

    // -- landed at the right router -----------------------------------
    checks++;
    if (pe.dest != rtr) begin
      $display("[FAIL] %-64s tag %h got router %0d exp %0d",
               "scoreboard: ejected at the wrong router", t, rtr, pe.dest);
      errors++;
    end

    // -- position within the packet ------------------------------------
    // HEAD, then BODY*, then TAIL -- or a lone HEAD_TAIL for a one-flit
    // packet. Checked by index rather than by arrival order, because the
    // log holds every hop of every packet mixed together.
    begin
      bit type_ok;
      type_ok = 1'b1;
      if (pe.len == 1)      type_ok = (typ == FLIT_HEAD_TAIL);
      else if (pos == 0)    type_ok = (typ == FLIT_HEAD);
      else if (pos == pe.len - 1) type_ok = (typ == FLIT_TAIL);
      else                  type_ok = (typ == FLIT_BODY);
      checks++;
      if (!type_ok) begin
        $display("[FAIL] %-64s tag %h pos %0d/%0d type %b",
                 "scoreboard: flit type sequence broken", t, pos, pe.len, typ);
        errors++;
      end
    end

    // -- header destination fields still name the real destination ------
    // Only a head carries them, and they must be the same after two hops
    // as they were at injection: nothing in the design is allowed to touch
    // them, and the merge is confined to the route field.
    if ((pe.len == 1) || (pos == 0)) begin
      checks++;
      if ((flit_dst_x(data) != 3'(pe.dest)) || (flit_dst_y(data) != Y_COORD)) begin
        $display("[FAIL] %-64s tag %h dx %0d dy %0d exp dx %0d dy %0d",
                 "scoreboard: header destination corrupted", t, flit_dst_x(data),
                 flit_dst_y(data), pe.dest, Y_COORD);
        errors++;
      end

      // -- the two header fields the merge is allowed to reach ----------
      // The route field, and at a packet's own destination the lookahead
      // the terminating router wrote into it must read DIR_LOCAL -- that is
      // the field telling the network interface "this is yours".
      // KIND is written once by the source NI. Routers are not its
      // consumer, so it must come out of two hops byte-identical to what was
      // injected -- which is the whole content of assumption D3 now that the
      // field is no longer a VC.
      checks++;
      if (flit_route(data) != DIR_LOCAL) begin
        $display("[FAIL] %-64s tag %h route %b", "scoreboard: ejected route field",
                 t, flit_route(data));
        errors++;
      end
      checks++;
      if (flit_kind(data) != 2'(pe.kind)) begin
        $display("[FAIL] %-64s tag %h kind %b exp %b",
                 "scoreboard: header KIND field rewritten", t, flit_kind(data), 2'(pe.kind));
        errors++;
      end
    end

    // -- tally ---------------------------------------------------------
    // Counters rather than a second scan: the watchdog calls work_pending()
    // every clock edge, so "is anything left" must be O(1). It also keeps
    // queue indexing out of the coroutine that runs the tests -- see the
    // work_pending() comment for why that mattered.
    sb_got_flits++;
    pe.got = pos + 1;
    exp_q[idx] = pe;
    if (pe.got == pe.len) begin
      sb_complete++;
      sb_outstanding--;
    end
  endtask

  // Outstanding work, as the watchdog sees it: either something is still
  // queued for injection, or some registered packet has not delivered its
  // last flit yet.
  //
  // Deliberately a pair of counter reads. This is called on every clock edge
  // by the watchdog and on every iteration of wait_idle(), so it must be O(1)
  // -- and it must contain no queue-indexing loop, because the loop it used
  // to contain was miscompiled into an infinite one (see sb_outstanding).
  function automatic bit work_pending();
    return (tx_q.size() > 0) || (sb_outstanding > 0);
  endfunction

  //---------------------------------------------------------------
  // 11. Receiver: log every flit leaving any router, on any port
  //
  // Positional push order is router-major, port-minor, but only within one
  // cycle. Tests identify flits by tag rather than by slot, so packets
  // leaving different routers on the same cycle can never be confused.
  //---------------------------------------------------------------
  rx_t rx[$];

  always @(posedge clk) begin : rx_logger
    rx_t e;
    if (rst_n) begin
      for (int r = 0; r < N_RTR; r++) begin
        for (int o = 0; o < NUM_PORTS; o++) begin
          if (r_out_valid[r][o]) begin
            // Built field by field rather than as an assignment pattern:
            // this toolchain does not accept '{...} as an argument.
            e.rtr  = r;
            e.port = o;
            e.vc   = int'(r_out_vc[r][o]);
            e.cyc  = cyc;
            e.data = r_out_data[r][o];
            rx.push_back(e);
            // Hop tallies. Only LOCAL, EAST and WEST carry anything in this
            // chain -- NORTH and SOUTH are absent on all three routers, and
            // EAST/WEST are absent at the ends -- so a flit leaving through
            // a port THIS router does not have is counted as bad and T11 can
            // prove no flit ever tried.
            if (o == LOCAL_IDX) eject_cnt[r]++;
            else if (o == EAST_IDX) begin
              if (HAS_EAST_P[r]) east_cnt++; else bad_port_cnt++;
            end
            else if (o == WEST_IDX) begin
              if (HAS_WEST_P[r]) west_cnt++; else bad_port_cnt++;
            end
            else bad_port_cnt++;
            // A flit that just reached its destination's network interface
            // is scored immediately, so a wrong route is reported at the
            // cycle it happens rather than at the end of the test.
            if ((o == LOCAL_IDX) && sb_en) sb_eject(r, e.data);
          end
        end
      end
    end
  end

  task automatic clear_rx();
    rx.delete();
    for (int r = 0; r < N_RTR; r++) eject_cnt[r] = 0;
    east_cnt     = 0;
    west_cnt     = 0;
    bad_port_cnt = 0;
  endtask

  function automatic int rx_n();
    return rx.size();
  endfunction

  function automatic logic [TAG_W-1:0] rx_tag(input int i);
    return flit_tag(rx[i].data);
  endfunction

  function automatic logic [1:0] rx_type(input int i);
    return flit_type(rx[i].data);
  endfunction

  // The route field of a header as it appears on a link. A single router
  // never consumes its own outgoing route field, so this is how the merge
  // -- the lookup the NEXT router will do -- is observed from outside.
  function automatic logic [3:0] rx_route(input int i);
    return flit_route(rx[i].data);
  endfunction

  // How many logged flits of `tag` went out of router `rtr` on port `port`.
  function automatic int hop_n(input int rtr, input int port, input logic [TAG_W-1:0] tag);
    int n;
    n = 0;
    for (int i = 0; i < rx.size(); i++) begin
      if ((rx[i].rtr == rtr) && (rx[i].port == port) && (flit_tag(rx[i].data) == tag)) n++;
    end
    return n;
  endfunction

  // Largest cycle-to-cycle gap between consecutive flits of `tag` on one
  // (router, port) pair. 1 means they left back to back, i.e. the link ran
  // at one flit per cycle; 2 or more means somebody stalled.
  function automatic int max_gap(input int rtr, input int port, input logic [TAG_W-1:0] tag);
    int last;
    int g;
    int m;
    last = -1;
    m    = 0;
    for (int i = 0; i < rx.size(); i++) begin
      if ((rx[i].rtr == rtr) && (rx[i].port == port) && (flit_tag(rx[i].data) == tag)) begin
        if (last >= 0) begin
          g = rx[i].cyc - last;
          if (g > m) m = g;
        end
        last = rx[i].cyc;
      end
    end
    return m;
  endfunction

  // Index of the first logged flit of `tag` (anywhere); -1 if absent.
  function automatic int find_tag(input logic [TAG_W-1:0] tag);
    for (int i = 0; i < rx.size(); i++) begin
      if (flit_tag(rx[i].data) == tag) return i;
    end
    return -1;
  endfunction

  //---------------------------------------------------------------
  // 12. NI ejection credit pipe (section 6)
  //
  // One pipe per router. A flit on a router's LOCAL output puts a credit in
  // stage 0 of that router's pipe at the posedge that closes the cycle, and
  // from there it is wired straight into that router's ds_credit_valid
  // [LOCAL]. The arbiter counts it at the following posedge, so the total
  // from "flit on the wire" to "credit usable" is two cycles -- section 6's
  // "registered credit return visible g+2, usable g+3" measured from a flit
  // that went out at g+1.
  //
  // NI_LAT exists so that number can be moved. It is 0 here on purpose, and
  // the reason is worth stating because it is not obvious: at NI_LAT = 0 the
  // loop is three cycles against four credits and full rate holds with a
  // credit to spare; at NI_LAT = 1 it is four against four and still holds,
  // but exactly on the boundary; at NI_LAT = 2 it is five against four and
  // the fourth flit of any back-to-back run stalls for one cycle. The
  // section 6 test below is the thing that noticed.
  //---------------------------------------------------------------
  logic [N_RTR-1:0][NI_LAT:0][NUM_VC-1:0] ni_pipe;

  always @(posedge clk) begin : ni_credit_pipe
    if (!rst_n) begin
      ni_pipe <= '0;
    end else begin
      for (int r = 0; r < N_RTR; r++) begin
        ni_pipe[r][0] <= '0;
        for (int k = 0; k < NUM_VC; k++) begin
          // Indexed by an explicit compare rather than by the 2-bit sideband
          // directly: the row index is clog2(NUM_VC) wide and an out-of-range
          // value would select past the end.
          if (r_out_valid[r][LOCAL_IDX] && (r_out_vc[r][LOCAL_IDX] == VC_W'(k))) begin
            ni_pipe[r][0][k] <= 1'b1;
          end
        end
        for (int s = 1; s <= NI_LAT; s++) ni_pipe[r][s] <= ni_pipe[r][s-1];
      end
    end
  end

  //---------------------------------------------------------------
  // 13. ds_credit_valid assembly
  //
  // One continuous process builds all three arrays, so each has exactly one
  // driver. Two kinds of source, and they are not interchangeable:
  //
  //  * a directional output's credits come from the neighbour's input port
  //    that receives them -- the literal wires of section 6, A to B and back;
  //  * a LOCAL output's credits come from the NI pipe above.
  //
  // Absent ports (NORTH and SOUTH everywhere, WEST at A, EAST at C) are left
  // at zero by the default, which is what router_top's "no credit on a link
  // that does not exist" assertion expects.
  //---------------------------------------------------------------
  always_comb begin : ds_credit_assembly
    a_ds_cred = '0;
    b_ds_cred = '0;
    c_ds_cred = '0;

    // A's east link is fed by B's WEST input port, and vice versa.
    a_ds_cred[EAST_IDX]  = b_cred_ret[WEST_IDX];
    b_ds_cred[WEST_IDX]  = a_cred_ret[EAST_IDX];

    // The same pair between B and C.
    b_ds_cred[EAST_IDX]  = c_cred_ret[WEST_IDX];
    c_ds_cred[WEST_IDX]  = b_cred_ret[EAST_IDX];

    // Ejection, from the NI pipe.
    a_ds_cred[LOCAL_IDX] = ni_pipe[0][NI_LAT];
    b_ds_cred[LOCAL_IDX] = ni_pipe[1][NI_LAT];
    c_ds_cred[LOCAL_IDX] = ni_pipe[2][NI_LAT];
  end

  //---------------------------------------------------------------
  // 14. Link wiring and LOCAL injection driver
  //
  // One negedge process owns every router's incoming-link arrays -- there
  // is no second driver anywhere, so no element of them can ever be written
  // from two places. Each cycle it:
  //
  //   1. settles the credits the routers returned during the cycle that is
  //      ending (reading them at the negedge keeps the count exact instead
  //      of one cycle conservative, same reasoning as tb_router_top);
  //   2. zeroes the arrays and re-copies the neighbour's registered outputs
  //      into the directional input ports. The neighbour's output only
  //      changes at a posedge, so what is copied at this negedge is exactly
  //      the value the receiving router will sample at the next posedge --
  //      a wire would deliver the same bit, so the link adds no latency;
  //   3. pushes the oldest queued flit for each router onto that router's
  //      LOCAL port while its inflight budget allows.
  //---------------------------------------------------------------
  int  inj_inflight [N_RTR][NUM_VC];

  int  drv_idx;
  int  drv_vc;

  initial begin
    rst_n      = 1'b0;
    a_in_data  = '0;  a_in_valid = '0;  a_in_vc = '0;
    b_in_data  = '0;  b_in_valid = '0;  b_in_vc = '0;
    c_in_data  = '0;  c_in_valid = '0;  c_in_vc = '0;
    for (int r = 0; r < N_RTR; r++) begin
      for (int k = 0; k < NUM_VC; k++) inj_inflight[r][k] = 0;
    end
  end

  // Push a flit onto a router's LOCAL injection queue.
  task automatic send(input int rtr, input logic [FLIT_W-1:0] data, input logic [VC_W-1:0] vc);
    tx_t t;
    // The guard reads the whole index rather than letting it decay into an
    // array subscript, and it turns a mistyped router number in a test into
    // a reported failure instead of a silently indexed queue.
    if ((rtr < 0) || (rtr >= N_RTR)) begin
      $display("[FAIL] send(): router %0d out of range 0..%0d", rtr, N_RTR - 1);
      errors++;
      return;
    end
    t.rtr  = rtr;
    t.vc   = vc;
    t.data = data;
    // One shared queue, destination carried in the entry (see the tx_t
    // comment): a per-router array of queues does not survive a variable
    // index in this simulator.
    tx_q.push_back(t);
  endtask

  always @(negedge clk) begin : link_and_inject
    if (!rst_n) begin
      a_in_data = '0;  a_in_valid = '0;  a_in_vc = '0;
      b_in_data = '0;  b_in_valid = '0;  b_in_vc = '0;
      c_in_data = '0;  c_in_valid = '0;  c_in_vc = '0;
      for (int r = 0; r < N_RTR; r++) begin
        for (int k = 0; k < NUM_VC; k++) inj_inflight[r][k] = 0;
      end
    end else begin
      // -- 1. settle credits -----------------------------------------
      for (int r = 0; r < N_RTR; r++) begin
        for (int k = 0; k < NUM_VC; k++) begin
          if (r_cred_ret[r][LOCAL_IDX][k] && (inj_inflight[r][k] > 0)) begin
            inj_inflight[r][k]--;
          end
        end
      end

      // -- 2. defaults, then the four inter-router wires -------------
      a_in_data = '0;  a_in_valid = '0;  a_in_vc = '0;
      b_in_data = '0;  b_in_valid = '0;  b_in_vc = '0;
      c_in_data = '0;  c_in_valid = '0;  c_in_vc = '0;

      // B's WEST output lands on A's EAST input, and B's own EAST input
      // hears C's WEST output. The remaining two wires are A's EAST output
      // (into B's WEST input) and B's EAST output (into C's WEST input),
      // copied below at the driving side.
      a_in_data[EAST_IDX]  = b_out_data[WEST_IDX];
      a_in_valid[EAST_IDX] = b_out_valid[WEST_IDX];
      a_in_vc[EAST_IDX]    = b_out_vc[WEST_IDX];

      b_in_data[WEST_IDX]  = a_out_data[EAST_IDX];
      b_in_valid[WEST_IDX] = a_out_valid[EAST_IDX];
      b_in_vc[WEST_IDX]    = a_out_vc[EAST_IDX];

      b_in_data[EAST_IDX]  = c_out_data[WEST_IDX];
      b_in_valid[EAST_IDX] = c_out_valid[WEST_IDX];
      b_in_vc[EAST_IDX]    = c_out_vc[WEST_IDX];

      c_in_data[WEST_IDX]  = b_out_data[EAST_IDX];
      c_in_valid[WEST_IDX] = b_out_valid[EAST_IDX];
      c_in_vc[WEST_IDX]    = b_out_vc[EAST_IDX];

      // -- 3. injection at each LOCAL port ---------------------------
      // The oldest queued flit for this router. The linear scan preserves
      // arrival order, so a router can never overtake its own earlier
      // packet, and it keeps every queue index a plain variable read of
      // the one shared queue.
      for (int r = 0; r < N_RTR; r++) begin
        drv_idx = -1;
        for (int i = 0; i < tx_q.size(); i++) begin
          if (tx_q[i].rtr == r) begin
            drv_idx = i;
            break;
          end
        end
        if (drv_idx >= 0) begin
          drv_vc = tx_q[drv_idx].vc;
          // The sideband is wider than NUM_VC needs. Making the range check
          // explicit keeps every bit of the index observable and stops a
          // malformed sideband from selecting past the end of inj_inflight.
          if (drv_vc >= NUM_VC) begin
            $display("[FAIL] tx driver saw out-of-range vc_id %0d on router %0d",
                     drv_vc, r);
            errors++;
          end else if (inj_inflight[r][drv_vc] < FIFO_DEPTH) begin
            case (r)
              0: begin
                a_in_data[LOCAL_IDX]  = tx_q[drv_idx].data;
                a_in_valid[LOCAL_IDX] = 1'b1;
                a_in_vc[LOCAL_IDX]    = VC_W'(tx_q[drv_idx].vc);
              end
              1: begin
                b_in_data[LOCAL_IDX]  = tx_q[drv_idx].data;
                b_in_valid[LOCAL_IDX] = 1'b1;
                b_in_vc[LOCAL_IDX]    = VC_W'(tx_q[drv_idx].vc);
              end
              default: begin
                c_in_data[LOCAL_IDX]  = tx_q[drv_idx].data;
                c_in_valid[LOCAL_IDX] = 1'b1;
                c_in_vc[LOCAL_IDX]    = VC_W'(tx_q[drv_idx].vc);
              end
            endcase
            inj_inflight[r][drv_vc]++;
            tx_q.delete(drv_idx);
          end
        end
      end
    end
  end

  //---------------------------------------------------------------
  // 15. Deadlock watchdog
  //
  // Armed whenever work is outstanding. Work is outstanding while anything
  // is queued for injection or while some packet still owes flits, so a
  // credit loop that wedges, a router that stops granting, or a flit that
  // simply vanishes all end here instead of hanging the run. The counter
  // resets on any observed arrival, so a slow but moving test never trips
  // it; only a genuinely motionless one does.
  //---------------------------------------------------------------
  int  last_rx_n  = 0;
  int  stall_cnt  = 0;
  bit  deadlock_seen = 1'b0;

  always @(negedge clk) begin : watchdog
    if (!rst_n) begin
      stall_cnt     = 0;
      last_rx_n     = 0;
      deadlock_seen = 1'b0;
    end else begin
      if (rx_n() != last_rx_n) stall_cnt = 0;
      else stall_cnt++;
      last_rx_n = rx_n();

      if (!deadlock_seen && work_pending() && (stall_cnt > MAX_STALL)) begin
        deadlock_seen = 1'b1;
        checks++;
        $display("[FAIL] %-64s", "deadlock: no flit moved for 500 cycles");
        $display("        queued for injection : %0d", tx_q.size());
        for (int i = 0; i < exp_q.size(); i++) begin
          if (exp_q[i].got < exp_q[i].len) begin
            $display("        tag %h got %0d/%0d", exp_q[i].tag,
                     exp_q[i].got, exp_q[i].len);
          end
        end
        errors++;
      end
    end
  end

  //---------------------------------------------------------------
  // 16. Wait helpers
  //---------------------------------------------------------------

  // Run until nothing has been queued AND nothing new has arrived for
  // `quiet` cycles, or until the budget runs out. The quiet window is what
  // makes this safe across two hops: the queue empties long before the last
  // flit reaches its destination, so stopping at "queue empty" would score
  // the run while half the traffic was still in flight.
  task automatic drain(input int max_cycles);
    int n;
    int quiet;
    int prev;
    n     = 0;
    quiet = 0;
    prev  = -1;
    while ((n < max_cycles) && (quiet < 32)) begin
      @(negedge clk);
      n++;
      if ((tx_q.size() == 0) && (rx_n() == prev)) quiet++;
      else quiet = 0;
      prev = rx_n();
    end
    check_true($sformatf("drain settled within %0d cycles", max_cycles),
               (tx_q.size() == 0) && (quiet >= 32));
  endtask

  // Run until the scoreboard is fully paid, or give up. Used by T11, where
  // "everything arrived" is the actual pass condition rather than an
  // inference from a quiet link.
  task automatic wait_idle(input int max_cycles);
    int n;
    n = 0;
    while (work_pending() && (n < max_cycles)) begin
      @(negedge clk);
      n++;
    end
    check_true($sformatf("all traffic settled within %0d cycles", max_cycles),
               !work_pending());
  endtask

  task automatic settle();
    repeat (12) @(negedge clk);
  endtask

  //---------------------------------------------------------------
  // 17. Tests
  //---------------------------------------------------------------

  // T10 (a): one HEAD_TAIL, A -> C, two hops away.
  //
  // This is the route_next test proper. The injected header carries
  // DIR_LOCAL -- a value that is wrong on purpose, because on a LOCAL input
  // port route_compute computes the exit direction from the destination and
  // never reads the field. So every DIR_EAST or DIR_LOCAL that shows up on
  // a link afterwards was written there by somebody's output port, and:
  //
  //   A must write DIR_EAST  -- B is east of A, and dest (2,1) is further
  //                            east still, so B's next move is east;
  //   B must write DIR_LOCAL -- C IS the destination, so the packet
  //                            terminates there;
  //   C must eject it.
  //
  // A chain of exactly two hops is the shortest thing that can show the
  // second of those: a single router writes a route field and then discards
  // it, so there is no way to observe from inside one router that the field
  // it produced was the one the next router needed.
  task automatic t10a_two_hop_head_tail();
    logic [TAG_W-1:0] tag;
    int i0, i1, i2;

    clear_rx();
    tag = 18'hA_2001;
    send(0, mk_ht(X_C, Y_COORD, DIR_LOCAL, 2'd0, tag), VC_W'(0));
    drain(400);

    check("T10a one flit logged across the whole line", rx_n(), 3);
    if (rx_n() >= 3) begin
      i0 = 0;
      i1 = 1;
      i2 = 2;

      // Hop 1: A's east link.
      check("T10a hop 1 left router A", rx[i0].rtr, 0);
      check("T10a hop 1 left via EAST", rx[i0].port, EAST_IDX);
      check("T10a hop 1 type", rx_type(i0), FLIT_HEAD_TAIL);
      check("T10a hop 1 payload survived", rx_tag(i0), tag);
      check("T10a hop 1 route field is B's next hop", rx_route(i0), DIR_EAST);

      // Hop 2: B's east link. The field must have been re-written, not
      // copied through: B's own decision is EAST, but what C needs to hear
      // is "you are the destination".
      check("T10a hop 2 left router B", rx[i1].rtr, 1);
      check("T10a hop 2 left via EAST", rx[i1].port, EAST_IDX);
      check("T10a hop 2 type", rx_type(i1), FLIT_HEAD_TAIL);
      check("T10a hop 2 payload survived", rx_tag(i1), tag);
      check("T10a hop 2 route field is C's next hop", rx_route(i1), DIR_LOCAL);

      // Hop 3: ejection at C's network interface.
      check("T10a ejected at router C", rx[i2].rtr, 2);
      check("T10a ejected via LOCAL", rx[i2].port, LOCAL_IDX);
      check("T10a type at the receiver", rx_type(i2), FLIT_HEAD_TAIL);
      check("T10a payload intact end to end", rx_tag(i2), tag);
    end
  endtask


  // T10 (b): the same trip in the other direction, C -> A.
  //
  // route_compute corrects X before Y, so the WEST walk is a separate code
  // path from the EAST one (compute_dir's `tgt_x > cur_x` branch), and B's
  // lookahead has to come out of it pointing WEST into A rather than east
  // into C. Sending from the far end also proves the chain is not relying
  // on A happening to be first.
  task automatic t10b_two_hop_reverse();
    logic [TAG_W-1:0] tag;
    int i0, i1, i2;

    clear_rx();
    tag = 18'hB_2002;
    send(2, mk_ht(X_A, Y_COORD, DIR_LOCAL, 2'd0, tag), VC_W'(0));
    drain(400);

    check("T10b one flit logged across the whole line", rx_n(), 3);
    if (rx_n() >= 3) begin
      i0 = 0;
      i1 = 1;
      i2 = 2;

      check("T10b hop 1 left router C", rx[i0].rtr, 2);
      check("T10b hop 1 left via WEST", rx[i0].port, WEST_IDX);
      check("T10b hop 1 route field is B's next hop", rx_route(i0), DIR_WEST);
      check("T10b hop 1 payload survived", rx_tag(i0), tag);

      check("T10b hop 2 left router B", rx[i1].rtr, 1);
      check("T10b hop 2 left via WEST", rx[i1].port, WEST_IDX);
      check("T10b hop 2 route field is A's next hop", rx_route(i1), DIR_LOCAL);
      check("T10b hop 2 payload survived", rx_tag(i1), tag);

      check("T10b ejected at router A", rx[i2].rtr, 0);
      check("T10b ejected via LOCAL", rx[i2].port, LOCAL_IDX);
      check("T10b payload intact end to end", rx_tag(i2), tag);
    end
  endtask


  // T10 (c): a four-flit packet through both hops.
  //
  // Three things a single-flit test cannot see:
  //
  //  * the merge must happen once per hop, on the head only, and re-write a
  //    DIFFERENT value at each hop (EAST at A, LOCAL at B) -- so the head is
  //    checked at all three routers, not just counted;
  //  * BODY and TAIL must come out of two consecutive output ports
  //    bit-for-bit identical to what was sent. They are compared against the
  //    constructors directly, at both hops, which is what catches the merge
  //    being applied to every flit rather than to heads;
  //  * all four flits must stay together: no hop may drop one, duplicate
  //    one, or let one take a different route than the rest of its packet.
  task automatic t10c_two_hop_multi_flit();
    logic [TAG_W-1:0] tag;
    logic [FLIT_W-1:0] sent_body;
    logic [FLIT_W-1:0] sent_tail;
    int base;

    clear_rx();
    tag       = 18'hC_2003;
    sent_body = mk_body(tag);
    sent_tail = mk_tail(tag);

    send(0, mk_head(X_C, Y_COORD, DIR_LOCAL, 2'd0, tag), VC_W'(0));
    send(0, mk_body(tag), VC_W'(0));
    send(0, mk_body(tag), VC_W'(0));
    send(0, mk_tail(tag), VC_W'(0));
    drain(600);

    check("T10c four flits at every hop (12 logged)", rx_n(), 12);
    if (rx_n() >= 12) begin
      // ---- hop 1: A's east link, indices 0..3 ---------------------
      for (int i = 0; i < 4; i++) begin
        check($sformatf("T10c hop1 flit %0d left router A", i), rx[i].rtr, 0);
        check($sformatf("T10c hop1 flit %0d left via EAST", i), rx[i].port, EAST_IDX);
      end
      check("T10c hop1 HEAD type", rx_type(0), FLIT_HEAD);
      check("T10c hop1 BODY type", rx_type(1), FLIT_BODY);
      check("T10c hop1 BODY type", rx_type(2), FLIT_BODY);
      check("T10c hop1 TAIL type", rx_type(3), FLIT_TAIL);
      check("T10c hop1 HEAD route is B's next hop", rx_route(0), DIR_EAST);
      check("T10c hop1 BODY unmodified", rx[1].data, sent_body);
      check("T10c hop1 BODY unmodified", rx[2].data, sent_body);
      check("T10c hop1 TAIL unmodified", rx[3].data, sent_tail);

      // ---- hop 2: B's east link, indices 4..7 ---------------------
      base = 4;
      for (int i = 0; i < 4; i++) begin
        check($sformatf("T10c hop2 flit %0d left router B", i), rx[base+i].rtr, 1);
        check($sformatf("T10c hop2 flit %0d left via EAST", i), rx[base+i].port, EAST_IDX);
      end
      check("T10c hop2 HEAD type", rx_type(base+0), FLIT_HEAD);
      check("T10c hop2 TAIL type", rx_type(base+3), FLIT_TAIL);
      // The value changed between the two hops: A wrote B's move, B wrote
      // "terminate here". If the field were simply forwarded, hop 2 would
      // still read EAST and this would fail.
      check("T10c hop2 HEAD route is C's next hop", rx_route(base+0), DIR_LOCAL);
      check("T10c hop2 BODY unmodified", rx[base+1].data, sent_body);
      check("T10c hop2 BODY unmodified", rx[base+2].data, sent_body);
      check("T10c hop2 TAIL unmodified", rx[base+3].data, sent_tail);

      // ---- hop 3: ejection at C, indices 8..11 --------------------
      base = 8;
      for (int i = 0; i < 4; i++) begin
        check($sformatf("T10c ejected flit %0d at router C", i), rx[base+i].rtr, 2);
        check($sformatf("T10c ejected flit %0d via LOCAL", i), rx[base+i].port, LOCAL_IDX);
      end
      check("T10c ejected HEAD type", rx_type(base+0), FLIT_HEAD);
      check("T10c ejected BODY type", rx_type(base+1), FLIT_BODY);
      check("T10c ejected BODY type", rx_type(base+2), FLIT_BODY);
      check("T10c ejected TAIL type", rx_type(base+3), FLIT_TAIL);
      check("T10c ejected HEAD route", rx_route(base+0), DIR_LOCAL);
      check("T10c payload intact end to end", rx_tag(base+0), tag);
      check("T10c BODY unmodified after two hops", rx[base+1].data, sent_body);
      check("T10c TAIL unmodified after two hops", rx[base+3].data, sent_tail);
    end
  endtask


  // T10 (d) and (e): the one-hop legs, and a packet that never leaves the
  // middle router's own line.
  //
  // A -> B ends with route_next = DIR_LOCAL computed at A, so the whole
  // "lookahead says terminate" case happens in one hop instead of two; B -> A
  // and B -> C cover the two directions from the middle router, which is the
  // only instance with a neighbour on both sides and therefore the one whose
  // WEST and EAST inputs are exercised together.
  task automatic t10d_single_hop_legs();
    logic [TAG_W-1:0] t_ab, t_ba, t_bc;
    int i;

    clear_rx();
    t_ab = 18'hD_2011;   // A -> B
    t_ba = 18'hD_2012;   // B -> A
    t_bc = 18'hD_2013;   // B -> C
    send(0, mk_ht(X_B, Y_COORD, DIR_LOCAL, 2'd0, t_ab), VC_W'(0));
    send(1, mk_ht(X_A, Y_COORD, DIR_LOCAL, 2'd0, t_ba), VC_W'(0));
    send(1, mk_ht(X_C, Y_COORD, DIR_LOCAL, 2'd0, t_bc), VC_W'(0));
    drain(400);

    check("T10d three one-hop packets (6 logged)", rx_n(), 6);

    if (rx_n() >= 6) begin
      // A -> B: out of A on EAST, then straight into B's LOCAL.
      i = find_tag(t_ab);
      check_true("T10d A->B left router A via EAST",
                 (i >= 0) && (rx[i].rtr == 0) && (rx[i].port == EAST_IDX));
      check_true("T10d A->B route field says terminate at B",
                 (i >= 0) && (rx_route(i) == DIR_LOCAL));
      check_true("T10d A->B ejected at B",
                 (hop_n(1, LOCAL_IDX, t_ab) == 1) && (hop_n(0, EAST_IDX, t_ab) == 1));

      // B -> A: out of B on WEST, into A's LOCAL.
      i = find_tag(t_ba);
      check_true("T10d B->A left router B via WEST",
                 (i >= 0) && (rx[i].rtr == 1) && (rx[i].port == WEST_IDX));
      check_true("T10d B->A ejected at A",
                 (hop_n(0, LOCAL_IDX, t_ba) == 1) && (hop_n(1, WEST_IDX, t_ba) == 1));

      // B -> C: out of B on EAST, into C's LOCAL. Same router as A->B but
      // the other directional output, so both of B's links are covered.
      i = find_tag(t_bc);
      check_true("T10d B->C left router B via EAST",
                 (i >= 0) && (rx[i].rtr == 1) && (rx[i].port == EAST_IDX));
      check_true("T10d B->C ejected at C",
                 (hop_n(2, LOCAL_IDX, t_bc) == 1) && (hop_n(1, EAST_IDX, t_bc) == 1));

      // Nothing wandered: no packet may appear on a port it should not use,
      // and NORTH/SOUTH are not even wired on this line.
      for (int k = 0; k < rx_n(); k++) begin
        check_true($sformatf("T10d flit %0d never used an unwired port", k),
                   (rx[k].port == LOCAL_IDX) || (rx[k].port == EAST_IDX) ||
                   (rx[k].port == WEST_IDX));
      end
    end
  endtask


  // Section 6 credit loop, confirmed on the chain.
  //
  // One 16-flit packet, one VC, from A all the way to C. Every hop must then
  // run at exactly one flit per cycle -- a gap of 2 or more anywhere means
  // the credits ran out before the return loop closed.
  //
  // The interesting hop is C's ejection. Directional outputs hold
  // FIFO_DEPTH = 8 credits against a loop of about 4, which is never going
  // to run dry. The LOCAL output is the tight one: LOCAL_CREDITS = 4 against
  // a loop of 3 (NI_LAT = 0), which is the balance section 6 describes as
  // sustainable. It is tight enough that the model matters -- running this
  // same test with the NI credit return delayed by two more cycles stalled
  // the fourth flit and turned this last max_gap into 2, which is exactly
  // the failure mode the section warns about ("extra link pipeline stages
  // lengthen it and may need more credits").
  task automatic t_credit_loop_full_rate();
    logic [TAG_W-1:0] tag;

    clear_rx();
    tag = 18'hF_3001;
    send(0, mk_head(X_C, Y_COORD, DIR_LOCAL, 2'd0, tag), VC_W'(0));
    for (int i = 0; i < PKT_FLITS - 2; i++) send(0, mk_body(tag), VC_W'(0));
    send(0, mk_tail(tag), VC_W'(0));
    drain(800);

    check("CL every flit reached A's east link", hop_n(0, EAST_IDX, tag), PKT_FLITS);
    check("CL every flit crossed B's east link", hop_n(1, EAST_IDX, tag), PKT_FLITS);
    check("CL every flit was ejected at C", hop_n(2, LOCAL_IDX, tag), PKT_FLITS);
    check("CL nothing else left the line", rx_n(), 3 * PKT_FLITS);

    check("CL A->B ran at one flit per cycle", max_gap(0, EAST_IDX, tag), 1);
    check("CL B->C ran at one flit per cycle", max_gap(1, EAST_IDX, tag), 1);
    check("CL ejection at C ran at one flit per cycle", max_gap(2, LOCAL_IDX, tag), 1);
  endtask


  // T11: random traffic with a scoreboard, then the deadlock watchdog.
  //
  // Three sources, random destinations (always one of the OTHER two
  // routers -- XY with dest == this router is DIR_LOCAL on a LOCAL input,
  // which section 2's legality table does not list as a legal LOCAL pair),
  // random packet lengths of 1..6 flits and both VCs. Roughly 36 packets
  // and well over a hundred flits, mixed so that the middle router is
  // simultaneously forwarding in both directions.
  //
  // What the scoreboard proves per packet: it arrives at the right router,
  // once, with HEAD/BODY*/TAIL in order and the destination fields
  // untouched. What it deliberately does not prove: the order of two
  // independent packets. An intermediate hop may allocate them different
  // output VCs and they may overtake each other -- that is what virtual
  // channels are for, so it is not a bug and the scoreboard does not claim
  // it. Within a packet the order is checked, because that has to hold.
  //
  // The watchdog runs throughout: if a credit loop wedges under this load,
  // the run fails with the outstanding packets named instead of hanging.
  task automatic t11_random_traffic();
    int src;
    int dest;
    int len;
    int vc;
    int kind;
    int sent;
    int n_ht;
    int exp_hops;
    exp_t pe;
    logic [TAG_W-1:0] tag;

    clear_rx();
    exp_q.delete();
    sb_reset();
    sb_en = 1'b1;
    sent = 0;
    n_ht = 0;
    exp_hops = 0;

    for (int s = 0; s < 12; s++) begin
      for (src = 0; src < N_RTR; src++) begin
        len = $urandom_range(1, 6);
        // Destination: any router except the source itself.
        dest = $urandom_range(0, 1);
        if (dest >= src) dest++;
        vc   = $urandom_range(0, NUM_VC - 1);
        // Derived rather than drawn from the RNG: a fourth $urandom_range
        // here would shift every subsequent len/dest/vc draw and quietly
        // change the traffic this test has always run, which would make "did
        // the KIND change break anything" unanswerable. src/dest/len move
        // enough between packets to exercise all four encodings anyway.
        kind = (src + dest + len) % 4;     // 00 WR_REQ .. 11 RD_RESP
        tag = tag_seq;
        tag_seq = tag_seq + 18'd1;

        pe.tag  = tag;
        pe.src  = src;
        pe.dest = dest;
        pe.len  = len;
        pe.vc   = vc;
        pe.kind = kind;
        pe.got  = 0;
        exp_q.push_back(pe);
        sb_outstanding++;
        sb_total_flits += len;
        // Every flit of this packet crosses |dest-src| links -- XY in a
        // straight line never detours -- and is then ejected on exactly one
        // LOCAL port. That is |dest-src| + 1 logged hops per flit, so the
        // whole run's log length is known in advance rather than merely
        // bounded.
        exp_hops += len * ((dest > src ? dest - src : src - dest) + 1);

        if (len == 1) begin
          send(src, mk_ht(3'(dest), Y_COORD, DIR_LOCAL, 2'(kind), tag), VC_W'(vc));
          n_ht++;
        end else begin
          send(src, mk_head(3'(dest), Y_COORD, DIR_LOCAL, 2'(kind), tag), VC_W'(vc));
          for (int i = 0; i < len - 2; i++) send(src, mk_body(tag), VC_W'(vc));
          send(src, mk_tail(tag), VC_W'(vc));
        end
        sent++;
      end
    end

    $display("        %0d packets, %0d of them single-flit, %0d flits",
             sent, n_ht, sb_total_flits);
    wait_idle(4000);

    // -- completeness ---------------------------------------------------
    // Two independent counts of the same thing: sb_complete is the number of
    // expectation entries that reached `len`, sb_got_flits is the number of
    // flits the scoreboard matched. Both are compared against totals made
    // when the traffic was generated, so a lost flit shows up twice.
    check("T11 every packet fully delivered", sb_complete, sent);
    check("T11 flit conservation (sent == received)", sb_got_flits, sb_total_flits);
    // And the receiver's own tally: LOCAL-port ejections, counted by port
    // rather than by tag, must add up to the same number. Nothing was
    // delivered outside the scoreboard's view.
    check("T11 the receiver ejected every injected flit",
          eject_cnt[0] + eject_cnt[1] + eject_cnt[2], sb_total_flits);
    // Finally, the log length predicted at generation time: each flit logged
    // once per link it crossed plus once at ejection, no more and no less.
    // This is the check that catches an extra hop, a repeated log entry, or
    // a flit that was swallowed on the way.
    check("T11 every hop logged exactly once", rx_n(), exp_hops);
    $display("        %0d flits scored over %0d logged hops",
             sb_got_flits, rx_n());

    // -- per-router distribution: every router must have ejected something,
    //    or half the traffic never made it through the middle.
    for (int r = 0; r < N_RTR; r++) begin
      check_true($sformatf("T11 router %0d ejected traffic", r), eject_cnt[r] > 0);
    end

    // -- both directional links were actually used ----------------------
    check_true("T11 eastbound links carried traffic", east_cnt > 0);
    check_true("T11 westbound links carried traffic", west_cnt > 0);
    $display("        %0d eastbound, %0d westbound flit hops", east_cnt, west_cnt);

    // -- and nobody ever used a port that has no neighbour --------------
    check("T11 flits avoided the absent ports", bad_port_cnt, 0);

    sb_en = 1'b0;
  endtask


  //---------------------------------------------------------------
  // 18. Reset
  //---------------------------------------------------------------
  task automatic reset_dut();
    rst_n = 1'b0;
    repeat (5) @(posedge clk);
    @(negedge clk);
    rst_n = 1'b1;
    @(negedge clk);
    clear_rx();
    exp_q.delete();
    sb_en = 1'b0;
    sb_reset();
    deadlock_seen = 1'b0;
  endtask

  // Zero every scoreboard total. Called whenever the expectation queue is
  // emptied, so a fresh test never inherits somebody else's tallies.
  task automatic sb_reset();
    sb_outstanding = 0;
    sb_got_flits   = 0;
    sb_complete    = 0;
    sb_total_flits = 0;
  endtask

  //---------------------------------------------------------------
  // 18. Main
  //---------------------------------------------------------------
  initial begin : main
    if ($test$plusargs("vcd")) begin
      $dumpfile("sim/router_chain.vcd");
      $dumpvars(0, tb_router_chain);
    end

    reset_dut();

    $display("---- T10a  two-hop HEAD_TAIL, A -> C, route_next at both hops ----");
    t10a_two_hop_head_tail();

    $display("---- T10b  two-hop HEAD_TAIL back, C -> A ----");
    t10b_two_hop_reverse();

    $display("---- T10c  four-flit packet through both hops ----");
    t10c_two_hop_multi_flit();

    $display("---- T10d  the three one-hop legs ----");
    t10d_single_hop_legs();

    $display("---- section 6 credit loop: 16 flits, full rate ----");
    t_credit_loop_full_rate();

    $display("---- T11  random traffic with a scoreboard ----");
    t11_random_traffic();

    $display("");
    if (errors == 0) $display("ALL %0d CHECKS PASSED", checks);
    else $display("%0d/%0d CHECKS FAILED", errors, checks);

    $finish;
  end

endmodule
