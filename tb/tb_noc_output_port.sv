`timescale 1ns / 1ps

//=============================================================================
// tb_noc_output_port.sv
//
// Verifies rtl/noc_output_port.sv: the header merge, the link register, and
// the two rules that make them correct together.
//
//
// What is being tested
// --------------------
// 1. THE MERGE (section 4.5, seam 10). A flit arriving from the crossbar
//    carries a STALE route field -- it names the exit port of the *previous*
//    hop. This router's own lookahead route is a separate 4-bit signal and
//    must be spliced into [13:10] -- but only when the flit is a HEAD or a
//    HEAD_TAIL, because for a BODY or a TAIL those same bits are payload.
//
//    Both halves matter. "Heads get the new route" alone would pass while a
//    merge condition that had accidentally become "always" silently
//    corrupts every payload flit, so the non-head case is checked as an
//    explicit equality rather than left as an absence of checks.
//
// 2. THE REGISTER (the LT boundary). flit_valid/flit_data/vc_id are exactly
//    one cycle behind st_valid/st_out_vc -- section 3's "grant in c2, header
//    on the output link in c3". A grant with no flit the next cycle, or a
//    flit with no grant, are both protocol violations at the link.
//
// 3. D3 -- the KIND field [3:2] is never rewritten. The authoritative VC is
//    the `vc_id` sideband; rewriting the in-flit field would look fine in a
//    single-router test and corrupt every packet in a chain.
//
//
// Reference model
// ---------------
// The expected merge is recomputed here from first principles rather than
// read out of the DUT, in the same vocabulary the package states it in
// (noc_tb_pkg.ref_merge):
//
//     expected = data;
//     if (flit_is_head(data)) expected = with_route(data, route_next);
//
// so a bug in the DUT's merge condition cannot be mirrored by an identical
// bug in the checker.
//
//
// Wiring
// ------
// Every port connection is a plain scalar or the whole array (README
// "Testbench Wiring Rules"). The only hierarchical reference is the
// combinational `merged` net, read as a whole signal with no index -- that
// is what lets the merge be checked *before* the register hides a mistake
// inside a one-cycle delay.
//=============================================================================

module tb_noc_output_port;

  // Flit field model and the shared reporter (see noc_tb_pkg.sv).
  import noc_tb_pkg::*;

  //---------------------------------------------------------------
  // 1. Parameters
  //---------------------------------------------------------------
  localparam realtime CLK_PERIOD = 10ns;

  // FLIT_W is owned by noc_tb_pkg; it is still passed to the DUT below so
  // the instance and the bench-side signals are provably the same number.
  // Only used to size the vc_id sideband this module forwards.
  parameter int NUM_VC = 4;
  // VC index width (linnea_v2 section 1): derived rather than independent,
  // so the sideband can never be narrower than the index it carries.
  localparam int VC_W   = (NUM_VC > 1) ? $clog2(NUM_VC) : 1;

  // FLIT_BODY / FLIT_HEAD / FLIT_TAIL / FLIT_HEAD_TAIL and ROUTE_MASK come
  // from the package.

  localparam logic [3:0] DIR_LOCAL = 4'b0000;
  localparam logic [3:0] DIR_NORTH = 4'b0001;
  localparam logic [3:0] DIR_EAST  = 4'b0010;
  localparam logic [3:0] DIR_WEST  = 4'b0100;
  localparam logic [3:0] DIR_SOUTH = 4'b1000;

  // The five legal directions, indexed 0..4, so stimulus can walk them
  // without repeating the literals (section 2).
  localparam logic [3:0] DIR [5] = '{DIR_LOCAL, DIR_NORTH, DIR_EAST, DIR_WEST, DIR_SOUTH};

  // Only [13:10] is allowed to change across the merge -- ROUTE_MASK,
  // which names that field, comes from the package.

  //---------------------------------------------------------------
  // 2. DUT I/O signals -- plain scalars throughout
  //---------------------------------------------------------------
  logic        clk;
  logic        rst_n;

  logic [FLIT_W-1:0] xbar_out_data;
  logic [3:0]  xbar_out_route_next;
  logic        st_valid;
  logic [VC_W-1:0]  st_out_vc;

  logic [FLIT_W-1:0] flit_data;
  logic        flit_valid;
  logic [VC_W-1:0]  vc_id;

  //---------------------------------------------------------------
  // 3. Bookkeeping -- checks, errors and check() come from noc_tb_pkg
  //---------------------------------------------------------------

  //---------------------------------------------------------------
  // 4. Clock
  //---------------------------------------------------------------
  initial clk = 0;
  always #(CLK_PERIOD / 2) clk = ~clk;

  //---------------------------------------------------------------
  // 5. DUT
  //---------------------------------------------------------------
  noc_output_port #(
      // Both must come from the bench, not stay at the module's defaults:
      // this block derives VC_W from NUM_VC to size its own st_out_vc/vc_id
      // sideband, so leaving it at the default makes the link-side signals
      // the bench drives a different width the moment the sweep moves.
      .FLIT_W(FLIT_W),
      .NUM_VC(NUM_VC)
  ) dut (
      .clk                (clk),
      .rst_n              (rst_n),
      .xbar_out_data      (xbar_out_data),
      .xbar_out_route_next(xbar_out_route_next),
      .st_valid           (st_valid),
      .st_out_vc          (st_out_vc),
      .flit_data          (flit_data),
      .flit_valid         (flit_valid),
      .vc_id              (vc_id)
  );

  //---------------------------------------------------------------
  // 6. Helpers
  //
  // check() and ref_merge() come from noc_tb_pkg. ref_merge is deliberately
  // expressed there as "a head's route becomes the lookahead, everything
  // else survives" -- the spec's wording, not this DUT's code.
  //---------------------------------------------------------------

  task automatic reset_dut();
    xbar_out_data       = '0;
    xbar_out_route_next = '0;
    st_valid            = 1'b0;
    st_out_vc           = '0;
    rst_n               = 0;
    repeat (4) @(posedge clk);
    @(negedge clk);
    rst_n = 1;
    #1;
  endtask

  // Build a flit whose type, KIND, route field and payload are all
  // independently controllable, so a merge that touches the wrong field is
  // visible. A thin wrapper over the package's mk_hdr: the field map lives
  // there, this only fixes the argument order the tests here already use.
  function automatic logic [FLIT_W-1:0] make_flit(input logic [1:0] typ, input logic [1:0] kind,
                                            input logic [3:0] route_field, input int tag);
    return mk_hdr(typ, kind, route_field, 3'd0, 3'd0, TAG_W'((tag * 37) + 1));
  endfunction

  // Drive one cycle: apply stimulus just after a negedge, check the
  // combinational merge, then let the posedge load the link register and
  // check what came out.
  //
  // Doing both halves in one task is deliberate -- the merge and the
  // register have to agree, and a bench that checked only one of them would
  // pass happily on a DUT where the register captured a different word than
  // the one the merge produced.
  task automatic cycle(input string tag, input logic [FLIT_W-1:0] d, input logic [3:0] r,
                       input logic v, input logic [VC_W-1:0] svc);
    logic [FLIT_W-1:0] exp_m;

    @(negedge clk);
    xbar_out_data       = d;
    xbar_out_route_next = r;
    st_valid            = v;
    st_out_vc           = svc;
    #1;

    exp_m = ref_merge(d, r);

    // Combinational half: what the merge decided, before the register can
    // hide it behind a delay.
    check($sformatf("%s merge result", tag), dut.merged, exp_m);

    @(posedge clk);
    #1;

    // Registered half: exactly one cycle behind, exactly as selected.
    check($sformatf("%s flit_valid", tag), {31'b0, flit_valid}, {31'b0, v});
    check($sformatf("%s flit_data", tag), flit_data, v ? exp_m : 32'h0);
    check($sformatf("%s vc_id sideband", tag), {30'b0, vc_id}, v ? {30'b0, svc} : 32'h0);
  endtask

  //---------------------------------------------------------------
  // 7. Tests
  //---------------------------------------------------------------

  // T1: reset clears the link register. An unreset flit_valid would look
  // like a flit being held across reset, and an unreset flit_data would put
  // the previous packet's payload on the wire the moment valid came back.
  task automatic t1_reset();
    check("T1 flit_valid low after reset", {31'b0, flit_valid}, 32'h0);
    check("T1 flit_data cleared by reset", flit_data, 32'h0);
    check("T1 vc_id cleared by reset", {30'b0, vc_id}, 32'h0);
  endtask

  // T2: every flit type, with a route field that must be replaced on the
  // heads and preserved on the others. The stale route is deliberately set
  // to a DIFFERENT direction from the lookahead so that a merge that did
  // nothing would produce the stale value and fail.
  task automatic t2_all_types();
    logic [1:0] typ;
    logic [3:0] stale;
    logic [3:0] look;
    int         tag;

    typ   = FLIT_BODY;
    stale = DIR_SOUTH;
    look  = DIR_EAST;

    for (int i = 0; i < 4; i++) begin
      case (i)
        0: typ = FLIT_BODY;
        1: typ = FLIT_HEAD;
        2: typ = FLIT_TAIL;
        default: typ = FLIT_HEAD_TAIL;
      endcase
      tag = i + 1;
      cycle($sformatf("T2 type %02b", typ),
            make_flit(typ, KIND_WR_RESP, stale, tag), look, 1'b1, VC_W'(3 % NUM_VC));
    end
  endtask

  // T3: the merge must not touch anything except [13:10]. Checked bit by
  // bit against the incoming word, using payloads chosen so that every
  // other field is non-zero -- an all-zero payload would make this test
  // pass no matter what the merge did to it.
  task automatic t3_only_route_field_changes();
    logic [FLIT_W-1:0] d;
    logic [FLIT_W-1:0] got;
    logic [3:0]  look;

    // A HEAD: [13:10] changes, everything else must not.
    look = DIR_NORTH;
    d    = make_flit(FLIT_HEAD, KIND_RD_REQ, DIR_SOUTH, 7);
    cycle("T3 HEAD", d, look, 1'b1, VC_W'(1 % NUM_VC));
    got = dut.merged;
    check("T3 HEAD: bits above the route field untouched", got & ~ROUTE_MASK, d & ~ROUTE_MASK);
    check("T3 HEAD: KIND untouched (D3)", flit_kind(got), flit_kind(d));
    check("T3 HEAD: type field untouched", flit_type(got), flit_type(d));
    check("T3 HEAD: route field replaced", flit_route(got), look);

    // A TAIL: nothing may change at all.
    d = make_flit(FLIT_TAIL, KIND_RD_RESP, DIR_WEST, 9);
    cycle("T3 TAIL", d, look, 1'b1, VC_W'(2 % NUM_VC));
    got = dut.merged;
    check("T3 TAIL: whole word identical to the input", got, d);
    check("T3 TAIL: route field still payload", flit_route(got), flit_route(d));
  endtask

  // T4: idle cycles. st_valid low must leave flit_valid low the next cycle
  // AND must not park a stale payload in the register -- the crossbar drives
  // zero when idle, and the register re-zeroes it here, so two independent
  // things have to agree for the wire to be quiet.
  task automatic t4_idle();
    cycle("T4 active", make_flit(FLIT_HEAD_TAIL, KIND_WR_REQ, DIR_WEST, 11), DIR_LOCAL, 1'b1, VC_W'(2 % NUM_VC));
    check("T4 flit_present after the active cycle", {31'b0, flit_valid}, 32'h1);

    // Idle, but with a non-zero payload still sitting on the crossbar --
    // the case where a stale value could survive.
    cycle("T4 idle with stale data", 32'hDEAD_BEEF, 4'b1111, 1'b0, VC_W'(3 % NUM_VC));
    check("T4 flit_valid low after idle", {31'b0, flit_valid}, 32'h0);
    check("T4 flit_data zero after idle", flit_data, 32'h0);
    check("T4 vc_id zero after idle", {30'b0, vc_id}, 32'h0);
  endtask

  // T5: back-to-back traffic, one flit per cycle. This is the steady-state
  // the credit loop is sized for (section 6), and it is where a register
  // that only updated on the rising edge of st_valid would show up: every
  // beat carries a different payload, so a held word is caught directly
  // rather than inferred.
  task automatic t5_back_to_back();
    logic [FLIT_W-1:0] d;
    logic [FLIT_W-1:0] exp_prev;
    logic [3:0]  look;
    logic [VC_W-1:0]  svc;
    bit          have_prev;

    exp_prev  = '0;
    have_prev = 1'b0;

    for (int i = 0; i < 8; i++) begin
      // Alternate head and body so both merge branches are exercised in the
      // same burst, and vary the sideband every cycle so a `vc_id` that was
      // registered once and held is caught.
      if (i % 2 == 0) d = make_flit(FLIT_HEAD, 2'(i % 4), DIR_SOUTH, i + 20);
      else d = make_flit(FLIT_BODY, 2'(i % 4), 4'((i * 3) % 16), i + 20);
      look = DIR[(i + 1) % 5];
      svc  = VC_W'(i % NUM_VC);
      cycle($sformatf("T5 beat %0d", i), d, look, 1'b1, svc);

      // The payload changes every beat, so the register must change with
      // it. A held value means the register only sampled on an edge of
      // st_valid instead of every cycle.
      if (have_prev) check($sformatf("T5 beat %0d is not a repeat", i),
                           flit_data == exp_prev, 1'b0);
      exp_prev  = dut.merged;
      have_prev = 1'b1;
    end
  endtask

  // T6: D3 in isolation. The header's KIND slot and the vc_id sideband are
  // two unrelated fields: KIND is written once by the source NI and read by
  // no router, vc_id is the authoritative VC for the link. The merge must
  // leave the in-flit copy alone while the sideband carries its own value --
  // and it must not confuse one for the other.
  task automatic t6_kind_field_never_rewritten();
    logic [FLIT_W-1:0] d;

    // Flit carries KIND RD_RESP in its header, sideband says VC 0.
    d = make_flit(FLIT_HEAD, KIND_RD_RESP, DIR_SOUTH, 31);
    cycle("T6 head with a KIND the sideband does not share", d, DIR_WEST, 1'b1, VC_W'(0 % NUM_VC));
    check("T6 in-flit KIND kept its own value", flit_kind(dut.merged), KIND_RD_RESP);
    check("T6 sideband carries the authoritative VC", vc_id, VC_W'(0));
    // The flit's KIND must NOT have been overwritten with the sideband VC --
    // the failure a merge that confused the two fields would produce.
    check("T6 KIND did not become the sideband VC", flit_kind(dut.merged) == vc_id, 1'b0);

    // And a non-head, where that slot is payload rather than a header field.
    d = make_flit(FLIT_TAIL, KIND_WR_RESP, 4'h5, 33);
    cycle("T6 tail whose payload overlaps the KIND slot", d, DIR_EAST, 1'b1, VC_W'(1 % NUM_VC));
    check("T6 tail payload in the KIND slot preserved", flit_kind(dut.merged), flit_kind(d));
  endtask

  // T7: a grant must be followed by a flit, and no flit without a grant.
  // cycle() checks that pairing on every beat; this test adds the part it
  // cannot see -- that the sideband is paired with the *same* beat's grant,
  // not merely with some grant, by making vc_id change on cycles where
  // st_valid is low as well as high. A sideband that only updated while
  // valid was high would hold its last value through an idle cycle and be
  // compared against a stale expectation here.
  task automatic t7_valid_pairs();
    logic     v;
    logic [VC_W-1:0] svc;

    for (int i = 0; i < 10; i++) begin : t7_beat
      v   = (i % 3) != 1;  // deliberately interleaves idle cycles
      svc = VC_W'((i + 1) % NUM_VC);
      // The header field is two bits whatever NUM_VC is -- this test does
      // not care what is in it, only that the sideband tracks the grant --
      // so the wider VC index is cut down rather than narrowing the flit.
      cycle($sformatf("T7 beat %0d", i), make_flit(FLIT_HEAD, KIND_WR_REQ, DIR_EAST, 40 + i),
            DIR_NORTH, v, svc);

      if (!v) check($sformatf("T7 beat %0d: sideband does not leak into an idle cycle", i),
                    {30'b0, vc_id}, 32'h0);
    end
  endtask

  //---------------------------------------------------------------
  // 8. Main
  //---------------------------------------------------------------
  initial begin : main
    if ($test$plusargs("vcd")) begin
      $dumpfile("sim/noc_output_port.vcd");
      $dumpvars(0, tb_noc_output_port);
    end

    reset_dut();

    $display("---- T1  reset clears the link register ----");
    t1_reset();

    $display("---- T2  every flit type, stale route vs lookahead ----");
    t2_all_types();

    $display("---- T3  only [13:10] changes ----");
    t3_only_route_field_changes();

    $display("---- T4  idle cycles leave the wire silent ----");
    t4_idle();

    $display("---- T5  back-to-back, one flit per cycle ----");
    t5_back_to_back();

    $display("---- T6  D3: the in-flit KIND field is never rewritten ----");
    t6_kind_field_never_rewritten();

    $display("---- T7  flit_valid and vc_id paired with their grant ----");
    t7_valid_pairs();

    $display("");
    if (errors == 0) $display("ALL %0d CHECKS PASSED", checks);
    else $display("%0d/%0d CHECKS FAILED", errors, checks);

    $finish;
  end

endmodule
