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
// 3. D3 -- the VC_ID field [3:2] is never rewritten. The authoritative VC is
//    the `vc_id` sideband; rewriting the in-flit field would look fine in a
//    single-router test and corrupt every packet in a chain.
//
//
// Reference model
// ---------------
// The expected merge is recomputed here from first principles rather than
// read out of the DUT:
//
//     expected = data;  if (data[0]) expected[13:10] = route_next;
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

  //---------------------------------------------------------------
  // 1. Parameters
  //---------------------------------------------------------------
  localparam realtime CLK_PERIOD = 10ns;

  localparam logic [1:0] FLIT_BODY      = 2'b00;
  localparam logic [1:0] FLIT_HEAD      = 2'b01;
  localparam logic [1:0] FLIT_TAIL      = 2'b10;
  localparam logic [1:0] FLIT_HEAD_TAIL = 2'b11;

  localparam logic [3:0] DIR_LOCAL = 4'b0000;
  localparam logic [3:0] DIR_NORTH = 4'b0001;
  localparam logic [3:0] DIR_EAST  = 4'b0010;
  localparam logic [3:0] DIR_WEST  = 4'b0100;
  localparam logic [3:0] DIR_SOUTH = 4'b1000;

  // The five legal directions, indexed 0..4, so stimulus can walk them
  // without repeating the literals (section 2).
  localparam logic [3:0] DIR [5] = '{DIR_LOCAL, DIR_NORTH, DIR_EAST, DIR_WEST, DIR_SOUTH};

  // Only [13:10] is allowed to change across the merge.
  localparam logic [31:0] ROUTE_MASK = 32'h0000_3C00;

  //---------------------------------------------------------------
  // 2. DUT I/O signals -- plain scalars throughout
  //---------------------------------------------------------------
  logic        clk;
  logic        rst_n;

  logic [31:0] xbar_out_data;
  logic [3:0]  xbar_out_route_next;
  logic        st_valid;
  logic [1:0]  st_out_vc;

  logic [31:0] flit_data;
  logic        flit_valid;
  logic [1:0]  vc_id;

  //---------------------------------------------------------------
  // 3. Bookkeeping
  //---------------------------------------------------------------
  int checks = 0;
  int errors = 0;

  //---------------------------------------------------------------
  // 4. Clock
  //---------------------------------------------------------------
  initial clk = 0;
  always #(CLK_PERIOD / 2) clk = ~clk;

  //---------------------------------------------------------------
  // 5. DUT
  //---------------------------------------------------------------
  noc_output_port dut (
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
  //---------------------------------------------------------------
  task automatic check(input string what, input logic [31:0] actual,
                       input logic [31:0] expected);
    checks++;
    if (actual === expected) $display("[PASS] %-58s %h", what, actual);
    else begin
      $display("[FAIL] %-58s got %h exp %h", what, actual, expected);
      errors++;
    end
  endtask

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

  // Independent reference for the merge. Written from the spec's wording,
  // not from the DUT's code.
  function automatic logic [31:0] ref_merge(input logic [31:0] d, input logic [3:0] r);
    logic [31:0] m;
    m = d;
    if (d[0]) m[13:10] = r;  // is_head == type[0]
    return m;
  endfunction

  // Build a flit whose type, VC field, route field and payload are all
  // independently controllable, so a merge that touches the wrong field is
  // visible.
  function automatic logic [31:0] make_flit(input logic [1:0] typ, input logic [1:0] vc,
                                            input logic [3:0] route_field, input int tag);
    logic [31:0] f;
    f         = '0;
    f[1:0]    = typ;
    f[3:2]    = vc;
    f[13:10]  = route_field;
    f[31:14]  = 18'((tag * 37) + 1);  // payload / header upper bits
    return f;
  endfunction

  // Drive one cycle: apply stimulus just after a negedge, check the
  // combinational merge, then let the posedge load the link register and
  // check what came out.
  //
  // Doing both halves in one task is deliberate -- the merge and the
  // register have to agree, and a bench that checked only one of them would
  // pass happily on a DUT where the register captured a different word than
  // the one the merge produced.
  task automatic cycle(input string tag, input logic [31:0] d, input logic [3:0] r,
                       input logic v, input logic [1:0] svc);
    logic [31:0] exp_m;

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
            make_flit(typ, 2'b10, stale, tag), look, 1'b1, 2'b11);
    end
  endtask

  // T3: the merge must not touch anything except [13:10]. Checked bit by
  // bit against the incoming word, using payloads chosen so that every
  // other field is non-zero -- an all-zero payload would make this test
  // pass no matter what the merge did to it.
  task automatic t3_only_route_field_changes();
    logic [31:0] d;
    logic [31:0] got;
    logic [3:0]  look;

    // A HEAD: [13:10] changes, everything else must not.
    look = DIR_NORTH;
    d    = make_flit(FLIT_HEAD, 2'b01, DIR_SOUTH, 7);
    cycle("T3 HEAD", d, look, 1'b1, 2'b01);
    got = dut.merged;
    check("T3 HEAD: bits above the route field untouched", got & ~ROUTE_MASK, d & ~ROUTE_MASK);
    check("T3 HEAD: VC field [3:2] untouched (D3)", {30'b0, got[3:2]}, {30'b0, d[3:2]});
    check("T3 HEAD: type field [1:0] untouched", {30'b0, got[1:0]}, {30'b0, d[1:0]});
    check("T3 HEAD: route field replaced", {28'b0, got[13:10]}, {28'b0, look});

    // A TAIL: nothing may change at all.
    d = make_flit(FLIT_TAIL, 2'b11, DIR_WEST, 9);
    cycle("T3 TAIL", d, look, 1'b1, 2'b10);
    got = dut.merged;
    check("T3 TAIL: whole word identical to the input", got, d);
    check("T3 TAIL: route field still payload", {28'b0, got[13:10]}, {28'b0, d[13:10]});
  endtask

  // T4: idle cycles. st_valid low must leave flit_valid low the next cycle
  // AND must not park a stale payload in the register -- the crossbar drives
  // zero when idle, and the register re-zeroes it here, so two independent
  // things have to agree for the wire to be quiet.
  task automatic t4_idle();
    cycle("T4 active", make_flit(FLIT_HEAD_TAIL, 2'b00, DIR_WEST, 11), DIR_LOCAL, 1'b1, 2'b10);
    check("T4 flit_present after the active cycle", {31'b0, flit_valid}, 32'h1);

    // Idle, but with a non-zero payload still sitting on the crossbar --
    // the case where a stale value could survive.
    cycle("T4 idle with stale data", 32'hDEAD_BEEF, 4'b1111, 1'b0, 2'b11);
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
    logic [31:0] d;
    logic [31:0] exp_prev;
    logic [3:0]  look;
    logic [1:0]  svc;
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
      svc  = 2'(i % 4);
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

  // T6: D3 in isolation. The in-flit VC field and the vc_id sideband are
  // allowed to DISAGREE -- that is the whole point of assumption D3 -- and
  // the merge must leave the in-flit copy alone while the sideband carries
  // the authoritative value.
  task automatic t6_vc_field_never_rewritten();
    logic [31:0] d;

    // Flit claims VC 3 in its header, sideband says VC 0.
    d = make_flit(FLIT_HEAD, 2'b11, DIR_SOUTH, 31);
    cycle("T6 head with a disagreeing VC field", d, DIR_WEST, 1'b1, 2'b00);
    check("T6 in-flit VC field [3:2] kept its own value",
          {30'b0, dut.merged[3:2]}, 32'h3);
    check("T6 sideband carries the authoritative VC", {30'b0, vc_id}, 32'h0);
    check("T6 the two are allowed to differ", {30'b0, dut.merged[3:2]} == {30'b0, vc_id},
          32'h0);

    // And a non-head, where [3:2] is payload rather than a VC field at all.
    d = make_flit(FLIT_TAIL, 2'b10, 4'h5, 33);
    cycle("T6 tail whose payload overlaps the VC field", d, DIR_EAST, 1'b1, 2'b01);
    check("T6 tail payload [3:2] preserved", {30'b0, dut.merged[3:2]}, {30'b0, d[3:2]});
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
    logic [1:0] svc;

    for (int i = 0; i < 10; i++) begin : t7_beat
      v   = (i % 3) != 1;  // deliberately interleaves idle cycles
      svc = 2'((i + 1) % 4);
      cycle($sformatf("T7 beat %0d", i), make_flit(FLIT_HEAD, svc, DIR_EAST, 40 + i),
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

    $display("---- T6  D3: the in-flit VC field is never rewritten ----");
    t6_vc_field_never_rewritten();

    $display("---- T7  flit_valid and vc_id paired with their grant ----");
    t7_valid_pairs();

    $display("");
    if (errors == 0) $display("ALL %0d CHECKS PASSED", checks);
    else $display("%0d/%0d CHECKS FAILED", errors, checks);

    $finish;
  end

endmodule
