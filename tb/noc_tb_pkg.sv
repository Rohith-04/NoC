// noc_tb_pkg.sv
//
// The one place the testbenches are allowed to know what a flit *is*.
//
// Before this file existed every bench restated the section 3.2 field map
// for itself: `f[3:2] = kind` here, `data[FLIT_W-1:14]` there, a fifth copy
// of the same `check()` task in each of five files, and a `KIND` write with
// no name to write it under. Every one of those is a place where a field
// map change would have to be found and fixed in several files, and where a
// change applied to only some of them would pass every test still green.
//
// The rule this package exists to enforce is short:
//
//   * a test never names a bit position -- it calls flit_route(), flit_tag(),
//     with_kind(), mk_head(), ...
//   * a test never spells a KIND as 2'b01 -- it writes KIND_RD_REQ
//   * a test never reimplements the pass/fail bookkeeping -- it calls check()
//
// That is deliberately the same shape the UVM environment will take: a
// sequence item with a field model, a scoreboard that reads the fields by
// name, and a reporter. Nothing here is Verilator-specific, so promoting it
// later is a move, not a rewrite.
//
// Ordering: this file must be compiled FIRST -- a package has to exist
// before anything can import it. The Makefile puts it at the head of $(TB)
// for exactly that reason.
//
// Widths: FLIT_W is a localparam here rather than a parameter because the
// package is a namespace, not a module -- there is nothing to override it
// on. The RTL and the benches keep FLIT_W as a *parameter* (linnea_v2
// section 4 item 1) and pass it down to their DUTs; both sides are 40, and
// only ever 40 (section 1's "recorded deviation").

package noc_tb_pkg;

  // Two warnings are silenced for this file only, and both are inherent to
  // what a codec is rather than signs of a problem.
  //
  //   UNUSEDPARAM -- a namespace's members are used by whoever imports it,
  //                  not by the namespace itself. Which of KIND_* a given
  //                  bench happens to spell out is the bench's business.
  //   UNUSEDSIGNAL -- every field accessor by construction reads one slice
  //                  and leaves the rest alone, so `flit_type()` reporting
  //                  "[39:2] not used" is describing correct behaviour, and
  //                  it would say so on every single build.
  //
  // The waiver stops at the end of this file. `make lint` compiles only
  // rtl/*.sv with full -Wall, so the RTL is still held to all of it.
  /* verilator lint_off UNUSEDPARAM */
  /* verilator lint_off UNUSEDSIGNAL */

  //===========================================================================
  // Widths
  //===========================================================================

  // The full flit, linnea_v2 section 3.
  localparam int FLIT_W = 40;

  // The tag: the reserved upper region of a flit, [FLIT_W-1:14], which the
  // routers never read. The benches use it to name a packet so the
  // scoreboard can tell two in-flight packets apart. 26 bits today because
  // everything above the low 14 is fair game at router level; when the NI
  // arrives and claims SRC/ID/LEN for real, this shrinks to the slots that
  // are actually free (section 4 item 6) -- and because there is one
  // definition of it, it shrinks in one place.
  localparam int TAG_W = FLIT_W - 14;

  // Bits [13:10]: the header's ROUTE field, and the only field the output
  // port's lookahead merge is allowed to rewrite.
  localparam logic [FLIT_W-1:0] ROUTE_MASK = 'h00003C00;

  //===========================================================================
  // Constants -- the encodings a test should be able to read out loud
  //===========================================================================

  // Flit type, [1:0]. The two low bits do double duty as `is_head` (bit 0)
  // and `is_last` (bit 1), which is the spelling the RTL uses throughout
  // (section 2: "is_head = type[0]").
  localparam logic [1:0] FLIT_BODY      = 2'b00;
  localparam logic [1:0] FLIT_HEAD      = 2'b01;
  localparam logic [1:0] FLIT_TAIL      = 2'b10;
  localparam logic [1:0] FLIT_HEAD_TAIL = 2'b11;

  // KIND, [3:2] of a header. Written once by the source NI and never read by
  // a router (assumption D3 -- it is not their consumer, so it is not their
  // business), but the scoreboard absolutely checks that it survived the
  // trip. The routers' silence about it is the reason these have to be
  // constants rather than a shared "vc" name: the field used to be VC_ID and
  // the two must never be confused again.
  localparam logic [1:0] KIND_WR_REQ  = 2'b00;
  localparam logic [1:0] KIND_RD_REQ  = 2'b01;
  localparam logic [1:0] KIND_WR_RESP = 2'b10;
  localparam logic [1:0] KIND_RD_RESP = 2'b11;

  //===========================================================================
  // Readers
  //
  // Every accessor takes the whole flit and returns the field. A test that
  // wants to know where a packet is going says `flit_dst_x(h)`, not
  // `h[6:4]` -- so if the map moves, the compiler moves it, and no test
  // quietly keeps reading the old bits.
  //===========================================================================

  function automatic logic [1:0] flit_type(input logic [FLIT_W-1:0] f);
    return f[1:0];
  endfunction

  function automatic logic [1:0] flit_kind(input logic [FLIT_W-1:0] f);
    return f[3:2];
  endfunction

  function automatic logic [2:0] flit_dst_x(input logic [FLIT_W-1:0] f);
    return f[6:4];
  endfunction

  function automatic logic [2:0] flit_dst_y(input logic [FLIT_W-1:0] f);
    return f[9:7];
  endfunction

  function automatic logic [3:0] flit_route(input logic [FLIT_W-1:0] f);
    return f[13:10];
  endfunction

  // BURST, [31:30]. Routers never read it, which makes it the cheapest
  // place for a bench to smuggle attribution through the network -- see
  // tb_router_top's rx_origin.
  function automatic logic [1:0] flit_burst(input logic [FLIT_W-1:0] f);
    return f[31:30];
  endfunction

  function automatic logic [7:0] flit_id(input logic [FLIT_W-1:0] f);
    return f[21:14];
  endfunction

  function automatic logic [TAG_W-1:0] flit_tag(input logic [FLIT_W-1:0] f);
    return f[FLIT_W-1:14];
  endfunction

  // The two predicates the whole design is written in terms of. Restated
  // once, from the encoding, rather than re-derived at each call site from a
  // slice comparison.
  function automatic bit flit_is_head(input logic [FLIT_W-1:0] f);
    return f[0];
  endfunction

  function automatic bit flit_is_last(input logic [FLIT_W-1:0] f);
    return f[1];
  endfunction

  //===========================================================================
  // Setters
  //
  // Pure: take a flit, return a copy with one field replaced. Used both to
  // build stimulus and to state a reference model ("a head's route becomes
  // the lookahead; everything else is untouched") without touching a slice.
  //===========================================================================

  function automatic logic [FLIT_W-1:0] with_type(input logic [FLIT_W-1:0] f,
                                                  input logic [1:0]        t);
    logic [FLIT_W-1:0] r = f;
    r[1:0] = t;
    return r;
  endfunction

  function automatic logic [FLIT_W-1:0] with_kind(input logic [FLIT_W-1:0] f,
                                                  input logic [1:0]        k);
    logic [FLIT_W-1:0] r = f;
    r[3:2] = k;
    return r;
  endfunction

  function automatic logic [FLIT_W-1:0] with_dst(input logic [FLIT_W-1:0] f,
                                                 input logic [2:0]        dy,
                                                 input logic [2:0]        dx);
    logic [FLIT_W-1:0] r = f;
    r[9:7] = dy;
    r[6:4] = dx;
    return r;
  endfunction

  function automatic logic [FLIT_W-1:0] with_route(input logic [FLIT_W-1:0] f,
                                                   input logic [3:0]        route);
    logic [FLIT_W-1:0] r = f;
    r[13:10] = route;
    return r;
  endfunction

  function automatic logic [FLIT_W-1:0] with_id(input logic [FLIT_W-1:0] f,
                                                input logic [7:0]        id);
    logic [FLIT_W-1:0] r = f;
    r[21:14] = id;
    return r;
  endfunction

  function automatic logic [FLIT_W-1:0] with_tag(input logic [FLIT_W-1:0]  f,
                                                 input logic [TAG_W-1:0]   tag);
    logic [FLIT_W-1:0] r = f;
    r[FLIT_W-1:14] = tag;
    return r;
  endfunction

  //===========================================================================
  // Constructors
  //
  // mk_hdr is the whole field map in one call. The shorter names on top of
  // it are what tests actually reach for, and they exist so that a test reads
  // as "a head for (dx,dy) on this route with this kind and this tag" rather
  // than as an assignment list.
  //
  // tb_router_chain and tb_router_top each had byte-identical copies of
  // mk_head/mk_ht/mk_body/mk_tail -- with a comment in the chain bench
  // warning that they "must stay identical to tb_router_top's, because the
  // chain tests compare a received body against the one that was sent". That
  // warning is now redundant: there is one of each.
  //===========================================================================

  function automatic logic [FLIT_W-1:0] mk_hdr(input logic [1:0]        typ,
                                                input logic [1:0]        kind,
                                                input logic [3:0]        route,
                                                input logic [2:0]        dest_y,
                                                input logic [2:0]        dest_x,
                                                input logic [TAG_W-1:0]  tag);
    logic [FLIT_W-1:0] f = '0;
    f[FLIT_W-1:14] = tag;
    f[13:10]       = route;
    f[9:7]         = dest_y;
    f[6:4]         = dest_x;
    f[3:2]         = kind;
    f[1:0]         = typ;
    return f;
  endfunction

  function automatic logic [FLIT_W-1:0] mk_head(input logic [2:0]       dx,
                                                input logic [2:0]       dy,
                                                input logic [3:0]       route,
                                                input logic [1:0]       kind,
                                                input logic [TAG_W-1:0] tag);
    return mk_hdr(FLIT_HEAD, kind, route, dy, dx, tag);
  endfunction

  function automatic logic [FLIT_W-1:0] mk_ht(input logic [2:0]       dx,
                                              input logic [2:0]       dy,
                                              input logic [3:0]       route,
                                              input logic [1:0]       kind,
                                              input logic [TAG_W-1:0] tag);
    return mk_hdr(FLIT_HEAD_TAIL, kind, route, dy, dx, tag);
  endfunction

  // Payload constructors.
  //
  // The filler in [13:2] is deliberately non-zero in [13:10] -- the exact
  // field the output port merges into a header. A real direction value there
  // (rather than a run of zeros) is what makes "the merge leaked onto a
  // BODY/TAIL" observable: the lookahead for these payload bits is never the
  // value they already carry, so an unwanted overwrite changes them. Hence
  // 12'h201 -> [13:10] = DIR_EAST and 12'h401 -> [13:10] = DIR_WEST.
  //
  // `12'h201` and `12'h401` are spelled out rather than assembled from
  // DIR_EAST/DIR_WEST because the point is that the low two bits differ too
  // (the TYPE field of the filler must not be 00 or the flit would look like
  // a BODY to anything reading the wrong slice).
  function automatic logic [FLIT_W-1:0] mk_body(input logic [TAG_W-1:0] tag);
    logic [FLIT_W-1:0] f = '0;
    f[1:0]      = FLIT_BODY;
    f[FLIT_W-1:2] = {tag, 12'h201};   // payload, [13:10] = DIR_EAST
    return f;
  endfunction

  // BODY/TAIL with a free payload: everything above the type field. The
  // input-port bench builds its own payloads rather than a tagged packet,
  // so it needs this rather than mk_body/mk_tail.
  localparam int PAY_W = FLIT_W - 2;

  function automatic logic [FLIT_W-1:0] mk_payload(input logic [1:0]   typ,
                                                   input logic [PAY_W-1:0] payload);
    logic [FLIT_W-1:0] f = '0;
    f[FLIT_W-1:2] = payload;
    f[1:0]        = typ;
    return f;
  endfunction

  function automatic logic [FLIT_W-1:0] mk_tail(input logic [TAG_W-1:0] tag);
    logic [FLIT_W-1:0] f = '0;
    f[1:0]      = FLIT_TAIL;
    f[FLIT_W-1:2] = {tag, 12'h401};   // payload, [13:10] = DIR_WEST
    return f;
  endfunction

  //===========================================================================
  // Reference model for the output port's lookahead merge
  //
  // Written from the spec's wording, not from the DUT's code: a head's route
  // field becomes the lookahead, everything else -- including KIND, per
  // assumption D3 -- survives byte for byte.
  //===========================================================================

  function automatic logic [FLIT_W-1:0] ref_merge(input logic [FLIT_W-1:0] d,
                                                  input logic [3:0]        lookahead);
    if (flit_is_head(d)) return with_route(d, lookahead);
    return d;
  endfunction

  //===========================================================================
  // Bookkeeping -- the shared reporter
  //
  // Counters live here rather than in each bench so that "checks" and
  // "errors" mean the same thing everywhere and a bench cannot quietly grow
  // its own. Each bench runs as its own Verilator binary, so a single static
  // pair is exactly right: no cross-talk, no reset between tests needed
  // beyond what a test does at its start.
  //
  // A bench that has a genuinely different checker shape -- tb_fifo's
  // `check(name, bit)` and tb_route_compute's 4-bit `check`, the input port's
  // chk_vec/chk_vc family -- simply does not import this package (it needs
  // neither the codec nor the reporter) and keeps its own counters. That is
  // a real split rather than a shadowed one: a local declaration would hide
  // the imported name outright, and Verilator says so with VARHIDDEN rather
  // than letting two meanings of `checks` coexist quietly.
  //
  // Every bench that DOES import it -- the five with the wide `check()`, plus
  // the input port, which borrows only the counters -- reports from here.
  //===========================================================================

  int checks = 0;
  int errors = 0;

  task automatic check(input string what, input logic [FLIT_W-1:0] actual,
                       input logic [FLIT_W-1:0] expected);
    checks++;
    if (actual !== expected) begin
      errors++;
      $display("[FAIL] %-62s got %h exp %h", what, actual, expected);
    end else begin
      $display("[PASS] %-62s %h", what, actual);
    end
  endtask

  task automatic check_true(input string what, input bit cond);
    checks++;
    if (cond) $display("[PASS] %-62s", what);
    else begin
      $display("[FAIL] %-62s", what);
      errors++;
    end
  endtask

  // The summary line. Every bench ends with the same two lines so that
  // tools/mutate_*.sh can grep `CHECKS (PASSED|FAILED)` and know nothing
  // about which bench they are looking at.
  task automatic report_stats();
    if (errors == 0) $display("ALL %0d CHECKS PASSED", checks);
    else $display("%0d/%0d CHECKS FAILED", errors, checks);
  endtask

  /* verilator lint_on UNUSEDSIGNAL */
  /* verilator lint_on UNUSEDPARAM */

endpackage
