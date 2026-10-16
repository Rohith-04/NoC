`timescale 1ns / 1ps

//=============================================================================
// tb_crossbar.sv
//
// Verifies rtl/crossbar.sv: the five 5:1 payload muxes, the matching
// lookahead-route muxes, and the "an idle output drives zero" rule from
// section 4.4 of the spec.
//
// The crossbar is pure combinational logic with no clocked state, so the
// whole bench is a stimulus/settle/check loop. A clock is still generated
// because the DUT's assertions sample on it; stimulus is applied just after
// a negedge so that every value is stable a full half-period before the
// posedge that the assertions look at.
//
//
// What "correct" means here
// -------------------------
// The arbiter is trusted for *which* input port wins -- that is its own
// bench's job (tb_arbiter). What has to be true at this seam is narrower:
//
//   1. xbar_out_data[o] and xbar_out_route_next[o] both come from the port
//      named by xbar_sel[o], and from the SAME port (seam 6).
//   2. An output with st_valid[o] low drives zero for both fields, even
//      when xbar_sel[o] still points at something. A held value here would
//      reach noc_output_port and be loaded into the link register as a
//      plausible-looking payload.
//   3. Outputs are independent: one output's selection must not disturb
//      another's.
//
// The stimulus is built so that every field that could be confused is
// different between input ports -- a data pattern that only differed in
// its top byte would let a wrong-port selection pass unnoticed as long as
// the top byte matched.
//=============================================================================

module tb_crossbar;

  // Flit field model and the shared reporter (see noc_tb_pkg.sv).
  import noc_tb_pkg::*;

  //---------------------------------------------------------------
  // 1. Parameters
  //---------------------------------------------------------------
  // FLIT_W is owned by noc_tb_pkg.

  localparam int       NUM_PORTS   = 5;
  localparam realtime  CLK_PERIOD  = 10ns;

  // The five legal direction codes, indexed by input port. Used both to
  // drive route_next and to name ports in messages (section 2).
  localparam logic [3:0] DIR [NUM_PORTS] = '{4'b0000, 4'b0001, 4'b0010, 4'b0100, 4'b1000};

  //---------------------------------------------------------------
  // 2. DUT I/O signals -- all whole packed arrays, which is what the
  //    wiring rule allows at a port endpoint (README "Testbench
  //    Wiring Rules"). Nothing below is ever passed as sig[i].
  //---------------------------------------------------------------
  logic                     clk;
  logic                     rst_n;

  logic [NUM_PORTS-1:0][FLIT_W-1:0] xbar_in_data;
  logic [NUM_PORTS-1:0][3:0]  xbar_in_route_next;
  logic [NUM_PORTS-1:0][2:0]  xbar_sel;
  logic [NUM_PORTS-1:0]       st_valid;

  logic [NUM_PORTS-1:0][FLIT_W-1:0] xbar_out_data;
  logic [NUM_PORTS-1:0][3:0]  xbar_out_route_next;

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
  crossbar #(
      .NUM_PORTS(NUM_PORTS)
  ) dut (
      .clk                (clk),
      .rst_n              (rst_n),
      .xbar_in_data       (xbar_in_data),
      .xbar_in_route_next (xbar_in_route_next),
      .xbar_sel           (xbar_sel),
      .st_valid           (st_valid),
      .xbar_out_data      (xbar_out_data),
      .xbar_out_route_next(xbar_out_route_next)
  );

  //---------------------------------------------------------------
  // 6. Helpers
  //
  // check() comes from noc_tb_pkg.
  //---------------------------------------------------------------

  // Advance to just after a negedge so stimulus lands a half-period clear
  // of the posedge the DUT's assertions sample on.
  task automatic tick();
    @(negedge clk);
    #1;
  endtask

  task automatic reset_dut();
    st_valid           = '0;
    xbar_sel           = '0;
    xbar_in_data       = '0;
    xbar_in_route_next = '0;
    rst_n              = 0;
    repeat (4) @(posedge clk);
    @(negedge clk);
    rst_n = 1;
    #1;
  endtask

  // A payload that is different in every region of the word, so a selection
  // that picks the wrong input port cannot accidentally match: the type
  // bits, the route field, both destination fields and the ID all carry the
  // port index.
  //
  // Built through noc_tb_pkg's setters rather than by slice. It used to
  // stamp `8'(p + 1)` into [31:24] as a second signature as well; that slot
  // straddles BURST and LEN and is not a field in its own right, and with
  // four named regions already carrying p there is nothing left for a wrong
  // pick to hide behind -- so the pattern stays honest and stays named.
  function automatic logic [FLIT_W-1:0] pat(input int p);
    logic [FLIT_W-1:0] v;
    v = '0;
    v = with_id   (v, 8'(7 * p + 3));       // unrelated function of p, breaks runs
    v = with_route(v, 4'(p));               // ROUTE -- carried through untouched
    v = with_dst  (v, 3'(p), 3'((p + 1) % 8));
    v = with_kind (v, 2'(p % 4));           // KIND (ignored by routers, D3)
    v = with_type (v, FLIT_HEAD_TAIL);
    return v;
  endfunction

  // Drive every input with its own unique payload.
  task automatic drive_inputs();
    for (int p = 0; p < NUM_PORTS; p++) begin
      xbar_in_data[p]       = pat(p);
      xbar_in_route_next[p] = DIR[p];
    end
  endtask

  //---------------------------------------------------------------
  // 7. Tests
  //---------------------------------------------------------------

  // T1: nothing selected. Every st_valid low must leave its output at zero
  // even though xbar_sel still names a port carrying a nonzero payload --
  // this is the check that distinguishes "zero because idle" from "zero
  // because the payload happened to be zero".
  task automatic t1_idle_zero();
    int other;
    drive_inputs();
    st_valid = '0;
    // Deliberately point every output at a different, non-zero port.
    for (int o = 0; o < NUM_PORTS; o++) xbar_sel[o] = 3'((o + 2) % NUM_PORTS);
    tick();

    for (int o = 0; o < NUM_PORTS; o++) begin
      check($sformatf("T1 idle output %0d data is zero", o), xbar_out_data[o], 32'h0);
      check($sformatf("T1 idle output %0d route is zero", o), xbar_out_route_next[o], 32'h0);
    end
    // ... and confirm the inputs really were nonzero, otherwise the test
    // above proves nothing.
    other = 0;
    for (int p = 0; p < NUM_PORTS; p++) other |= int'(xbar_in_data[p] != 32'h0);
    check("T1 stimulus really was nonzero", other[0], 1'b1);
  endtask

  // T2: exhaustive. Every (output, selected input) pair, one at a time.
  // With only one output valid, the four idle outputs are checked for
  // zero as well, so each iteration also covers the gating rule.
  task automatic t2_exhaustive();
    for (int o = 0; o < NUM_PORTS; o++) begin
      for (int p = 0; p < NUM_PORTS; p++) begin
        drive_inputs();
        st_valid = '0;
        xbar_sel = '0;
        st_valid[o] = 1'b1;
        xbar_sel[o] = 3'(p);
        tick();

        check($sformatf("T2 out %0d sel %0d data", o, p),
              xbar_out_data[o], xbar_in_data[p]);
        check($sformatf("T2 out %0d sel %0d route_next", o, p),
              xbar_out_route_next[o], {28'h0, xbar_in_route_next[p]});

        // The four outputs that are not selected must be silent.
        for (int q = 0; q < NUM_PORTS; q++) begin
          if (q != o) begin
            check($sformatf("T2 out %0d quiet while out %0d is active", q, o),
                  xbar_out_data[q], 32'h0);
            check($sformatf("T2 out %0d route quiet while out %0d is active", q, o),
                  xbar_out_route_next[q], 32'h0);
          end
        end
      end
    end
  endtask

  // T3: all five outputs active at once, each on a different input. This is
  // the only test that can catch outputs sharing a mux or a selection
  // register -- in T2 at most one output ever changes.
  task automatic t3_all_active();
    int sel_of [NUM_PORTS];

    drive_inputs();
    st_valid = '1;
    // A derangement: output o selects input (o+2)%5, so no output happens to
    // select the index that matches its own, which would hide an o/p mix-up.
    for (int o = 0; o < NUM_PORTS; o++) begin
      sel_of[o]     = (o + 2) % NUM_PORTS;
      xbar_sel[o]   = 3'(sel_of[o]);
    end
    tick();

    for (int o = 0; o < NUM_PORTS; o++) begin
      check($sformatf("T3 out %0d selects input %0d (data)", o, sel_of[o]),
            xbar_out_data[o], xbar_in_data[sel_of[o]]);
      check($sformatf("T3 out %0d selects input %0d (route_next)", o, sel_of[o]),
            xbar_out_route_next[o], {28'h0, xbar_in_route_next[sel_of[o]]});
    end
  endtask

  // T4: one output changing its selection over consecutive cycles. Catches a
  // mux output that holds its previous value instead of re-evaluating --
  // which is what the zero-when-idle rule is really guarding against.
  task automatic t4_reselection();
    // Start with the first selection live and its payload nonzero...
    drive_inputs();
    st_valid      = '0;
    st_valid[0]   = 1'b1;
    xbar_sel      = '0;
    xbar_sel[0]   = 3'd1;
    tick();
    check("T4 out 0 first selection (data)", xbar_out_data[0], xbar_in_data[1]);

    // ... move to another input, same output ...
    xbar_sel[0] = 3'd3;
    tick();
    check("T4 out 0 moved selection (data)", xbar_out_data[0], xbar_in_data[3]);
    check("T4 out 0 moved selection (route)", xbar_out_route_next[0],
          {28'h0, xbar_in_route_next[3]});

    // ... then drop valid while the selection still points at nonzero data.
    // The output has to go to zero; if it held, this is where it shows.
    st_valid[0] = 1'b0;
    tick();
    check("T4 out 0 drops to zero when idle", xbar_out_data[0], 32'h0);
    check("T4 out 0 route drops to zero when idle", xbar_out_route_next[0], 32'h0);

    // ... and comes back with a third selection.
    st_valid[0] = 1'b1;
    xbar_sel[0] = 3'd4;
    tick();
    check("T4 out 0 reselects after idle (data)", xbar_out_data[0], xbar_in_data[4]);
    check("T4 out 0 reselects after idle (route)", xbar_out_route_next[0],
          {28'h0, xbar_in_route_next[4]});
  endtask

  // T5: data and route_next must name the SAME input port (seam 6). The
  // default stimulus makes both fields unique per port, so a mismatch in
  // either direction is caught by T2 -- but that only holds because the two
  // happen to correlate. This test deliberately de-correlates them: two
  // ports carrying identical payloads but different route_next, and two
  // ports carrying different payloads but identical route_next. A crossbar
  // that muxed data from one port and route_next from another still passes
  // T2 and fails here.
  task automatic t5_route_pairs();
    // Ports 1 and 2: same data, different route_next.
    drive_inputs();
    xbar_in_data[2] = xbar_in_data[1];   // ports 1 and 2: same data

    st_valid    = '0;
    st_valid[0] = 1'b1;
    xbar_sel[0] = 3'd1;
    tick();
    check("T5 data from port 1", xbar_out_data[0], xbar_in_data[1]);
    check("T5 route_next from port 1, not port 2", xbar_out_route_next[0],
          {28'h0, xbar_in_route_next[1]});

    xbar_sel[0] = 3'd2;
    tick();
    check("T5 data identical across ports 1 and 2", xbar_out_data[0], xbar_in_data[2]);
    check("T5 route_next must still differ (from port 2)", xbar_out_route_next[0],
          {28'h0, xbar_in_route_next[2]});

    // Ports 3 and 4: different data, same route_next.
    xbar_in_route_next[4] = xbar_in_route_next[3];
    xbar_sel[0]           = 3'd3;
    tick();
    check("T5 data from port 3", xbar_out_data[0], xbar_in_data[3]);
    check("T5 route_next from port 3", xbar_out_route_next[0],
          {28'h0, xbar_in_route_next[3]});

    xbar_sel[0] = 3'd4;
    tick();
    check("T5 data now differs (port 4)", xbar_out_data[0], xbar_in_data[4]);
    check("T5 route_next held at the port 4 value", xbar_out_route_next[0],
          {28'h0, xbar_in_route_next[4]});
  endtask

  //---------------------------------------------------------------
  // 8. Main
  //---------------------------------------------------------------
  initial begin : main
    if ($test$plusargs("vcd")) begin
      $dumpfile($sformatf("sim/%s.vcd", "crossbar"));
      $dumpvars(0, tb_crossbar);
    end

    reset_dut();

    $display("---- T1  idle output drives zero ----");
    t1_idle_zero();

    $display("---- T2  exhaustive (output, selected input) sweep ----");
    t2_exhaustive();

    $display("---- T3  all five outputs active at once ----");
    t3_all_active();

    $display("---- T4  one output re-selecting over time ----");
    t4_reselection();

    $display("---- T5  data and route_next come from the same port ----");
    t5_route_pairs();

    $display("");
    if (errors == 0) $display("ALL %0d CHECKS PASSED", checks);
    else $display("%0d/%0d CHECKS FAILED", errors, checks);

    $finish;
  end

endmodule
