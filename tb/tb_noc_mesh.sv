`timescale 1ns / 1ps

// tb_noc_mesh.sv
//
// The mesh self-test. Every tile sends a packet to every other tile, and
// the run is judged on exactly two properties:
//
//   1. PACKET INTEGRITY. A flit comes out byte-identical to what went in
//      (a header modulo its ROUTE field, which every output port rewrites),
//      each packet's flits come out in order, and the network produces no
//      more flits and no fewer than it was given.
//   2. THE CORRECT EJECTION TILE. A packet comes out on the LOCAL port of
//      the tile it was addressed to, and nowhere else.
//
// There is deliberately no routing oracle here -- no Manhattan distance, no
// hop count, no model of the path a packet takes. The bench cannot say how
// a packet reached a tile; it can say which tile it must reach and what it
// must look like when it gets there. Baking a routing algorithm into the
// scoreboard would turn any legitimate routing change into a regression
// read, and would make the test answer a question nobody asked.
//
//
// What this bench is and is not
// -----------------------------
// It is the test of noc_mesh's one job: that ROWS*COLS routers, wired by
// this module and nothing else, pass packets between their LOCAL ports
// intact and to the right place. It is NOT a test of route_compute (the
// router_top and route_compute benches cover that), not a test of the credit
// arithmetic (the input/output port benches and the chain do), and not a
// performance measurement -- no latency, throughput or Manhattan number is
// computed anywhere below.
//
//
// Reading this file
// -----------------
// Tests name fields, never bit positions, and never signals: `flit_dst_x(h)`
// and `flit_route(h)` come from noc_tb_pkg, which is the only file that
// knows where the bits are. The scoreboard below is written entirely in
// those terms, so moving a field in the header moves this file's behaviour
// or does not compile -- it cannot silently keep reading the old slice.
//
// The whole bench sees four signals of the DUT: injection, ejection, and the
// two halves of the LOCAL credit loop. Every inter-router wire in the mesh
// is noc_mesh's business.
//

module tb_noc_mesh;

  // Flit field model and the shared reporter (see noc_tb_pkg.sv).
  import noc_tb_pkg::*;

  //=========================================================================
  // EDIT ME -- mesh geometry and traffic shape
  //
  //   make TOP=noc_mesh sim ROWS=4 COLS=4
  //
  // Everything below this banner is written against ROWS and COLS; there is
  // no second place in this file where the shape of the array is written
  // down, and no place that assumes a 2x2. Geometry also reaches the DUT: the
  // instance below passes ROWS/COLS straight through, so one number here
  // changes both the stimulus and the array under test.
  //
  // 1x1, 2x2, 3x3 and 2x3 are all worth running -- see the "walls" comment
  // on the traffic generator for why the small ones are not trivial.
  //=========================================================================
  parameter int ROWS = 2;
  parameter int COLS = 2;

  parameter int NUM_VC = 4;

  // Neighbour input FIFO depth, and -- per linnea_v2 section 1, which sets
  // them equal -- the NI receive buffer depth each tile's LOCAL output
  // credit counter starts at. Swept one at a time by `make regress`.
  parameter int FIFO_DEPTH = 4;
  parameter int LOCAL_CREDITS = FIFO_DEPTH;

  // Longest packet, in flits. Packet (s,d) is
  //   1 + ((s*N + d) % MAX_LEN)
  // flits long, so the traffic is a fixed function of the geometry: the same
  // ROWS and COLS always produce the same packets, and a failure reproduces
  // run to run with no seed to remember.
  parameter int MAX_LEN = 4;

  localparam int          NUM_PORTS  = 5;
  localparam int          VC_W       = (NUM_VC > 1) ? $clog2(NUM_VC) : 1;
  localparam int          N_TILES    = ROWS * COLS;
  localparam realtime     CLK_PERIOD = 10ns;

  // Watchdog: no flit scored, with work still outstanding, for this many
  // cycles, and the run is stuck. Counted in the progress watchdog below
  // rather than left for the timeout in wait_idle() to notice, so that a
  // deadlock reports where it stopped instead of as "did not settle".
  localparam int          MAX_STALL  = 500;

  localparam logic [3:0]  DIR_LOCAL = 4'b0000;
  localparam logic [3:0]  DIR_NORTH = 4'b0001;

  // What every injected header carries in its ROUTE field.
  //
  // On a LOCAL input port route_compute ignores route_in entirely and
  // computes the exit direction from the destination (route_compute.sv step
  // 1), so this value is dead the instant the flit is built -- and that is
  // the point. It must not survive to the wire: noc_output_port's merge
  // replaces it with the lookahead on every head, at every hop, so a flit
  // that arrives anywhere still carrying it means a merge did not happen.
  //
  // It is deliberately NOT DIR_LOCAL, which is what tb_router_chain injects.
  // DIR_LOCAL is also the correct value at ejection, so a bench that injects
  // it catches a missing merge only on multi-hop packets; on a small mesh
  // most packets are one hop, and DIR_LOCAL would leave those checking
  // nothing at all. A direction that is simply wrong for every packet makes
  // the check bite on all of them, and costs nothing when the merge works,
  // because route_compute never reads the field on a LOCAL port.
  localparam logic [3:0]  INJ_ROUTE = DIR_NORTH;

  //---------------------------------------------------------------
  // Typedefs (declared first: the logger and the scoreboard below
  // are both built out of them)
  //---------------------------------------------------------------

  // One entry per packet injected, i.e. the reference every ejection is
  // scored against. It records the decision -- which tile, how long, which
  // VC and KIND -- rather than an expected arrival slot: two packets on
  // different VCs may legally overtake each other, so the order in which
  // independent packets arrive is not a property of this design. What is a
  // property is that each packet's own flits arrive, in order, at its own
  // tile, exactly once, which is what got/len/dr/dc check.
  typedef struct {
    logic [TAG_W-1:0] tag;
    int          sr, sc;   // source tile
    int          dr, dc;   // destination tile -- also the ejection tile
    int          len;
    int          vc;
    // KIND, the 2-bit field at [3:2] of the header (linnea_v2 section 3.2).
    // Deliberately not the VC: the VC is link sideband and changes at every
    // hop, whereas KIND is written once by the source and routers are
    // required to leave it alone. Scoring it is how that is proved.
    int          kind;
    int          got;      // flits of this packet received so far
  } exp_t;

  // The TX queue is ONE queue carrying the source tile alongside the flit,
  // not an array of queues (`tx_t q[N_TILES][$]`): an array of queues with
  // a variable index corrupts silently in this simulator (push_back writes
  // the wrong element). A single queue indexed by a variable is well
  // behaved, and the oldest entry for a given tile is found by a scan, which
  // is exactly the "oldest packet first" order a real link needs anyway.
  typedef struct {
    int          sr, sc;
    int          vc;
    logic [FLIT_W-1:0] data;
  } tx_t;

  exp_t exp_q[$];
  tx_t  tx_q[$];

  // Outstanding-work counters, next to the queues they describe.
  //
  // `work_pending()` is called on every clock edge from the watchdog and on
  // every iteration of wait_idle(), so it has to be O(1) -- and it must
  // contain no loop at all. A previous bench had it walk a queue, and this
  // toolchain hoisted the loop counter out of that loop when inlining the
  // function into the coroutine that runs the tests: the counter was set
  // once, never incremented, and the test spun forever. A counter has no
  // loop to miscompile.
  int  tx_left        = 0;   // flits queued for injection
  int  sb_outstanding = 0;   // packets registered that have not delivered
                             // their last flit yet
  int  sb_got_flits   = 0;   // flits the scoreboard matched
  int  sb_complete    = 0;   // packets that reached len
  int  sb_total_flits = 0;   // flits the generator built
  int  sb_packets     = 0;   // packets the generator built

  function automatic bit work_pending();
    return (tx_left > 0) || (sb_outstanding > 0);
  endfunction

  //---------------------------------------------------------------
  // DUT signals -- the flat packed boundary, and nothing else
  //
  // Each is a whole array at its port endpoint, never an element select;
  // see README "Testbench Wiring Rules".
  //---------------------------------------------------------------
  logic                            clk;
  logic                            rst_n;

  // Injection: this bench is every tile's network interface.
  logic [ROWS-1:0][COLS-1:0][FLIT_W-1:0]   inj_data;
  logic [ROWS-1:0][COLS-1:0]               inj_valid;
  logic [ROWS-1:0][COLS-1:0][VC_W-1:0]     inj_vc;

  // Ejection: the LOCAL output of each tile. Which [row][col] a flit comes
  // out on is the answer to "where did it go", so the scoreboard needs no
  // routing model of its own to check it.
  logic [ROWS-1:0][COLS-1:0][FLIT_W-1:0]   ej_data;
  logic [ROWS-1:0][COLS-1:0]               ej_valid;
  logic [ROWS-1:0][COLS-1:0][VC_W-1:0]     ej_vc;

  // The LOCAL link's credit loop, both halves:
  //   lc_credit    the tile freed a slot in its LOCAL input FIFO -- this
  //                bench's injection budget;
  //   ej_credit    this bench is done with an ejected flit, so the tile's
  //                arbiter may spend that LOCAL output slot again.
  logic [ROWS-1:0][COLS-1:0][NUM_VC-1:0]   lc_credit;
  logic [ROWS-1:0][COLS-1:0][NUM_VC-1:0]   ej_credit;

  noc_mesh #(
      .ROWS          (ROWS),
      .COLS          (COLS),
      .NUM_PORTS     (NUM_PORTS),
      .FLIT_W        (FLIT_W),
      .NUM_VC        (NUM_VC),
      .FIFO_DEPTH    (FIFO_DEPTH),
      .LOCAL_CREDITS (LOCAL_CREDITS)
  ) dut (
      .clk          (clk),
      .rst_n        (rst_n),
      .inj_data     (inj_data),
      .inj_valid    (inj_valid),
      .inj_vc       (inj_vc),
      .ej_data      (ej_data),
      .ej_valid     (ej_valid),
      .ej_vc        (ej_vc),
      .lc_credit    (lc_credit),
      .lc_ds_credit (ej_credit)
  );

  //---------------------------------------------------------------
  // Expected contents of every flit of a packet
  //
  // Rebuilt on demand rather than stored: given the packet and the position
  // within it, the constructor below reproduces the flit exactly, so the
  // scoreboard never has to keep a copy of the stimulus around or walk a
  // queue to find one.
  //---------------------------------------------------------------
  function automatic logic [FLIT_W-1:0] exp_flit(input exp_t p, input int pos);
    if (p.len == 1)
      return mk_ht(3'(p.dc), 3'(p.dr), INJ_ROUTE, 2'(p.kind), p.tag);
    if (pos == 0)
      return mk_head(3'(p.dc), 3'(p.dr), INJ_ROUTE, 2'(p.kind), p.tag);
    if (pos == p.len - 1)
      return mk_tail(p.tag);
    return mk_body(p.tag);
  endfunction

  //---------------------------------------------------------------
  // Traffic generator
  //
  // All-to-all over DISTINCT pairs: a tile never sends to itself, and that
  // is a design property rather than an oversight. Section 2 of the spec
  // enumerates "XY legal (input -> output) pairs, 16 of 25", and
  // LOCAL -> LOCAL is not one of them -- a packet injected at a router has
  // to leave it. route_compute will happily compute DIR_LOCAL for a packet
  // addressed to the tile it was injected on, and the arbiter's xy_legal
  // assertion fires on the grant, which is exactly how this test found it.
  // The spec's table sides with the arbiter, so loopback belongs to the NI
  // and not to the network; the traffic below never asks for it.
  //
  // That also makes 1x1 unusable as a traffic test: with one tile and no
  // self-send there is no legal pair at all, so the configuration is
  // rejected below rather than allowed to pass with zero checks. 2x2 is the
  // default; 3x3 is the smallest geometry with an interior tile that has
  // four neighbours; 1x2 and 2x1 are the smallest that exercise an edge
  // tile sending across the array.
  //---------------------------------------------------------------
  initial begin
    assert (N_TILES >= 2)
    else $fatal(1, "tb_noc_mesh: ROWS*COLS must be >= 2 -- section 2's XY table has no LOCAL->LOCAL pair, so a single tile has nothing legal to send to (got %0dx%0d)", ROWS, COLS);
  end

  logic [TAG_W-1:0] next_tag = '0;

  // Queue one packet of an explicit shape. Both traffic lanes below funnel
  // through here, so the bookkeeping -- the expectation entry, the tag, the
  // per-flit TX entries -- exists once and cannot drift between them.
  task automatic inject_pkt(input int s, input int d, input int len,
                            input int vc, input int kind);
    exp_t pe;
    tx_t  t;
    int   sr, sc, dr, dc;
    logic [FLIT_W-1:0] f;

    sr = s / COLS;  sc = s % COLS;
    dr = d / COLS;  dc = d % COLS;

    pe.tag = next_tag;
    next_tag = next_tag + 1'b1;
    pe.sr = sr;  pe.sc = sc;
    pe.dr = dr;  pe.dc = dc;
    pe.len = len;
    pe.vc  = vc;
    pe.kind = kind;
    pe.got  = 0;
    exp_q.push_back(pe);

    sb_packets++;
    sb_total_flits += len;
    sb_outstanding++;

    for (int pos = 0; pos < len; pos++) begin
      f      = exp_flit(pe, pos);
      t.sr   = sr;
      t.sc   = sc;
      t.vc   = pe.vc;
      t.data = f;
      tx_q.push_back(t);
      tx_left++;
    end
  endtask

  // Lane 1: the shape the pattern picks. Deterministic rather than drawn --
  // an RNG draw would shift every later packet's shape and make "did this
  // change alter the traffic?" unanswerable the first time something moves.
  // Covers 1..MAX_LEN flits, so a lone HEAD_TAIL crosses the mesh as well as
  // a multi-flit packet.
  task automatic inject(input int s, input int d);
    int len;
    len = 1 + ((s * N_TILES + d) % MAX_LEN);
    inject_pkt(s, d, len, (s + d) % NUM_VC, (s + d + len) % 4);
  endtask

  // Lane 2: length chosen only to exceed a link's credit pool.
  //
  // A packet keeps one VC for its whole trip (the arbiter switches each flit
  // out on its input VC), and the credit pool for a (link, VC) pair holds
  // FIFO_DEPTH flits -- the init value in arbiter.sv's credit_init. So a
  // packet of FIFO_DEPTH + 1 flits cannot cross a link unless that link's
  // credit return wire is actually carrying credits back.
  //
  // That matters because it is precisely the wiring this module owns. Lane 1
  // alone tops out at MAX_LEN, and at the default FIFO_DEPTH = 4 that is
  // exactly the pool, so a packet can cross a link on the credits it started
  // with and the network never has to hear an answer: move the northbound
  // credit return to the wrong neighbour port and the 2x2 below still passes,
  // because the heaviest thing it ever asks of that link is three flits on
  // one VC. One extra packet per pair -- and every directed link carries at
  // least one pair's XY path -- forces a credit round-trip through every link
  // instead.
  //
  // This is not a routing model or a timing oracle: nothing here counts hops
  // or measures a latency. It only makes the packets big enough that the
  // wiring has to work.
  task automatic inject_long(input int s, input int d);
    inject_pkt(s, d, FIFO_DEPTH + 1, (s + d) % NUM_VC, (s + d + 1) % 4);
  endtask

  task automatic build_traffic();
    // s == d is skipped on purpose -- see the comment above. The two loops
    // are flat tile indices rather than (row, col) pairs because inject()
    // derives the coordinates; that keeps the nesting at two levels and
    // makes "every ordered pair except the diagonal" read directly.
    for (int s = 0; s < N_TILES; s++)
      for (int d = 0; d < N_TILES; d++)
        if (s != d) begin
          inject(s, d);
          inject_long(s, d);
        end
  endtask

  //---------------------------------------------------------------
  // Injection driver
  //
  // Runs on the negedge, after the edge that delivered this cycle's credit
  // returns, and pushes the oldest queued flit for each tile onto that
  // tile's LOCAL port while its credit budget allows.
  //
  // One flit per tile per cycle, and only if the tile's LOCAL input FIFO
  // has room for that VC: inj_inflight is bumped when a flit is pushed and
  // dropped when lc_credit says a slot came back, so it is the number of
  // flits this bench has in flight into one tile on one VC and must never
  // exceed FIFO_DEPTH, which is how deep that FIFO is.
  //---------------------------------------------------------------
  int inj_inflight [ROWS][COLS][NUM_VC];

  int drv_s;
  int drv_sc;
  int drv_idx;
  int drv_vc;

  always @(negedge clk) begin : inject_driver
    if (!rst_n) begin
      inj_data  = '0;
      inj_valid = '0;
      inj_vc    = '0;
      for (int r = 0; r < ROWS; r++)
        for (int c = 0; c < COLS; c++)
          for (int k = 0; k < NUM_VC; k++)
            inj_inflight[r][c][k] = 0;
    end else begin
      // -- 1. settle credits ------------------------------------------
      for (int r = 0; r < ROWS; r++)
        for (int c = 0; c < COLS; c++)
          for (int k = 0; k < NUM_VC; k++)
            if (lc_credit[r][c][k] && (inj_inflight[r][c][k] > 0))
              inj_inflight[r][c][k]--;

      // -- 2. defaults, then at most one flit per tile ----------------
      inj_data  = '0;
      inj_valid = '0;
      inj_vc    = '0;

      for (int r = 0; r < ROWS; r++) begin
        for (int c = 0; c < COLS; c++) begin
          // The oldest queued flit for this tile. The linear scan preserves
          // arrival order, so a tile can never overtake its own earlier
          // packet, and it keeps every index a plain variable read of the
          // one shared queue.
          drv_idx = -1;
          for (int i = 0; i < tx_q.size(); i++) begin
            if ((tx_q[i].sr == r) && (tx_q[i].sc == c)) begin
              drv_idx = i;
              break;
            end
          end
          if (drv_idx >= 0) begin
            drv_s  = tx_q[drv_idx].sr;
            drv_sc = tx_q[drv_idx].sc;
            drv_vc = tx_q[drv_idx].vc;
            if ((drv_vc < 0) || (drv_vc >= NUM_VC)) begin
              // Reads the whole index rather than letting it decay into an
              // array subscript, so a bad number becomes a reported failure
              // instead of a silently indexed queue.
              check_true($sformatf("injection driver saw vc %0d at tile (%0d,%0d), range 0..%0d",
                                   drv_vc, drv_s, drv_sc, NUM_VC - 1), 1'b0);
            end else if (inj_inflight[r][c][drv_vc] < FIFO_DEPTH) begin
              inj_data[r][c]  = tx_q[drv_idx].data;
              inj_valid[r][c] = 1'b1;
              inj_vc[r][c]    = VC_W'(drv_vc);
              inj_inflight[r][c][drv_vc]++;
              tx_q.delete(drv_idx);
              tx_left--;
            end
          end
        end
      end
    end
  end

  //---------------------------------------------------------------
  // Ejection credit pipe
  //
  // A flit on a tile's LOCAL output puts a credit in this register at the
  // posedge that closes the cycle, so it is visible during the next cycle
  // and the tile's arbiter counts it at the following posedge -- two cycles
  // from "flit on the wire" to "credit usable", the same loop the line
  // bench measures (tb_router_chain's NI pipe, at NI_LAT = 0).
  //
  // One credit per ejected flit, on the VC the flit was switched onto: the
  // arbiter's LOCAL output credits are counted per VC, so returning them on
  // a different VC would refill a pool nobody was drawing from.
  //---------------------------------------------------------------
  always @(posedge clk) begin : ej_credit_pipe
    if (!rst_n) begin
      ej_credit <= '0;
    end else begin
      ej_credit <= '0;
      for (int r = 0; r < ROWS; r++)
        for (int c = 0; c < COLS; c++)
          for (int k = 0; k < NUM_VC; k++)
            if (ej_valid[r][c] && (ej_vc[r][c] == VC_W'(k)))
              ej_credit[r][c][k] <= 1'b1;
    end
  end

  //---------------------------------------------------------------
  // Scoreboard
  //
  // Every ejection is matched back to the packet it belongs to by tag, at
  // the cycle it happens, so a wrong tile or a corrupted flit is reported
  // where it occurred rather than at the end of the run.
  //---------------------------------------------------------------
  int eject_cnt [ROWS][COLS];
  bit sb_en = 1'b0;

  function automatic int find_tag(input logic [TAG_W-1:0] t);
    for (int i = 0; i < exp_q.size(); i++)
      if (exp_q[i].tag == t) return i;
    return -1;
  endfunction

  task automatic sb_eject(input int rr, input int cc, input logic [FLIT_W-1:0] data);
    logic [TAG_W-1:0] t;
    int          idx;
    int          pos;
    exp_t        pe;
    logic [FLIT_W-1:0] want;

    t = flit_tag(data);
    idx = find_tag(t);
    if (idx < 0) begin
      check_true($sformatf("flit %h ejected at (%0d,%0d) was injected by this bench",
                           t, rr, cc), 1'b0);
      return;
    end

    // Read the entry, check it, write the whole thing back: one queue, one
    // computed index, no in-place field write on a queue element.
    pe  = exp_q[idx];
    pos = pe.got;

    if (pos >= pe.len) begin
      check_true($sformatf("packet %h delivers no more than its %0d flits", t, pe.len), 1'b0);
      return;
    end

    want = exp_flit(pe, pos);

    // -- 1. the tile it came out on ----------------------------------
    // The whole routing question this test asks. `rr` and `cc` are which
    // tile's LOCAL port fired; the packet said where it was going when it
    // was built, and those two numbers have to be the same.
    check_true($sformatf("packet %h reaches (%0d,%0d), the tile it was sent to", t, pe.dr, pe.dc),
               (rr == pe.dr) && (cc == pe.dc));

    // -- 2. the flit itself ------------------------------------------
    // A header is allowed to differ in ROUTE and nothing else: every output
    // port on the way replaces that field with its lookahead (noc_output_port
    // line 138 applies the merge to any head). A BODY or TAIL has no such
    // field -- the merge must not reach it -- so it is compared whole, and
    // the filler the package puts at [13:2] of a payload is non-zero exactly
    // so that an unwanted splice changes something visible.
    if (pos == 0)
      check($sformatf("packet %h header survives, ROUTE aside", t),
            data & ~ROUTE_MASK, want & ~ROUTE_MASK);
    else
      check($sformatf("packet %h flit %0d of %0d byte-identical", t, pos, pe.len),
            data, want);

    // -- 3. the fields routers must leave alone ----------------------
    if (pos == 0) begin
      // KIND is written once by the source and routers are not its consumer,
      // so it must come out of any number of hops identical to what was
      // injected -- the whole content of assumption D3 now that this field
      // is KIND rather than a VC id.
      check_true($sformatf("packet %h KIND unchanged by routers", t),
                 flit_kind(data) == flit_kind(want));

      // The terminating router stamps DIR_LOCAL into the lookahead it writes
      // on the way out, because its own route_compute says "this packet ends
      // here". It is the field telling the network interface "this is yours",
      // and since ROUTE is the one header field that is allowed to differ
      // from what was sent, this is also where a missing merge shows up: with
      // INJ_ROUTE on the wire instead, the value can only be the one this
      // bench injected.
      check_true($sformatf("packet %h stamped DIR_LOCAL on its last hop", t),
                 flit_route(data) == DIR_LOCAL);
    end

    // -- tally -------------------------------------------------------
    sb_got_flits++;
    pe.got = pos + 1;
    exp_q[idx] = pe;
    if (pe.got == pe.len) begin
      sb_complete++;
      sb_outstanding--;
    end
  endtask

  //---------------------------------------------------------------
  // Ejection logger
  //
  // Every flit leaving any tile on any port. Only LOCAL carries anything
  // the bench sees as traffic -- the four walls are noc_mesh's own
  // assertion's business -- but scoring runs the moment a flit reaches its
  // destination's network interface so that a wrong route is reported at
  // the cycle it happens.
  //---------------------------------------------------------------
  always @(posedge clk) begin : ej_logger
    if (rst_n) begin
      for (int r = 0; r < ROWS; r++) begin
        for (int c = 0; c < COLS; c++) begin
          if (ej_valid[r][c]) begin
            eject_cnt[r][c]++;
            if (sb_en) sb_eject(r, c, ej_data[r][c]);
          end
        end
      end
    end
  end

  //---------------------------------------------------------------
  // Progress watchdog
  //
  // Not a timeout: it fires only when nothing has been scored for
  // MAX_STALL cycles while work is still outstanding, so a slow run that is
  // still moving is never mistaken for a deadlock. It reports where it
  // stopped, which is the number that says whether the mesh wedged in the
  // network or at the injection boundary.
  //---------------------------------------------------------------
  int  stall_cnt     = 0;
  int  last_scored   = 0;
  bit  deadlock_seen = 1'b0;

  always @(posedge clk) begin : progress_watchdog
    if (!rst_n) begin
      stall_cnt = 0;
    end else begin
      if (sb_got_flits != last_scored) begin
        last_scored = sb_got_flits;
        stall_cnt   = 0;
      end else begin
        stall_cnt++;
      end
      if (!deadlock_seen && work_pending() && (stall_cnt > MAX_STALL)) begin
        deadlock_seen = 1'b1;
        check_true($sformatf("mesh kept making progress (%0d of %0d flits delivered after %0d quiet cycles)",
                             sb_got_flits, sb_total_flits, stall_cnt), 1'b0);
      end
    end
  end

  //---------------------------------------------------------------
  // Wait helpers
  //---------------------------------------------------------------
  task automatic wait_idle(input int max_cycles);
    int n;
    n = 0;
    while (work_pending() && !deadlock_seen && (n < max_cycles)) begin
      @(negedge clk);
      n++;
    end
    check_true($sformatf("all traffic settled within %0d cycles", max_cycles),
               !work_pending());
  endtask

  task automatic settle();
    repeat (20) @(negedge clk);
  endtask

  //---------------------------------------------------------------
  // Per-tile coverage
  //
  // All-to-all traffic means every tile must have ejected at least
  // something. Without this, a mesh where one row was simply never wired
  // would still pass: its packets would never arrive, but the scoreboard
  // only follows packets that did.
  //---------------------------------------------------------------
  task automatic check_coverage();
    for (int r = 0; r < ROWS; r++)
      for (int c = 0; c < COLS; c++)
        check_true($sformatf("tile (%0d,%0d) ejected traffic", r, c),
                   eject_cnt[r][c] > 0);
  endtask

  //---------------------------------------------------------------
  // Final report
  //---------------------------------------------------------------
  task automatic final_report();
    $display("");
    $display("        %0dx%0d mesh: %0d packets, %0d flits injected, %0d flits scored",
             ROWS, COLS, sb_packets, sb_total_flits, sb_got_flits);
    if (deadlock_seen)
      $display("        the watchdog fired -- the run stopped making progress");
    $display("");
    report_stats();
  endtask

  //---------------------------------------------------------------
  // Clock
  //---------------------------------------------------------------
  initial clk = 1'b0;
  always #(CLK_PERIOD / 2) clk = ~clk;

  //---------------------------------------------------------------
  // Main
  //---------------------------------------------------------------
  initial begin : main
    if ($test$plusargs("vcd")) begin
      $dumpfile("sim/noc_mesh.vcd");
      $dumpvars(0, tb_noc_mesh);
    end

    // Reset is held until the traffic exists, so the generator and the
    // injection driver are never in flight at the same time: the driver owns
    // tx_q from the moment rst_n rises, and nothing below touches it again.
    // During reset the driver zeroes its in-flight counts and the mesh's own
    // credit counters, and the logger is gated off by rst_n, so nothing that
    // happens here is scored.
    rst_n = 1'b0;
    repeat (8) @(negedge clk);

    build_traffic();
    sb_en = 1'b1;

    @(negedge clk);
    rst_n = 1'b1;
    @(negedge clk);

    wait_idle(40000);

    // Anything still in flight after the queue drains gets a few cycles to
    // appear, so a straggler is scored rather than silently missed.
    settle();

    // -- completeness ---------------------------------------------------
    // Two independent counts of the same thing: sb_complete is the number of
    // packets that reached their length, sb_got_flits is the number of
    // individual flits matched. Both are compared against totals made when
    // the traffic was built, so a lost flit shows up twice.
    check("every packet fully delivered", sb_complete, sb_packets);
    check("flit conservation (built == scored)", sb_got_flits, sb_total_flits);
    // And the receiver's own tally, counted by port rather than by tag:
    // nothing was delivered outside the scoreboard's view.
    begin
      int total_ejected;
      total_ejected = 0;
      for (int r = 0; r < ROWS; r++)
        for (int c = 0; c < COLS; c++)
          total_ejected += eject_cnt[r][c];
      check("the tiles ejected every injected flit", total_ejected, sb_total_flits);
    end

    check_coverage();

    final_report();
    $finish;
  end

endmodule
