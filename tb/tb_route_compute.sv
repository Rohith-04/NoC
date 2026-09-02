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

  initial begin
    // Drive X on the unused input -- if route_self ever depends on it,
    // this will show up as an X on the output and fail the check.
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
