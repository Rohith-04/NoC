// Defines shared flit fields, constructors, and test reporters.

package noc_tb_pkg;

  /* verilator lint_off UNUSEDPARAM */
  /* verilator lint_off UNUSEDSIGNAL */

  localparam int FLIT_W = 40;

  localparam int TAG_W = FLIT_W - 14;

  localparam logic [FLIT_W-1:0] ROUTE_MASK = 'h00003C00;

  localparam logic [1:0] FLIT_BODY      = 2'b00;
  localparam logic [1:0] FLIT_HEAD      = 2'b01;
  localparam logic [1:0] FLIT_TAIL      = 2'b10;
  localparam logic [1:0] FLIT_HEAD_TAIL = 2'b11;

  localparam logic [1:0] KIND_WR_REQ  = 2'b00;
  localparam logic [1:0] KIND_RD_REQ  = 2'b01;
  localparam logic [1:0] KIND_WR_RESP = 2'b10;
  localparam logic [1:0] KIND_RD_RESP = 2'b11;

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

  function automatic logic [1:0] flit_burst(input logic [FLIT_W-1:0] f);
    return f[31:30];
  endfunction

  function automatic logic [7:0] flit_id(input logic [FLIT_W-1:0] f);
    return f[21:14];
  endfunction

  function automatic logic [TAG_W-1:0] flit_tag(input logic [FLIT_W-1:0] f);
    return f[FLIT_W-1:14];
  endfunction

  function automatic bit flit_is_head(input logic [FLIT_W-1:0] f);
    return f[0];
  endfunction

  function automatic bit flit_is_last(input logic [FLIT_W-1:0] f);
    return f[1];
  endfunction

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

  function automatic logic [FLIT_W-1:0] mk_body(input logic [TAG_W-1:0] tag);
    logic [FLIT_W-1:0] f = '0;
    f[1:0]      = FLIT_BODY;
    f[FLIT_W-1:2] = {tag, 12'h201};
    return f;
  endfunction

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
    f[FLIT_W-1:2] = {tag, 12'h401};
    return f;
  endfunction

  function automatic logic [FLIT_W-1:0] ref_merge(input logic [FLIT_W-1:0] d,
                                                  input logic [3:0]        lookahead);
    if (flit_is_head(d)) return with_route(d, lookahead);
    return d;
  endfunction

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

  task automatic report_stats();
    if (errors == 0) $display("ALL %0d CHECKS PASSED", checks);
    else $display("%0d/%0d CHECKS FAILED", errors, checks);
  endtask

  /* verilator lint_on UNUSEDSIGNAL */
  /* verilator lint_on UNUSEDPARAM */

endpackage
