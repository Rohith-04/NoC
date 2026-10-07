// tb_route_compute.sv
//
// Directed testbench for route_compute. Reference model below is an
// independent reimplementation of XY-DOR -- not a call into the DUT's
// own compute_dir function -- so this actually checks the RTL against
// the spec, not against itself.
//
// Coverage: both port types (relay pass-through vs Local dual-compute),
// all 4 real directions, and the two LOCAL-termination edge cases
// (relay arriving already-terminating, and Local injecting to itself)
// where route_next must be forced LOCAL rather than derived from
// compute_dir on meaningless next-hop coordinates.

`timescale 1ns / 1ps

module tb_route_compute;

  localparam logic [3:0] DIR_LOCAL = 4'b0000;
  localparam logic [3:0] DIR_NORTH = 4'b0001;
  localparam logic [3:0] DIR_EAST  = 4'b0010;
  localparam logic [3:0] DIR_WEST  = 4'b0100;
  localparam logic [3:0] DIR_SOUTH = 4'b1000;

  // ---------------------------------------------------------------
  // Reference model: independent XY-DOR reimplementation.
  // ---------------------------------------------------------------
  function automatic logic [3:0] ref_dir(input logic [2:0] cx, input logic [2:0] cy,
                                         input logic [2:0] tx, input logic [2:0] ty);
    if (cx != tx) ref_dir = (tx > cx) ? DIR_EAST : DIR_WEST;
    else if (cy != ty) ref_dir = (ty > cy) ? DIR_SOUTH : DIR_NORTH;  // Y increases downward
    else ref_dir = DIR_LOCAL;
  endfunction

  int errors = 0;
  int checks = 0;

  task automatic check(input string what, input logic [3:0] actual, input logic [3:0] expected);
    checks++;
    if (actual !== expected) begin
      errors++;
      $display("FAIL: %-24s got=%b  exp=%b", what, actual, expected);
    end else begin
      $display("PASS: %-24s got=%b", what, actual);
    end
  endtask

  // ---------------- DUT: relay port (N/E/S/W), CUR=(3,3) ----------------
  logic [2:0] relay_dest_x, relay_dest_y;
  logic [3:0] relay_route_in;
  logic [3:0] relay_route_self, relay_route_next;

  route_compute #(
      .CUR_X(3'd3),
      .CUR_Y(3'd3),
      .IS_LOCAL_PORT(0)
  ) dut_relay (
      .dest_x    (relay_dest_x),
      .dest_y    (relay_dest_y),
      .route_in  (relay_route_in),
      .route_self(relay_route_self),
      .route_next(relay_route_next)
  );

  // ---------------- DUT: Local port, CUR=(3,3) ----------------
  logic [2:0] local_dest_x, local_dest_y;
  logic [3:0] local_route_in;  // structurally unused when IS_LOCAL_PORT=1
  logic [3:0] local_route_self, local_route_next;

  route_compute #(
      .CUR_X(3'd3),
      .CUR_Y(3'd3),
      .IS_LOCAL_PORT(1)
  ) dut_local (
      .dest_x    (local_dest_x),
      .dest_y    (local_dest_y),
      .route_in  (local_route_in),
      .route_self(local_route_self),
      .route_next(local_route_next)
  );

  // ===============================================================
  // Exhaustive coordinate sweep (spec section 10, step 2)
  //
  // The directed cases above are readable and explain intent, but they only
  // sample a handful of coordinates. This block builds one instance of EACH
  // port type for every point in the 3-bit coordinate space (8x8 = 64
  // positions), so that a single pass over destinations and routes covers
  // every (CUR, dest) pair the hardware can ever see -- 49k comparisons
  // against the reference model below.
  //
  // The two port types differ only in how route_self is obtained, so both
  // are swept through the same driver:
  //
  //   LOCAL  route_self computed from (CUR, dest); route_in is irrelevant,
  //          which is itself under test -- it is driven to 4'bxxxx (which a
  //          2-state engine folds to 4'b0000 = DIR_LOCAL, a *meaningful*
  //          value), so an instance that wrongly reads route_in would
  //          return LOCAL for a destination that is not CUR and fail.
  //
  //   RELAY  route_self must pass route_in straight through, and route_next
  //          must be computed as if one hop had already been taken along it.
  //          route_in sweeps all five codes including DIR_LOCAL, the
  //          "arrives already terminating" edge case.
  // ===============================================================

  localparam int SWEEP_N = 8;  // 3-bit coordinate space: 0..7
  localparam int SWEEP_INST = SWEEP_N * SWEEP_N;  // one instance per CUR point

  // -------------------------------------------------------------------------
  // Wiring rule for this bench -- every module port endpoint is a PLAIN
  // SCALAR signal, never an element of an array.
  //
  // This is not a style preference, it is a hard requirement of the flow: an
  // array element used directly as a port connection never sees a write made
  // after time 0. The connection freezes at its initial value, the stimulus
  // silently never reaches the DUT, and the bench then compares every
  // instance against a permanently stale response while reporting ordinary
  // assertion failures. Nothing warns you -- the first version of this sweep
  // produced 37k failures that were entirely an artifact of the wiring.
  //
  // The workaround, in two parts:
  //
  //   * Stimulus: CUR_X/CUR_Y are elaboration-time parameters, so all 64
  //     instances want the SAME inputs. Three shared plain scalars drive
  //     every instance, and there is only one write per stimulus vector
  //     instead of 64.
  //
  //   * Responses: each instance drives its own generate-scope scalar
  //     (plain, so the port endpoint is fine), which a continuous assign
  //     with a constant genvar index folds into a response bus. Reading that
  //     bus procedurally then works normally.
  //
  // Index the response buses as [cur_x*SWEEP_N + cur_y].
  // -------------------------------------------------------------------------

  // ---- shared stimulus (plain scalars) ----
  logic [2:0] sw_dest_x;
  logic [2:0] sw_dest_y;
  logic [3:0] sw_route_in;

  // ---- response buses (packed vectors, fed by continuous assigns) ----
  logic [SWEEP_INST-1:0][3:0] sw_r_self;
  logic [SWEEP_INST-1:0][3:0] sw_r_next;
  logic [SWEEP_INST-1:0][3:0] sw_l_self;
  logic [SWEEP_INST-1:0][3:0] sw_l_next;

  genvar gx, gy;
  generate
    for (gx = 0; gx < SWEEP_N; gx++) begin : gen_sw_x
      for (gy = 0; gy < SWEEP_N; gy++) begin : gen_sw_y

        // Plain scalars sitting directly on the DUT ports.
        logic [3:0] r_self_i, r_next_i;
        logic [3:0] l_self_i, l_next_i;

        route_compute #(
            .CUR_X(3'(gx)),
            .CUR_Y(3'(gy)),
            .IS_LOCAL_PORT(0)
        ) u_sw_relay (
            .dest_x    (sw_dest_x),
            .dest_y    (sw_dest_y),
            .route_in  (sw_route_in),
            .route_self(r_self_i),
            .route_next(r_next_i)
        );

        route_compute #(
            .CUR_X(3'(gx)),
            .CUR_Y(3'(gy)),
            .IS_LOCAL_PORT(1)
        ) u_sw_local (
            .dest_x    (sw_dest_x),
            .dest_y    (sw_dest_y),
            .route_in  (sw_route_in),
            .route_self(l_self_i),
            .route_next(l_next_i)
        );

        // Constant genvar index, so the hierarchical reference is legal.
        assign sw_r_self[gx*SWEEP_N+gy] = r_self_i;
        assign sw_r_next[gx*SWEEP_N+gy] = r_next_i;
        assign sw_l_self[gx*SWEEP_N+gy] = l_self_i;
        assign sw_l_next[gx*SWEEP_N+gy] = l_next_i;

      end
    end
  endgenerate

  // ---------------------------------------------------------------
  // Reference helpers -- independent reimplementations, never a call
  // into the DUT.
  // ---------------------------------------------------------------

  // Walk one hop along a direction. Y grows downward, so increasing Y is
  // SOUTH. Mirrors the hardware's step 2 (deriving downstream coordinates).
  function automatic logic [2:0] step_x(input logic [2:0] x, input logic [3:0] dir);
    if (dir == DIR_EAST)      step_x = x + 3'd1;
    else if (dir == DIR_WEST) step_x = x - 3'd1;
    else                      step_x = x;
  endfunction

  function automatic logic [2:0] step_y(input logic [2:0] y, input logic [3:0] dir);
    if (dir == DIR_SOUTH)      step_y = y + 3'd1;
    else if (dir == DIR_NORTH) step_y = y - 3'd1;
    else                       step_y = y;
  endfunction

  // Expected lookahead: forced LOCAL when the packet terminates here (the
  // next hop does not exist), otherwise the route a router one hop further
  // along would compute.
  function automatic logic [3:0] ref_next(input logic [2:0] cx, input logic [2:0] cy,
                                          input logic [3:0] self, input logic [2:0] dx,
                                          input logic [2:0] dy);
    if (self == DIR_LOCAL) ref_next = DIR_LOCAL;
    else ref_next = ref_dir(step_x(cx, self), step_y(cy, self), dx, dy);
  endfunction

  // Sweep index -> one-hot direction code (the five legal route_in values).
  function automatic logic [3:0] dir_of(input int k);
    case (k)
      0:       dir_of = DIR_LOCAL;
      1:       dir_of = DIR_NORTH;
      2:       dir_of = DIR_EAST;
      3:       dir_of = DIR_WEST;
      default: dir_of = DIR_SOUTH;
    endcase
  endfunction

  // ---------------------------------------------------------------
  // Quiet comparison for the sweep.
  //
  // ~49k passes would be ~49k lines of log nobody reads, so only failures
  // print. Bookkeeping still feeds the same counters the directed tests
  // use, so the single summary at the end covers both.
  // ---------------------------------------------------------------
  task automatic cmp_sweep(input string what, input logic [3:0] actual,
                           input logic [3:0] expected, input int cx, input int cy,
                           input int dx, input int dy, input logic [3:0] route);
    checks++;
    if (actual !== expected) begin
      errors++;
      $display("[FAIL] %s : CUR=(%0d,%0d) dest=(%0d,%0d) route_in=4'b%b got=%b exp=%b",
               what, cx, cy, dx, dy, route, actual, expected);
    end
  endtask

  // ---------------------------------------------------------------
  // The sweep itself.
  //
  // All 64 CUR positions are driven together because they share the same
  // (dest, route_in) stimulus -- only CUR differs between them. One #1 per
  // stimulus vector, then 64 comparisons, instead of one #1 per comparison.
  // ---------------------------------------------------------------
  task automatic run_sweep();
    logic [3:0] ri, es, en;

    $display("--- Exhaustive sweep over a %0d x %0d coordinate space ---",
             SWEEP_N, SWEEP_N);

    // ---- LOCAL: route_self must be computed, never read from route_in ----
    for (int dx = 0; dx < SWEEP_N; dx++) begin
      for (int dy = 0; dy < SWEEP_N; dy++) begin

        sw_dest_x   = 3'(dx);
        sw_dest_y   = 3'(dy);
        sw_route_in = 4'bxxxx;  // must be ignored entirely
        #1;

        for (int cx = 0; cx < SWEEP_N; cx++) begin
          for (int cy = 0; cy < SWEEP_N; cy++) begin
            es = ref_dir(3'(cx), 3'(cy), 3'(dx), 3'(dy));
            en = ref_next(3'(cx), 3'(cy), es, 3'(dx), 3'(dy));
            cmp_sweep("local route_self", sw_l_self[cx*SWEEP_N+cy], es, cx, cy, dx, dy, 4'd0);
            cmp_sweep("local route_next", sw_l_next[cx*SWEEP_N+cy], en, cx, cy, dx, dy, 4'd0);
          end
        end

      end
    end

    // ---- RELAY: route_self is a pure pass-through of route_in ----
    for (int k = 0; k < 5; k++) begin
      ri = dir_of(k);

      for (int dx = 0; dx < SWEEP_N; dx++) begin
        for (int dy = 0; dy < SWEEP_N; dy++) begin

          sw_dest_x   = 3'(dx);
          sw_dest_y   = 3'(dy);
          sw_route_in = ri;
          #1;

          for (int cx = 0; cx < SWEEP_N; cx++) begin
            for (int cy = 0; cy < SWEEP_N; cy++) begin
              en = ref_next(3'(cx), 3'(cy), ri, 3'(dx), 3'(dy));
              cmp_sweep("relay route_self", sw_r_self[cx*SWEEP_N+cy], ri, cx, cy, dx, dy, 4'(k));
              cmp_sweep("relay route_next", sw_r_next[cx*SWEEP_N+cy], en, cx, cy, dx, dy, 4'(k));
            end
          end

        end
      end
    end

    $display("    sweep complete: %0d comparisons", checks);
  endtask

  initial begin
    // Drive X on the unused input -- if route_self ever depends on it, this
    // will show up as an X on the output and fail the check below.
    //
    // Under Verilator (2-state) an X is folded to 0, so this assignment is a
    // no-op here. It is kept because it is exactly the check that will start
    // working when the design moves to VCS, and because it documents the
    // intent: IS_LOCAL_PORT=1 must never read route_in at all.
    local_route_in = 4'bxxxx;

    // ============= RELAY PORT (N/E/S/W) =============
    // route_self must be an exact pass-through of route_in.

    // 1: EAST relay, dest still 2 hops east -> route_next stays EAST
    relay_route_in = DIR_EAST;
    relay_dest_x   = 3'd5;
    relay_dest_y   = 3'd3;
    #1;
    check("relay1 route_self", relay_route_self, DIR_EAST);
    check("relay1 route_next", relay_route_next, ref_dir(3'd4, 3'd3, relay_dest_x, relay_dest_y));

    // 2: EAST relay, dest exactly 1 hop east -> downstream router IS dest
    relay_route_in = DIR_EAST;
    relay_dest_x   = 3'd4;
    relay_dest_y   = 3'd3;
    #1;
    check("relay2 route_self", relay_route_self, DIR_EAST);
    check("relay2 route_next", relay_route_next, DIR_LOCAL);

    // 3: EAST relay, X corrects next hop, Y still needs SOUTH after that
    relay_route_in = DIR_EAST;
    relay_dest_x   = 3'd4;
    relay_dest_y   = 3'd5;
    #1;
    check("relay3 route_self", relay_route_self, DIR_EAST);
    check("relay3 route_next", relay_route_next, DIR_SOUTH);

    // 4: WEST relay
    relay_route_in = DIR_WEST;
    relay_dest_x   = 3'd1;
    relay_dest_y   = 3'd3;
    #1;
    check("relay4 route_self", relay_route_self, DIR_WEST);
    check("relay4 route_next", relay_route_next, ref_dir(3'd2, 3'd3, relay_dest_x, relay_dest_y));

    // 5: NORTH relay
    relay_route_in = DIR_NORTH;
    relay_dest_x   = 3'd3;
    relay_dest_y   = 3'd1;
    #1;
    check("relay5 route_self", relay_route_self, DIR_NORTH);
    check("relay5 route_next", relay_route_next, ref_dir(3'd3, 3'd2, relay_dest_x, relay_dest_y));

    // 6: SOUTH relay
    relay_route_in = DIR_SOUTH;
    relay_dest_x   = 3'd3;
    relay_dest_y   = 3'd6;
    #1;
    check("relay6 route_self", relay_route_self, DIR_SOUTH);
    check("relay6 route_next", relay_route_next, ref_dir(3'd3, 3'd4, relay_dest_x, relay_dest_y));

    // 7: EDGE CASE -- packet already terminating on arrival (route_in=LOCAL).
    //    route_next MUST be forced LOCAL, not derived from compute_dir on
    //    meaningless next-hop coordinates.
    relay_route_in = DIR_LOCAL;
    relay_dest_x   = 3'd3;
    relay_dest_y   = 3'd3;
    #1;
    check("relay7 route_self", relay_route_self, DIR_LOCAL);
    check("relay7 route_next", relay_route_next, DIR_LOCAL);

    // ============= LOCAL PORT =============
    // route_self is COMPUTED (dual compute_dir call), not passed through.

    // 1: inject, dest 2 hops east
    local_dest_x = 3'd5;
    local_dest_y = 3'd3;
    #1;
    check("local1 route_self", local_route_self, ref_dir(3'd3, 3'd3, local_dest_x, local_dest_y));
    check("local1 route_next", local_route_next, ref_dir(3'd4, 3'd3, local_dest_x, local_dest_y));

    // 2: inject, dest 1 hop east -> route_next LOCAL (downstream router IS dest)
    local_dest_x = 3'd4;
    local_dest_y = 3'd3;
    #1;
    check("local2 route_self", local_route_self, DIR_EAST);
    check("local2 route_next", local_route_next, DIR_LOCAL);

    // 3: inject, X already correct at injection, needs SOUTH
    local_dest_x = 3'd3;
    local_dest_y = 3'd5;
    #1;
    check("local3 route_self", local_route_self, DIR_SOUTH);
    check("local3 route_next", local_route_next, ref_dir(3'd3, 3'd4, local_dest_x, local_dest_y));

    // 4: EDGE CASE -- inject to self (e.g. HEAD_TAIL doorbell to local PE).
    //    route_self resolves LOCAL on the FIRST compute_dir call;
    //    route_next must be forced LOCAL WITHOUT a second call.
    local_dest_x = 3'd3;
    local_dest_y = 3'd3;
    #1;
    check("local4 route_self", local_route_self, DIR_LOCAL);
    check("local4 route_next", local_route_next, DIR_LOCAL);

    // 5: inject WEST
    local_dest_x = 3'd1;
    local_dest_y = 3'd3;
    #1;
    check("local5 route_self", local_route_self, DIR_WEST);
    check("local5 route_next", local_route_next, ref_dir(3'd2, 3'd3, local_dest_x, local_dest_y));

    // 6: inject NORTH
    local_dest_x = 3'd3;
    local_dest_y = 3'd1;
    #1;
    check("local6 route_self", local_route_self, DIR_NORTH);
    check("local6 route_next", local_route_next, ref_dir(3'd3, 3'd2, local_dest_x, local_dest_y));

    // ============= EXHAUSTIVE SWEEP =============
    run_sweep();

    // ============= SUMMARY =============
    $display("----------------------------------------");
    if (errors == 0) $display("ALL %0d CHECKS PASSED", checks);
    else $display("%0d / %0d CHECKS FAILED", errors, checks);
    $display("----------------------------------------");

    $finish;
  end

  //---------------------------------------------------------------
  // Waveform Dump
  //---------------------------------------------------------------
  initial begin
    $dumpfile("sim/route_compute.vcd");
    $dumpvars(0, tb_route_compute);
  end
endmodule
