// tb_noc_input_port.sv
//
// Directed testbench for noc_input_port, run against a MOCK arbiter.
//
// Why a mock: the real `arbiter` does not exist yet (build order step 3), and
// even once it does, a port-level test needs a grant source it can control to
// the cycle. The mock below models exactly the two behaviours the input port
// depends on and nothing else:
//
//   VA  - combinational accept in the request cycle (spec section 1.1: "the
//         allocator is combinational in the request cycle; the input port
//         latches assignment_valid at the clock edge"). Output VC is chosen
//         round-robin per input VC so out_vc capture gets exercised with more
//         than one value.
//   SA  - one round-robin pick across this port's requesting VCs, granted
//         immediately. This collapses the real arbiter's stage 2 (which here
//         has only one client) but keeps the property the input port cares
//         about: at most one VC switched per port per cycle, and sa_gnt
//         always implies sa_pick.
//
// Cycle accounting convention
// ---------------------------
// Inputs are driven at the negedge of cycle N and checked at the same negedge
// after a settling delay. The posedge that ENDS cycle N commits them, so a
// signal driven "during c0" is consumed by the c0->c1 edge and its effect is
// visible on outputs during c1. This matches the spec's section 3 timeline
// word for word: "H on link in c0" -> "H on data_out, head_valid, arrive,
// va_req in c1".
//
// Coverage
// --------
//   T9  empty-FIFO bypass (flit lands on the link with an empty FIFO)
//   T2  the section 3 three-flit packet, checked against its exact cycle table
//   T8  fetch and grant in the same cycle (the collision case)
//   R1  route capture + the arrival-cycle live VA output-port mux, including
//       the regression where a stale out_port would be sent to VA
//   L1  LOCAL port route computation (dest east, dest self)
//   V1  two VCs active at once: independence, one-hot sa_gnt, sa_pick mux
//   C1  credit return count == flit fetch count
//
// Everything runs under Verilator (full SVA support, which the DUT uses).
// That engine is 2-state, so this bench makes no claims about X propagation
// -- the poisoned-ROUTE cases below are forward-looking checks that will
// start earning their keep when the network moves to VCS.
//
// NOTE for anyone editing comments here: a line whose comment begins with
// the tool's own name is parsed by Verilator as a metacomment directive and
// the build dies with "Unknown verilator comment". Never start a comment
// line with that word.

`timescale 1ns / 1ps

//===============================================================================
// Testbench
//===============================================================================

module tb_noc_input_port;

  localparam int NUM_VC = 2;

  localparam logic [1:0] FLIT_BODY      = 2'b00;
  localparam logic [1:0] FLIT_HEAD      = 2'b01;
  localparam logic [1:0] FLIT_TAIL      = 2'b10;
  localparam logic [1:0] FLIT_HEAD_TAIL = 2'b11;

  localparam logic [3:0] DIR_LOCAL = 4'b0000;
  localparam logic [3:0] DIR_NORTH = 4'b0001;
  localparam logic [3:0] DIR_EAST  = 4'b0010;
  localparam logic [3:0] DIR_WEST  = 4'b0100;
  localparam logic [3:0] DIR_SOUTH = 4'b1000;

  localparam logic [2:0] CUR_X = 3'd3;
  localparam logic [2:0] CUR_Y = 3'd3;

  localparam realtime CLK_PERIOD = 10ns;
  localparam realtime SETTLE     = 1ns;  // after negedge, let comb logic settle

  int errors = 0;
  int checks = 0;

  //---------------------------------------------------------------------------
  // Check tasks
  //
  // One family per value width rather than one 32-bit task taking everything.
  // Passing a 4-bit direction to a 32-bit formal is a silent zero-extension
  // that linters flag (WIDTHEXPAND) and that hides real width mistakes, so
  // every wrapper widens explicitly and only where it means to.
  //
  // All four funnel into `report`, which owns the pass/fail bookkeeping.
  //---------------------------------------------------------------------------

  task automatic report(input string name, input logic [31:0] actual,
                        input logic [31:0] expected);
    checks++;
    if (actual !== expected) begin
      errors++;
      $display("[FAIL] %s : got=0x%08h exp=0x%08h  (t=%0t)", name, actual,
               expected, $time);
    end
    else begin
      $display("[PASS] %s : 0x%08h", name, actual);
    end
  endtask

  // 32-bit: flits, grant counters.
  task automatic chk(input string n, input logic [31:0] a, input logic [31:0] e);
    report(n, a, e);
  endtask

  // 4-bit: route directions.
  task automatic chk4(input string n, input logic [3:0] a, input logic [3:0] e);
    report(n, {28'd0, a}, {28'd0, e});
  endtask

  // 2-bit: VC indices and packed per-VC request vectors.
  task automatic chk2(input string n, input logic [1:0] a, input logic [1:0] e);
    report(n, {30'd0, a}, {30'd0, e});
  endtask

  // 1-bit: flags.
  task automatic chk_bit(input string n, input logic a, input logic e);
    report(n, {31'd0, a}, {31'd0, e});
  endtask

  //---------------------------------------------------------------------------
  // Flit constructors -- one place that knows the bit layout, so the tests
  // read as packets rather than as concatenations.
  //---------------------------------------------------------------------------

  // HEAD / HEAD_TAIL carry routing metadata.
  function automatic logic [31:0] mk_head(input logic [1:0] ftype,
                                          input logic [3:0] route,
                                          input logic [2:0] dest_y,
                                          input logic [2:0] dest_x);
    logic [31:0] f;
    f = '0;
    f[13:10] = route;   // ROUTE: this router's exit port (relay ports only)
    f[9:7]   = dest_y;
    f[6:4]   = dest_x;
    f[3:2]   = 2'b00;   // VC_ID -- ignored by routers (assumption D3)
    f[1:0]   = ftype;
    return f;
  endfunction

  // BODY / TAIL carry payload only.
  function automatic logic [31:0] mk_payload(input logic [1:0] ftype,
                                             input logic [29:0] payload);
    logic [31:0] f;
    f = '0;
    f[31:2] = payload;
    f[1:0]  = ftype;
    return f;
  endfunction

  //---------------------------------------------------------------------------
  // Clock / reset
  //---------------------------------------------------------------------------
  logic clk;
  logic rst_n;

  initial clk = 1'b0;
  always #(CLK_PERIOD / 2) clk = ~clk;

  task automatic do_reset();
    rst_n = 1'b0;
    repeat (4) @(negedge clk);
    rst_n = 1'b1;
    @(negedge clk);
    #SETTLE;
  endtask

  //===========================================================================
  // DUT 1: directional (relay) input port -- route comes from the header
  //===========================================================================
  logic [31:0] r_flt_data;
  logic        r_flt_valid;
  logic [1:0]  r_vc_id;

  logic [NUM_VC-1:0] r_credit;

  logic [NUM_VC-1:0] r_req_va;
  logic [3:0]        r_va_req_out_port [NUM_VC];
  logic [NUM_VC-1:0] r_va_req_single;
  logic [NUM_VC-1:0] r_va_gnt;
  logic [1:0]        r_va_gnt_out_vc [NUM_VC];

  logic [NUM_VC-1:0] r_req_sa;
  logic [3:0]        r_sa_req_out_port [NUM_VC];
  logic [1:0]        r_sa_req_out_vc [NUM_VC];
  logic [NUM_VC-1:0] r_sa_req_last;
  logic [NUM_VC-1:0] r_sa_gnt;
  logic [NUM_VC-1:0] r_sa_pick;

  logic [31:0] r_st_flit_data;
  logic [3:0]  r_st_route_next;

  noc_input_port #(
      .NUM_VC        (NUM_VC),
      .CUR_X         (CUR_X),
      .CUR_Y         (CUR_Y),
      .IS_LOCAL_PORT (0)
  ) u_relay (
      .clk                 (clk),
      .rst_n               (rst_n),

      .flit_data           (r_flt_data),
      .flit_valid          (r_flt_valid),
      .vc_id               (r_vc_id),

      .credit_return_valid (r_credit),

      .req_va              (r_req_va),
      .va_req_out_port     (r_va_req_out_port),
      .va_req_single       (r_va_req_single),
      .va_gnt              (r_va_gnt),
      .va_gnt_out_vc       (r_va_gnt_out_vc),

      .req_sa              (r_req_sa),
      .sa_req_out_port     (r_sa_req_out_port),
      .sa_req_out_vc       (r_sa_req_out_vc),
      .sa_req_last         (r_sa_req_last),
      .sa_gnt              (r_sa_gnt),
      .sa_pick             (r_sa_pick),

      .st_flit_data        (r_st_flit_data),
      .st_route_next       (r_st_route_next)
  );

  logic [NUM_VC-1:0] r_m_va_gnt, r_m_sa_gnt, r_m_sa_pick;
  logic [1:0]        r_m_va_out_vc [NUM_VC];
  int unsigned       r_n_va, r_n_sa;

  mock_arbiter #(.NUM_VC(NUM_VC)) u_relay_mock (
      .clk           (clk),
      .rst_n         (rst_n),
      .va_req        (r_req_va),
      .va_gnt        (r_m_va_gnt),
      .va_gnt_out_vc (r_m_va_out_vc),
      .sa_req        (r_req_sa),
      .sa_gnt        (r_m_sa_gnt),
      .sa_pick       (r_m_sa_pick),
      .n_va_grants   (r_n_va),
      .n_sa_grants   (r_n_sa)
  );

  // The mock's grants are wired straight back into the DUT, copied element by
  // element so the loop makes the per-VC correspondence explicit rather than
  // hiding it behind a whole-array assignment.
  always_comb begin
    r_va_gnt   = r_m_va_gnt;
    r_sa_gnt   = r_m_sa_gnt;
    r_sa_pick  = r_m_sa_pick;
    for (int v = 0; v < NUM_VC; v++) begin
      r_va_gnt_out_vc[v] = r_m_va_out_vc[v];
    end
  end

  // Drive helper for the relay port.
  task automatic r_step(input logic [31:0] d, input logic v, input logic [1:0] vc);
    @(negedge clk);
    r_flt_data  = d;
    r_flt_valid = v;
    r_vc_id     = vc;
    #SETTLE;
  endtask

  task automatic r_idle();
    r_step(32'h0, 1'b0, 2'd0);
  endtask

  //===========================================================================
  // DUT 2: LOCAL input port -- route is computed from the destination
  //===========================================================================
  logic [31:0] l_flt_data;
  logic        l_flt_valid;
  logic [1:0]  l_vc_id;

  logic [NUM_VC-1:0] l_credit;

  logic [NUM_VC-1:0] l_req_va;
  logic [3:0]        l_va_req_out_port [NUM_VC];
  logic [NUM_VC-1:0] l_va_req_single;
  logic [NUM_VC-1:0] l_va_gnt;
  logic [1:0]        l_va_gnt_out_vc [NUM_VC];

  logic [NUM_VC-1:0] l_req_sa;
  logic [3:0]        l_sa_req_out_port [NUM_VC];
  logic [1:0]        l_sa_req_out_vc [NUM_VC];
  logic [NUM_VC-1:0] l_sa_req_last;
  logic [NUM_VC-1:0] l_sa_gnt;
  logic [NUM_VC-1:0] l_sa_pick;

  logic [31:0] l_st_flit_data;
  logic [3:0]  l_st_route_next;

  noc_input_port #(
      .NUM_VC        (NUM_VC),
      .CUR_X         (CUR_X),
      .CUR_Y         (CUR_Y),
      .IS_LOCAL_PORT (1)
  ) u_local (
      .clk                 (clk),
      .rst_n               (rst_n),

      .flit_data           (l_flt_data),
      .flit_valid          (l_flt_valid),
      .vc_id               (l_vc_id),

      .credit_return_valid (l_credit),

      .req_va              (l_req_va),
      .va_req_out_port     (l_va_req_out_port),
      .va_req_single       (l_va_req_single),
      .va_gnt              (l_va_gnt),
      .va_gnt_out_vc       (l_va_gnt_out_vc),

      .req_sa              (l_req_sa),
      .sa_req_out_port     (l_sa_req_out_port),
      .sa_req_out_vc       (l_sa_req_out_vc),
      .sa_req_last         (l_sa_req_last),
      .sa_gnt              (l_sa_gnt),
      .sa_pick             (l_sa_pick),

      .st_flit_data        (l_st_flit_data),
      .st_route_next       (l_st_route_next)
  );

  logic [NUM_VC-1:0] l_m_va_gnt, l_m_sa_gnt, l_m_sa_pick;
  logic [1:0]        l_m_va_out_vc [NUM_VC];
  int unsigned       l_n_va, l_n_sa;

  mock_arbiter #(.NUM_VC(NUM_VC)) u_local_mock (
      .clk           (clk),
      .rst_n         (rst_n),
      .va_req        (l_req_va),
      .va_gnt        (l_m_va_gnt),
      .va_gnt_out_vc (l_m_va_out_vc),
      .sa_req        (l_req_sa),
      .sa_gnt        (l_m_sa_gnt),
      .sa_pick       (l_m_sa_pick),
      .n_va_grants   (l_n_va),
      .n_sa_grants   (l_n_sa)
  );

  always_comb begin
    l_va_gnt   = l_m_va_gnt;
    l_sa_gnt   = l_m_sa_gnt;
    l_sa_pick  = l_m_sa_pick;
    for (int v = 0; v < NUM_VC; v++) begin
      l_va_gnt_out_vc[v] = l_m_va_out_vc[v];
    end
  end

  task automatic l_step(input logic [31:0] d, input logic v, input logic [1:0] vc);
    @(negedge clk);
    l_flt_data  = d;
    l_flt_valid = v;
    l_vc_id     = vc;
    #SETTLE;
  endtask

  task automatic l_idle();
    l_step(32'h0, 1'b0, 2'd0);
  endtask


  //===========================================================================
  // Test: T0 -- idle behaviour out of reset
  //
  // With nothing offered, nothing may be requested, granted, switched or
  // credited. A non-zero here means something is asserted combinationally
  // when it should not be (typically a decode of stale data_out).
  //===========================================================================
  task automatic test_reset();
    $display("--- T0: idle after reset ---");
    do_reset();

    chk2("T0 req_va",            r_req_va,  '0);
    chk2("T0 req_sa",            r_req_sa,  '0);
    chk2("T0 credit_return",     r_credit,  '0);
    chk("T0 st_flit_data",      r_st_flit_data, '0);
    chk4("T0 st_route_next",     r_st_route_next, '0);
    chk2("T0 va_req_single",     r_va_req_single, '0);
    chk2("T0 sa_req_last",       r_sa_req_last, '0);
    chk2("T0 local req_va",      l_req_va,  '0);
  endtask


  //===========================================================================
  // Test: T9 -- empty-FIFO bypass
  //
  // A single HEAD_TAIL arrives on a link whose FIFO is completely empty and
  // whose VC is idle. The FIFO's bypass path forwards it straight to data_out
  // without entering storage, so:
  //
  //   c0  flit on link, fetch=1 (bypass)
  //   c1  flit on data_out, arrive=1 -> first VA request, against the LIVE
  //       route_compute output (out_port has never been written for this VC)
  //   c2  VA has been latched -> SA request, grant, flit switched
  //
  // The credit for the c0 fetch must appear in c1 (registered one cycle
  // after the read, assumption D4).
  //===========================================================================
  task automatic test_T9_bypass();
    logic [31:0] pkt;

    $display("--- T9: empty-FIFO bypass ---");
    do_reset();

    pkt = mk_head(FLIT_HEAD_TAIL, DIR_WEST, 3'd1, 3'd1);

    // ---- c0: flit lands on an empty link ----
    r_step(pkt, 1'b1, 2'd0);

    chk_bit("T9 c0 req_va (not yet)",      r_req_va[0], 1'b0);
    chk_bit("T9 c0 credit_return (c1 too)", r_credit[0], 1'b0);

    // ---- c1: bypassed flit is on data_out ----
    r_idle();

    chk_bit("T9 c1 req_va",           r_req_va[0], 1'b1);
    chk_bit("T9 c1 va_req_single",    r_va_req_single[0], 1'b1);
    chk4("T9 c1 va_req_out_port",      r_va_req_out_port[0], DIR_WEST);
    chk_bit("T9 c1 credit_return",    r_credit[0], 1'b1);   // registered from c0 fetch
    chk_bit("T9 c1 req_sa (VA not yet latched)", r_req_sa[0], 1'b0);

    // ---- c2: assignment latched, SA request + grant, flit switches ----
    r_idle();

    chk_bit("T9 c2 req_sa",           r_req_sa[0], 1'b1);
    chk4("T9 c2 sa_req_out_port",      r_sa_req_out_port[0], DIR_WEST);
    chk_bit("T9 c2 sa_req_last",      r_sa_req_last[0], 1'b1);
    chk_bit("T9 c2 sa_gnt",           r_sa_gnt[0], 1'b1);
    chk("T9 c2 st_flit_data",         r_st_flit_data, pkt);
    chk_bit("T9 c2 credit_return",    r_credit[0], 1'b0);   // c1 fetched nothing

    // ---- c3: HEAD_TAIL was the last flit, so everything releases ----
    r_idle();

    chk_bit("T9 c3 req_sa",           r_req_sa[0], 1'b0);
    chk_bit("T9 c3 req_va",           r_req_va[0], 1'b0);
    chk_bit("T9 c3 credit_return",    r_credit[0], 1'b0);
  endtask


  //===========================================================================
  // Test: T2 -- the section 3 reference timeline
  //
  // 3-flit packet H, B, T arriving back-to-back on VC0, destined for the
  // WEST output. This is transcribed cycle for cycle from the spec's table;
  // if any of these numbers move, the pipeline has moved with them.
  //
  //   c0  H on link       fetch (bypass)
  //   c1  B on link       H on data_out, arrive, VA request + live port
  //                       B written to FIFO (head_valid=1, no grant)
  //   c2  T on link       SA request + GRANT (H switches); fetch B
  //   c3  idle            B on data_out; GRANT (B switches); fetch T
  //   c4  idle            T on data_out; GRANT (T switches); FIFO empty ->
  //                       fetch = 0, head_valid and assignment_valid clear
  //   c5  idle
  //
  // Three consecutive grants (c2, c3, c4) is the throughput claim: one flit
  // per cycle per VC.
  //===========================================================================
  task automatic test_T2_three_flit();
    logic [31:0] H, B, T;
    logic [3:0]   exp_route_next;

    $display("--- T2: 3-flit packet, spec section 3 timeline ---");
    do_reset();

    H = mk_head(FLIT_HEAD, DIR_WEST, 3'd1, 3'd1);
    B = mk_payload(FLIT_BODY, 30'h1234_5678);
    T = mk_payload(FLIT_TAIL, 30'h0BAD_C0DE);

    // With CUR=(3,3), route WEST, dest x=1: next hop is (2,3), still 2 hops
    // short of x=1, so the lookahead route is WEST again.
    exp_route_next = DIR_WEST;

    // ---- c0 ----
    r_step(H, 1'b1, 2'd0);
    chk_bit("T2 c0 req_va (H not fetched yet)", r_req_va[0], 1'b0);

    // ---- c1 ----
    r_step(B, 1'b1, 2'd0);
    chk_bit("T2 c1 req_va",             r_req_va[0], 1'b1);
    chk4("T2 c1 va_req_out_port (live)",  r_va_req_out_port[0], DIR_WEST);
    chk_bit("T2 c1 va_req_single",       r_va_req_single[0], 1'b0);  // HEAD, not HT
    chk_bit("T2 c1 credit_return",       r_credit[0], 1'b1);         // from c0 fetch
    chk_bit("T2 c1 req_sa (VA pending)", r_req_sa[0], 1'b0);

    // ---- c2 : grant #1, H switches ----
    r_step(T, 1'b1, 2'd0);
    chk_bit("T2 c2 req_sa",              r_req_sa[0], 1'b1);
    chk4("T2 c2 sa_req_out_port",         r_sa_req_out_port[0], DIR_WEST);
    chk2("T2 c2 sa_req_out_vc",           r_sa_req_out_vc[0], 2'd0);  // mock's first pick
    chk_bit("T2 c2 sa_req_last",         r_sa_req_last[0], 1'b0);    // H is not last
    chk_bit("T2 c2 sa_gnt",              r_sa_gnt[0], 1'b1);
    chk_bit("T2 c2 sa_pick",             r_sa_pick[0], 1'b1);
    chk("T2 c2 st_flit_data (H)",        r_st_flit_data, H);
    chk4("T2 c2 st_route_next",           r_st_route_next, exp_route_next);
    chk_bit("T2 c2 credit_return",       r_credit[0], 1'b0);         // c1 fetched nothing

    // ---- c3 : grant #2, B switches ----
    r_idle();
    chk_bit("T2 c3 req_sa (head held)",  r_req_sa[0], 1'b1);
    chk_bit("T2 c3 sa_gnt",              r_sa_gnt[0], 1'b1);
    chk("T2 c3 st_flit_data (B)",        r_st_flit_data, B);
    chk_bit("T2 c3 sa_req_last",         r_sa_req_last[0], 1'b0);
    chk_bit("T2 c3 credit_return",       r_credit[0], 1'b1);         // from c2 fetch of B

    // ---- c4 : grant #3, T switches; FIFO empty so no fetch ----
    r_idle();
    chk_bit("T2 c4 sa_gnt",              r_sa_gnt[0], 1'b1);
    chk("T2 c4 st_flit_data (T)",        r_st_flit_data, T);
    chk_bit("T2 c4 sa_req_last",         r_sa_req_last[0], 1'b1);
    chk_bit("T2 c4 credit_return",       r_credit[0], 1'b1);         // from c3 fetch of T

    // ---- c5 : everything released ----
    r_idle();
    chk_bit("T2 c5 req_sa",              r_req_sa[0], 1'b0);
    chk_bit("T2 c5 req_va",              r_req_va[0], 1'b0);
    chk_bit("T2 c5 credit_return",       r_credit[0], 1'b0);         // c4 fetched nothing

    // Exactly three grants, no more, no fewer.
    chk("T2 total SA grants", 32'(r_n_sa), 32'd3);
    chk("T2 total VA grants", 32'(r_n_va), 32'd1);
  endtask


  //===========================================================================
  // Test: T8 -- fetch and grant in the same cycle (collision)
  //
  // The case the old `!head_valid && ...` fetch rule got wrong. Sequence:
  //
  //   c0  H on link, fetch via bypass (FIFO stays empty)
  //   c1  H on data_out, VA request, VA grants at the edge. No link traffic.
  //   c2  SA request AND GRANT for H. Simultaneously T arrives on the link
  //       with the FIFO still empty -> fetch takes the BYPASS path in the
  //       very cycle the head register is being vacated.
  //   c3  T must be on data_out with req_sa still high.
  //
  // If fetch loses to the grant, head_valid drops in c3 and T is stranded:
  // req_sa goes low for a cycle and the flit is delayed (or, under the old
  // head_valid edge-detect route capture, captured against a stale header).
  //
  // Note c1 deliberately leaves the FIFO empty so that c2's fetch must come
  // from fifo_wr_enable -- exercising the `|| fifo_wr_enable` half of the
  // rule rather than the `!fifo_empty` half.
  //===========================================================================
  task automatic test_T8_collision();
    logic [31:0] H, T;

    $display("--- T8: fetch and grant in the same cycle ---");
    do_reset();

    H = mk_head(FLIT_HEAD, DIR_EAST, 3'd5, 3'd5);
    T = mk_payload(FLIT_TAIL, 30'h3333_3333);

    // ---- c0 ----
    r_step(H, 1'b1, 2'd0);
    chk_bit("T8 c0 req_va", r_req_va[0], 1'b0);

    // ---- c1 : VA request, no link traffic so the FIFO stays empty ----
    r_idle();
    chk_bit("T8 c1 req_va",           r_req_va[0], 1'b1);
    chk4("T8 c1 va_req_out_port",      r_va_req_out_port[0], DIR_EAST);
    chk_bit("T8 c1 req_sa",           r_req_sa[0], 1'b0);

    // ---- c2 : GRANT for H, and T arrives on an empty FIFO in the same cycle
    r_step(T, 1'b1, 2'd0);
    chk_bit("T8 c2 sa_gnt",           r_sa_gnt[0], 1'b1);
    chk("T8 c2 st_flit_data (H)",     r_st_flit_data, H);
    chk_bit("T8 c2 sa_req_last",      r_sa_req_last[0], 1'b0);

    // ---- c3 : the collision must have kept the VC active ----
    r_idle();
    chk_bit("T8 c3 req_sa (head held across collision)", r_req_sa[0], 1'b1);
    chk_bit("T8 c3 sa_gnt",           r_sa_gnt[0], 1'b1);
    chk("T8 c3 st_flit_data (T)",     r_st_flit_data, T);
    chk_bit("T8 c3 sa_req_last",      r_sa_req_last[0], 1'b1);
    chk_bit("T8 c3 credit_return",    r_credit[0], 1'b1);   // c2's bypass fetch

    // ---- c4 : released ----
    r_idle();
    chk_bit("T8 c4 req_sa",           r_req_sa[0], 1'b0);
    chk_bit("T8 c4 credit_return",    r_credit[0], 1'b0);

    chk("T8 total SA grants", 32'(r_n_sa), 32'd2);
    chk("T8 total VA grants", 32'(r_n_va), 32'd1);
  endtask


  //===========================================================================
  // Test: R1 -- route capture and the arrival-cycle live VA output-port mux
  //
  // Two packets back-to-back on the same VC, deliberately routed to
  // DIFFERENT output ports.
  //
  // Regression being pinned down: `va_req_out_port` must read the live
  // route_compute output during the arrival cycle and the latched register
  // afterwards. Driving it straight from the latch (the original code did
  // exactly that) means the second packet's first VA request is made against
  // the FIRST packet's route -- here, NORTH instead of EAST -- and the packet
  // gets allocated down the wrong output port.
  //
  //   pkt1 (NORTH) arrives c0 -> out_port latched NORTH at end of c1
  //   pkt2 (EAST)  arrives c3 -> out_port still holds NORTH, so the ONLY way
  //              va_req_out_port can read EAST is the live mux.
  //===========================================================================
  task automatic test_R1_route_capture();
    logic [31:0] p1, p2;

    $display("--- R1: route capture + live VA output-port mux ---");
    do_reset();

    p1 = mk_head(FLIT_HEAD_TAIL, DIR_NORTH, 3'd1, 3'd3);
    p2 = mk_head(FLIT_HEAD_TAIL, DIR_EAST,  3'd3, 3'd5);

    // ---- packet 1: NORTH ----
    r_step(p1, 1'b1, 2'd0);                       // c0: arrive next cycle

    r_idle();                                     // c1
    chk4("R1 c1 pkt1 va_req_out_port", r_va_req_out_port[0], DIR_NORTH);
    chk_bit("R1 c1 req_va",           r_req_va[0], 1'b1);

    r_idle();                                     // c2: switch pkt1
    chk4("R1 c2 pkt1 sa_req_out_port", r_sa_req_out_port[0], DIR_NORTH);
    chk_bit("R1 c2 sa_gnt",           r_sa_gnt[0], 1'b1);

    // ---- packet 2: EAST, arriving into a VC whose out_port still says NORTH
    r_step(p2, 1'b1, 2'd0);                       // c3: pkt2 on link, pkt1 done

    r_idle();                                     // c4: pkt2 arrival cycle
    chk4("R1 c4 pkt2 va_req_out_port (LIVE, not stale NORTH)", r_va_req_out_port[0], DIR_EAST);
    chk_bit("R1 c4 req_va",           r_req_va[0], 1'b1);
    chk_bit("R1 c4 req_sa",           r_req_sa[0], 1'b0);

    r_idle();                                     // c5: latched value must now be EAST
    chk4("R1 c5 pkt2 sa_req_out_port (LATCHED)", r_sa_req_out_port[0], DIR_EAST);
    chk_bit("R1 c5 sa_gnt",           r_sa_gnt[0], 1'b1);
    chk("R1 c5 st_flit_data",         r_st_flit_data, p2);

    r_idle();                                     // c6
    chk_bit("R1 c6 req_sa",           r_req_sa[0], 1'b0);

    chk("R1 total VA grants", 32'(r_n_va), 32'd2);
    chk("R1 total SA grants", 32'(r_n_sa), 32'd2);
  endtask


  //===========================================================================
  // Test: L1 -- LOCAL port route computation
  //
  // The local instance is the only one where route_self is COMPUTED rather
  // than read out of the header. Two directions plus the self-termination
  // edge case, where route_self is LOCAL and route_next must be forced LOCAL
  // instead of being derived from meaningless next-hop coordinates.
  //===========================================================================
  task automatic test_L1_local_port();
    logic [31:0] pkt;

    $display("--- L1: LOCAL port route compute ---");
    do_reset();

    // -- dest (5,3) from CUR (3,3): X differs -> EAST -----------------------
    // ROUTE is deliberately poisoned with X: a local port must never look at
    // it (it has no upstream header), so the value has to be irrelevant.
    pkt = mk_head(FLIT_HEAD_TAIL, 4'bxxxx, 3'd3, 3'd5);
    l_step(pkt, 1'b1, 2'd0);

    l_idle();                                       // c1: arrival
    chk4("L1 east va_req_out_port (LIVE)",  l_va_req_out_port[0], DIR_EAST);
    // Credit for the c0 bypass fetch, registered one cycle later (D4).
    chk2("L1 east credit_return",           l_credit, 2'b01);
    // HEAD_TAIL, so VA sees the single-flit tier bit.
    chk2("L1 east va_req_single",           l_va_req_single, 2'b01);

    l_idle();                                       // c2: latched, switching
    chk4("L1 east sa_req_out_port (LATCHED)", l_sa_req_out_port[0], DIR_EAST);
    chk_bit("L1 east sa_gnt",              l_sa_gnt[0], 1'b1);
    chk2("L1 east sa_req_last",         l_sa_req_last, 2'b01);
    chk2("L1 east sa_req_out_vc",          l_sa_req_out_vc[0], 2'd0);  // 1st grant
    chk("L1 east st_flit_data",            l_st_flit_data, pkt);
    // st_route_next is muxed by sa_pick, so it is only presented during the
    // grant cycle -- which is precisely when the output port merges it into
    // the outgoing header.
    chk4("L1 east st_route_next",          l_st_route_next, DIR_EAST);  // next hop (4,3) -> still east

    l_idle();                                       // c3: released
    chk_bit("L1 east done",                l_req_sa[0], 1'b0);

    // -- dest (3,5): X matches, Y grows downward -> SOUTH -------------------
    pkt = mk_head(FLIT_HEAD_TAIL, 4'bxxxx, 3'd5, 3'd3);
    l_step(pkt, 1'b1, 2'd0);

    l_idle();
    chk4("L1 south va_req_out_port (LIVE)", l_va_req_out_port[0], DIR_SOUTH);
    chk2("L1 south credit_return",          l_credit, 2'b01);
    chk2("L1 south va_req_single",          l_va_req_single, 2'b01);

    l_idle();
    chk4("L1 south sa_req_out_port",        l_sa_req_out_port[0], DIR_SOUTH);
    chk_bit("L1 south sa_gnt",             l_sa_gnt[0], 1'b1);
    chk2("L1 south sa_req_last",        l_sa_req_last, 2'b01);
    chk2("L1 south sa_req_out_vc",         l_sa_req_out_vc[0], 2'd1);  // 2nd grant
    chk("L1 south st_flit_data",           l_st_flit_data, pkt);
    // next hop (3,4) vs dest (3,5): still south.
    chk4("L1 south st_route_next",         l_st_route_next, DIR_SOUTH);

    l_idle();
    chk_bit("L1 south done",               l_req_sa[0], 1'b0);

    // -- dest == CUR: injection to this very router ------------------------
    // route_self resolves LOCAL on the FIRST compute_dir call, and
    // route_next must be forced LOCAL WITHOUT a second call on junk
    // next-hop coordinates.
    pkt = mk_head(FLIT_HEAD_TAIL, 4'bxxxx, CUR_Y, CUR_X);
    l_step(pkt, 1'b1, 2'd0);

    l_idle();
    chk4("L1 self va_req_out_port",         l_va_req_out_port[0], DIR_LOCAL);
    chk2("L1 self credit_return",           l_credit, 2'b01);
    chk2("L1 self va_req_single",           l_va_req_single, 2'b01);

    l_idle();
    chk4("L1 self sa_req_out_port",         l_sa_req_out_port[0], DIR_LOCAL);
    chk_bit("L1 self sa_gnt",              l_sa_gnt[0], 1'b1);
    chk2("L1 self sa_req_last",         l_sa_req_last, 2'b01);
    chk2("L1 self sa_req_out_vc",          l_sa_req_out_vc[0], 2'd0);  // wraps back
    chk("L1 self st_flit_data",            l_st_flit_data, pkt);
    chk4("L1 self st_route_next",          l_st_route_next, DIR_LOCAL);

    l_idle();
    chk_bit("L1 self done",                l_req_sa[0], 1'b0);

    chk("L1 total VA grants", 32'(l_n_va), 32'd3);
    chk("L1 total SA grants", 32'(l_n_sa), 32'd3);
  endtask


  //===========================================================================
  // Test: V1 -- two VCs active at the same time
  //
  // Two single-flit packets fed to different VCs one cycle apart, each with a
  // different output port. Checks:
  //
  //   - the VCs do not interfere (separate FIFOs, separate control state),
  //   - sa_gnt is one-hot at any given cycle -- the port has one datapath,
  //   - sa_pick actually selects the right VC's flit for the crossbar mux,
  //   - each packet's route survives to its own sa_req_out_port.
  //
  // The mock's stage-1 pointer alternates, so VC0 switches first and VC1
  // one cycle later.
  //===========================================================================
  task automatic test_V1_two_vc();
    logic [31:0] f0, f1;

    $display("--- V1: two VCs concurrently ---");
    do_reset();

    f0 = mk_head(FLIT_HEAD_TAIL, DIR_NORTH, 3'd1, 3'd3);
    f1 = mk_head(FLIT_HEAD_TAIL, DIR_SOUTH, 3'd5, 3'd3);

    // ---- c0: VC0's packet ----
    r_step(f0, 1'b1, 2'd0);

    // ---- c1: VC1's packet arrives while VC0 is sitting at the VA stage ----
    r_step(f1, 1'b1, 2'd1);
    chk_bit("V1 c1 req_va[0] (VC0 at VA)",        r_req_va[0], 1'b1);
    chk4("V1 c1 VC0 va_req_out_port (LIVE)",       r_va_req_out_port[0], DIR_NORTH);
    chk_bit("V1 c1 req_sa[0] (VA not latched)",   r_req_sa[0], 1'b0);
    // VC1's flit is on the link this cycle but is not on data_out until c2,
    // so it must not be asking for anything yet.
    chk_bit("V1 c1 req_va[1] (VC1 not fetched)",  r_req_va[1], 1'b0);

    // ---- c2: VC0 switches (mock pointer starts at 0), VC1 reaches VA ----
    r_idle();
    chk_bit("V1 c2 sa_gnt[0]",                    r_sa_gnt[0], 1'b1);
    chk_bit("V1 c2 sa_gnt[1] (only one per port)", r_sa_gnt[1], 1'b0);
    chk_bit("V1 c2 sa_pick[0]",                   r_sa_pick[0], 1'b1);
    chk_bit("V1 c2 sa_pick[1]",                   r_sa_pick[1], 1'b0);
    chk("V1 c2 st_flit_data (VC0's)",             r_st_flit_data, f0);
    chk4("V1 c2 VC0 sa_req_out_port",              r_sa_req_out_port[0], DIR_NORTH);
    chk_bit("V1 c2 req_va[0] (now owns a VC)",    r_req_va[0], 1'b0);
    chk_bit("V1 c2 req_va[1] (VC1 at VA)",        r_req_va[1], 1'b1);
    chk4("V1 c2 VC1 va_req_out_port (LIVE)",       r_va_req_out_port[1], DIR_SOUTH);

    // ---- c3: VC1 switches, VC0 already released ----
    r_idle();
    chk_bit("V1 c3 sa_gnt[0] (released)",         r_sa_gnt[0], 1'b0);
    chk_bit("V1 c3 sa_gnt[1]",                    r_sa_gnt[1], 1'b1);
    chk_bit("V1 c3 sa_pick[1]",                   r_sa_pick[1], 1'b1);
    chk("V1 c3 st_flit_data (VC1's)",             r_st_flit_data, f1);
    chk4("V1 c3 VC1 sa_req_out_port",              r_sa_req_out_port[1], DIR_SOUTH);
    chk_bit("V1 c3 VC0 idle",                     r_req_sa[0], 1'b0);

    // ---- c4: both idle ----
    r_idle();
    chk_bit("V1 c4 req_sa[0]",        r_req_sa[0], 1'b0);
    chk_bit("V1 c4 req_sa[1]",        r_req_sa[1], 1'b0);

    chk("V1 total VA grants", 32'(r_n_va), 32'd2);
    chk("V1 total SA grants", 32'(r_n_sa), 32'd2);
  endtask


  //===========================================================================
  // Test: C1 -- credit return accounting
  //
  // credit_return is registered from fetch, so over a long run the number of
  // credits returned must equal the number of flits that ever reached
  // data_out. Each flit fetched exactly once means no flit lost, and no extra
  // credit means no flit double-counted -- which is what stops the upstream
  // router from over-running this buffer.
  //
  // Flits in this test: 6.
  //===========================================================================
  task automatic test_C1_credits();
    logic [31:0] pkts[6];
    int unsigned credits;
    logic [31:0] n_before;

    $display("--- C1: credit return accounting ---");
    do_reset();

    credits = 0;
    n_before = 32'(r_n_sa);

    // Six single-flit packets, alternating VCs so both fetch paths and both
    // per-VC credit bits get exercised. They are spaced two cycles apart so
    // each VC is guaranteed idle before its next packet lands.
    for (int k = 0; k < 6; k++) begin
      pkts[k] = mk_head(FLIT_HEAD_TAIL,
                        ((k % 2) != 0) ? DIR_SOUTH : DIR_EAST,
                        3'd1 + 3'(k),
                        3'd1);
    end

    for (int k = 0; k < 6; k++) begin
      // Drive flit k during its cycle; its fetch (bypass) commits at the
      // edge that ends this cycle.
      r_step(pkts[k], 1'b1, 2'(k % 2));

      // Advance one cycle: the registered credit for that fetch is now on
      // the wire, on the bit belonging to the VC that fetched.
      @(negedge clk);
      #SETTLE;
      credits += 32'(r_credit[0]) + 32'(r_credit[1]);

      // Drop the link so the next iteration's r_step starts two cycles on.
      r_flt_data  = '0;
      r_flt_valid = 1'b0;
      r_vc_id     = '0;
      #SETTLE;
    end

    // Drain: nothing more arrives, so any credit seen here would be a
    // spurious extra return for a flit that was already accounted.
    repeat (6) begin
      @(negedge clk);
      #SETTLE;
      credits += 32'(r_credit[0]) + 32'(r_credit[1]);
    end

    chk("C1 credits returned", credits, 32'd6);
    chk("C1 flits switched",   32'(r_n_sa) - n_before, 32'd6);
  endtask


  //===========================================================================
  // Top-level sequence
  //===========================================================================
  initial begin
    // Park the links idle before reset releases.
    r_flt_data  = '0;
    r_flt_valid = 1'b0;
    r_vc_id     = '0;
    l_flt_data  = '0;
    l_flt_valid = 1'b0;
    l_vc_id     = '0;

    test_reset();

    test_T9_bypass();
    test_T2_three_flit();
    test_T8_collision();
    test_R1_route_capture();
    test_L1_local_port();
    test_V1_two_vc();
    test_C1_credits();

    $display("========================================");
    $display("Checks : %0d", checks);
    $display("Errors : %0d", errors);
    if (errors == 0) $display("ALL TESTS PASSED");
    else $display("TEST FAILED");
    $display("========================================");
    $finish;
  end

  //---------------------------------------------------------------------------
  // Global timeout -- a hung fetch/grant loop should fail loudly rather than
  // spinning until someone kills the sim.
  //---------------------------------------------------------------------------
  initial begin
    #(CLK_PERIOD * 2000);
    $display("ERROR: tb_noc_input_port timed out");
    $finish;
  end

  //---------------------------------------------------------------------------
  // Waveform dump
  //---------------------------------------------------------------------------
  initial begin
    $dumpfile("sim/noc_input_port.vcd");
    $dumpvars(0, tb_noc_input_port);
  end

endmodule
