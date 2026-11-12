// Self-checking tests for route_compute.

`timescale 1ns / 1ps

module tb_route_compute;

  localparam logic [3:0] DIR_LOCAL = 4'b0000;
  localparam logic [3:0] DIR_NORTH = 4'b0001;
  localparam logic [3:0] DIR_EAST  = 4'b0010;
  localparam logic [3:0] DIR_WEST  = 4'b0100;
  localparam logic [3:0] DIR_SOUTH = 4'b1000;

  function automatic logic [3:0] ref_dir(input logic [2:0] cx, input logic [2:0] cy,
                                         input logic [2:0] tx, input logic [2:0] ty);
    if (cx != tx) ref_dir = (tx > cx) ? DIR_EAST : DIR_WEST;
    else if (cy != ty) ref_dir = (ty > cy) ? DIR_SOUTH : DIR_NORTH;
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

  logic [2:0] local_dest_x, local_dest_y;
  logic [3:0] local_route_in;
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

  localparam int SWEEP_N = 8;
  localparam int SWEEP_INST = SWEEP_N * SWEEP_N;

  logic [2:0] sw_dest_x;
  logic [2:0] sw_dest_y;
  logic [3:0] sw_route_in;

  logic [SWEEP_INST-1:0][3:0] sw_r_self;
  logic [SWEEP_INST-1:0][3:0] sw_r_next;
  logic [SWEEP_INST-1:0][3:0] sw_l_self;
  logic [SWEEP_INST-1:0][3:0] sw_l_next;

  genvar gx, gy;
  generate
    for (gx = 0; gx < SWEEP_N; gx++) begin : gen_sw_x
      for (gy = 0; gy < SWEEP_N; gy++) begin : gen_sw_y

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

        assign sw_r_self[gx*SWEEP_N+gy] = r_self_i;
        assign sw_r_next[gx*SWEEP_N+gy] = r_next_i;
        assign sw_l_self[gx*SWEEP_N+gy] = l_self_i;
        assign sw_l_next[gx*SWEEP_N+gy] = l_next_i;

      end
    end
  endgenerate

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

  function automatic logic [3:0] ref_next(input logic [2:0] cx, input logic [2:0] cy,
                                          input logic [3:0] self, input logic [2:0] dx,
                                          input logic [2:0] dy);
    if (self == DIR_LOCAL) ref_next = DIR_LOCAL;
    else ref_next = ref_dir(step_x(cx, self), step_y(cy, self), dx, dy);
  endfunction

  function automatic logic [3:0] dir_of(input int k);
    case (k)
      0:       dir_of = DIR_LOCAL;
      1:       dir_of = DIR_NORTH;
      2:       dir_of = DIR_EAST;
      3:       dir_of = DIR_WEST;
      default: dir_of = DIR_SOUTH;
    endcase
  endfunction

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

  task automatic run_sweep();
    logic [3:0] ri, es, en;

    $display("--- Exhaustive sweep over a %0d x %0d coordinate space ---",
             SWEEP_N, SWEEP_N);

    for (int dx = 0; dx < SWEEP_N; dx++) begin
      for (int dy = 0; dy < SWEEP_N; dy++) begin

        sw_dest_x   = 3'(dx);
        sw_dest_y   = 3'(dy);
        sw_route_in = 4'bxxxx;
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

    local_route_in = 4'bxxxx;

    relay_route_in = DIR_EAST;
    relay_dest_x   = 3'd5;
    relay_dest_y   = 3'd3;
    #1;
    check("relay1 route_self", relay_route_self, DIR_EAST);
    check("relay1 route_next", relay_route_next, ref_dir(3'd4, 3'd3, relay_dest_x, relay_dest_y));

    relay_route_in = DIR_EAST;
    relay_dest_x   = 3'd4;
    relay_dest_y   = 3'd3;
    #1;
    check("relay2 route_self", relay_route_self, DIR_EAST);
    check("relay2 route_next", relay_route_next, DIR_LOCAL);

    relay_route_in = DIR_EAST;
    relay_dest_x   = 3'd4;
    relay_dest_y   = 3'd5;
    #1;
    check("relay3 route_self", relay_route_self, DIR_EAST);
    check("relay3 route_next", relay_route_next, DIR_SOUTH);

    relay_route_in = DIR_WEST;
    relay_dest_x   = 3'd1;
    relay_dest_y   = 3'd3;
    #1;
    check("relay4 route_self", relay_route_self, DIR_WEST);
    check("relay4 route_next", relay_route_next, ref_dir(3'd2, 3'd3, relay_dest_x, relay_dest_y));

    relay_route_in = DIR_NORTH;
    relay_dest_x   = 3'd3;
    relay_dest_y   = 3'd1;
    #1;
    check("relay5 route_self", relay_route_self, DIR_NORTH);
    check("relay5 route_next", relay_route_next, ref_dir(3'd3, 3'd2, relay_dest_x, relay_dest_y));

    relay_route_in = DIR_SOUTH;
    relay_dest_x   = 3'd3;
    relay_dest_y   = 3'd6;
    #1;
    check("relay6 route_self", relay_route_self, DIR_SOUTH);
    check("relay6 route_next", relay_route_next, ref_dir(3'd3, 3'd4, relay_dest_x, relay_dest_y));

    relay_route_in = DIR_LOCAL;
    relay_dest_x   = 3'd3;
    relay_dest_y   = 3'd3;
    #1;
    check("relay7 route_self", relay_route_self, DIR_LOCAL);
    check("relay7 route_next", relay_route_next, DIR_LOCAL);

    local_dest_x = 3'd5;
    local_dest_y = 3'd3;
    #1;
    check("local1 route_self", local_route_self, ref_dir(3'd3, 3'd3, local_dest_x, local_dest_y));
    check("local1 route_next", local_route_next, ref_dir(3'd4, 3'd3, local_dest_x, local_dest_y));

    local_dest_x = 3'd4;
    local_dest_y = 3'd3;
    #1;
    check("local2 route_self", local_route_self, DIR_EAST);
    check("local2 route_next", local_route_next, DIR_LOCAL);

    local_dest_x = 3'd3;
    local_dest_y = 3'd5;
    #1;
    check("local3 route_self", local_route_self, DIR_SOUTH);
    check("local3 route_next", local_route_next, ref_dir(3'd3, 3'd4, local_dest_x, local_dest_y));

    local_dest_x = 3'd3;
    local_dest_y = 3'd3;
    #1;
    check("local4 route_self", local_route_self, DIR_LOCAL);
    check("local4 route_next", local_route_next, DIR_LOCAL);

    local_dest_x = 3'd1;
    local_dest_y = 3'd3;
    #1;
    check("local5 route_self", local_route_self, DIR_WEST);
    check("local5 route_next", local_route_next, ref_dir(3'd2, 3'd3, local_dest_x, local_dest_y));

    local_dest_x = 3'd3;
    local_dest_y = 3'd1;
    #1;
    check("local6 route_self", local_route_self, DIR_NORTH);
    check("local6 route_next", local_route_next, ref_dir(3'd3, 3'd2, local_dest_x, local_dest_y));

    run_sweep();

    $display("----------------------------------------");
    if (errors == 0) $display("ALL %0d CHECKS PASSED", checks);
    else $display("%0d / %0d CHECKS FAILED", errors, checks);
    $display("----------------------------------------");

    $finish;
  end

  initial begin
    $dumpfile("sim/route_compute.vcd");
    $dumpvars(0, tb_route_compute);
  end
endmodule
