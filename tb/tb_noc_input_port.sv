// Self-checking tests for noc_input_port.

`timescale 1ns / 1ps

module tb_noc_input_port;

  import noc_tb_pkg::*;

  parameter  int NUM_VC = 4;

  parameter  int FIFO_DEPTH = 4;

  localparam int VC_W   = (NUM_VC > 1) ? $clog2(NUM_VC) : 1;

  localparam logic [3:0] DIR_LOCAL = 4'b0000;
  localparam logic [3:0] DIR_NORTH = 4'b0001;
  localparam logic [3:0] DIR_EAST  = 4'b0010;
  localparam logic [3:0] DIR_WEST  = 4'b0100;
  localparam logic [3:0] DIR_SOUTH = 4'b1000;

  localparam logic [2:0] CUR_X = 3'd3;
  localparam logic [2:0] CUR_Y = 3'd3;

  localparam realtime CLK_PERIOD = 10ns;
  localparam realtime SETTLE     = 1ns;

  task automatic report(input string name, input logic [FLIT_W-1:0] actual,
                        input logic [FLIT_W-1:0] expected);
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

  task automatic chk(input string n, input logic [FLIT_W-1:0] a, input logic [FLIT_W-1:0] e);
    report(n, a, e);
  endtask

  task automatic chk4(input string n, input logic [3:0] a, input logic [3:0] e);
    report(n, FLIT_W'(a), FLIT_W'(e));
  endtask

  task automatic chk_vec(input string n, input logic [NUM_VC-1:0] a,
                         input logic [NUM_VC-1:0] e);
    report(n, FLIT_W'(a), FLIT_W'(e));
  endtask

  task automatic chk_vc(input string n, input logic [VC_W-1:0] a,
                        input logic [VC_W-1:0] e);
    report(n, FLIT_W'(a), FLIT_W'(e));
  endtask

  task automatic chk_bit(input string n, input logic a, input logic e);
    report(n, FLIT_W'(a), FLIT_W'(e));
  endtask

  function automatic logic [FLIT_W-1:0] mk_head(input logic [1:0] ftype,
                                          input logic [3:0] route,
                                          input logic [2:0] dest_y,
                                          input logic [2:0] dest_x);
    return mk_hdr(ftype, KIND_WR_REQ, route, dest_y, dest_x, '0);
  endfunction

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

  logic [FLIT_W-1:0] r_flt_data;
  logic        r_flt_valid;
  logic [VC_W-1:0]  r_vc_id;

  logic [NUM_VC-1:0] r_credit;

  logic [NUM_VC-1:0] r_req_va;
  logic [3:0]        r_va_req_out_port [NUM_VC];
  logic [NUM_VC-1:0] r_va_req_single;
  logic [NUM_VC-1:0][VC_W-1:0] r_va_gnt_out_vc;
  for (genvar v = 0; v < NUM_VC; v++) begin : gen_r_allocation
    assign r_va_gnt_out_vc[v] = VC_W'(v);
  end
  logic [NUM_VC-1:0] r_va_gnt;

  logic [NUM_VC-1:0] r_req_sa;
  logic [3:0]        r_sa_req_out_port [NUM_VC];
  logic [VC_W-1:0]        r_sa_req_out_vc [NUM_VC];
  logic [NUM_VC-1:0] r_sa_req_last;
  logic [NUM_VC-1:0] r_sa_gnt;
  logic [NUM_VC-1:0] r_sa_pick;

  logic [FLIT_W-1:0] r_st_flit_data;
  logic [3:0]  r_st_route_next;

  noc_input_port #(
      .NUM_VC        (NUM_VC),
      .DEPTH         (FIFO_DEPTH),
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
  int unsigned       r_n_va, r_n_sa;

  mock_arbiter #(.NUM_VC(NUM_VC)) u_relay_mock (
      .clk           (clk),
      .rst_n         (rst_n),
      .va_req        (r_req_va),
      .va_gnt        (r_m_va_gnt),
      .sa_req        (r_req_sa),
      .sa_gnt        (r_m_sa_gnt),
      .sa_pick       (r_m_sa_pick),
      .n_va_grants   (r_n_va),
      .n_sa_grants   (r_n_sa)
  );

  always_comb begin
    r_va_gnt   = r_m_va_gnt;
    r_sa_gnt   = r_m_sa_gnt;
    r_sa_pick  = r_m_sa_pick;
  end

  task automatic r_step(input logic [FLIT_W-1:0] d, input logic v, input logic [VC_W-1:0] vc);
    @(negedge clk);
    r_flt_data  = d;
    r_flt_valid = v;
    r_vc_id     = vc;
    #SETTLE;
  endtask

  task automatic r_idle();
    r_step(32'h0, 1'b0, VC_W'(0));
  endtask

  logic [FLIT_W-1:0] l_flt_data;
  logic        l_flt_valid;
  logic [VC_W-1:0]  l_vc_id;

  logic [NUM_VC-1:0] l_credit;

  logic [NUM_VC-1:0] l_req_va;
  logic [3:0]        l_va_req_out_port [NUM_VC];
  logic [NUM_VC-1:0] l_va_req_single;
  logic [NUM_VC-1:0][VC_W-1:0] l_va_gnt_out_vc;
  bit remap_local = 0;
  for (genvar v = 0; v < NUM_VC; v++) begin : gen_l_allocation
    assign l_va_gnt_out_vc[v] = VC_W'((v / (NUM_VC/2)) * (NUM_VC/2) +
        ((v + int'(remap_local)) % (NUM_VC/2)));
  end
  logic [NUM_VC-1:0] l_va_gnt;

  logic [NUM_VC-1:0] l_req_sa;
  logic [3:0]        l_sa_req_out_port [NUM_VC];
  logic [VC_W-1:0]        l_sa_req_out_vc [NUM_VC];
  logic [NUM_VC-1:0] l_sa_req_last;
  logic [NUM_VC-1:0] l_sa_gnt;
  logic [NUM_VC-1:0] l_sa_pick;

  logic [FLIT_W-1:0] l_st_flit_data;
  logic [3:0]  l_st_route_next;

  noc_input_port #(
      .NUM_VC        (NUM_VC),
      .DEPTH         (FIFO_DEPTH),
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
  int unsigned       l_n_va, l_n_sa;

  mock_arbiter #(.NUM_VC(NUM_VC)) u_local_mock (
      .clk           (clk),
      .rst_n         (rst_n),
      .va_req        (l_req_va),
      .va_gnt        (l_m_va_gnt),
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
  end

  task automatic l_step(input logic [FLIT_W-1:0] d, input logic v, input logic [VC_W-1:0] vc);
    @(negedge clk);
    l_flt_data  = d;
    l_flt_valid = v;
    l_vc_id     = vc;
    #SETTLE;
  endtask

  task automatic l_idle();
    l_step(32'h0, 1'b0, VC_W'(0));
  endtask

  task automatic test_reset();
    $display("--- T0: idle after reset ---");
    do_reset();

    chk_vec("T0 req_va",            r_req_va,  '0);
    chk_vec("T0 req_sa",            r_req_sa,  '0);
    chk_vec("T0 credit_return",     r_credit,  '0);
    chk("T0 st_flit_data",      r_st_flit_data, '0);
    chk4("T0 st_route_next",     r_st_route_next, '0);
    chk_vec("T0 va_req_single",     r_va_req_single, '0);
    chk_vec("T0 sa_req_last",       r_sa_req_last, '0);
    chk_vec("T0 local req_va",      l_req_va,  '0);
  endtask

  task automatic test_T9_bypass();
    logic [FLIT_W-1:0] pkt;

    $display("--- T9: empty-FIFO bypass ---");
    do_reset();

    pkt = mk_head(FLIT_HEAD_TAIL, DIR_WEST, 3'd1, 3'd1);

    r_step(pkt, 1'b1, VC_W'(0));

    chk_bit("T9 c0 req_va (not yet)",      r_req_va[0], 1'b0);
    chk_bit("T9 c0 credit_return (c1 too)", r_credit[0], 1'b0);

    r_idle();

    chk_bit("T9 c1 req_va",           r_req_va[0], 1'b1);
    chk_bit("T9 c1 va_req_single",    r_va_req_single[0], 1'b1);
    chk4("T9 c1 va_req_out_port",      r_va_req_out_port[0], DIR_WEST);
    chk_bit("T9 c1 credit_return",    r_credit[0], 1'b1);
    chk_bit("T9 c1 req_sa (VA not yet latched)", r_req_sa[0], 1'b0);

    r_idle();

    chk_bit("T9 c2 req_sa",           r_req_sa[0], 1'b1);
    chk4("T9 c2 sa_req_out_port",      r_sa_req_out_port[0], DIR_WEST);
    chk_bit("T9 c2 sa_req_last",      r_sa_req_last[0], 1'b1);
    chk_bit("T9 c2 sa_gnt",           r_sa_gnt[0], 1'b1);
    chk("T9 c2 st_flit_data",         r_st_flit_data, pkt);
    chk_bit("T9 c2 credit_return",    r_credit[0], 1'b0);

    r_idle();

    chk_bit("T9 c3 req_sa",           r_req_sa[0], 1'b0);
    chk_bit("T9 c3 req_va",           r_req_va[0], 1'b0);
    chk_bit("T9 c3 credit_return",    r_credit[0], 1'b0);
  endtask

  task automatic test_T2_three_flit();
    logic [FLIT_W-1:0] H, B, T;
    logic [3:0]   exp_route_next;

    $display("--- T2: 3-flit packet, spec section 3 timeline ---");
    do_reset();

    H = mk_head(FLIT_HEAD, DIR_WEST, 3'd1, 3'd1);
    B = mk_payload(FLIT_BODY, 30'h1234_5678);
    T = mk_payload(FLIT_TAIL, 30'h0BAD_C0DE);

    exp_route_next = DIR_WEST;

    r_step(H, 1'b1, VC_W'(0));
    chk_bit("T2 c0 req_va (H not fetched yet)", r_req_va[0], 1'b0);

    r_step(B, 1'b1, VC_W'(0));
    chk_bit("T2 c1 req_va",             r_req_va[0], 1'b1);
    chk4("T2 c1 va_req_out_port (live)",  r_va_req_out_port[0], DIR_WEST);
    chk_bit("T2 c1 va_req_single",       r_va_req_single[0], 1'b0);
    chk_bit("T2 c1 credit_return",       r_credit[0], 1'b1);
    chk_bit("T2 c1 req_sa (VA pending)", r_req_sa[0], 1'b0);

    r_step(T, 1'b1, VC_W'(0));
    chk_bit("T2 c2 req_sa",              r_req_sa[0], 1'b1);
    chk4("T2 c2 sa_req_out_port",         r_sa_req_out_port[0], DIR_WEST);
    chk_vc("T2 c2 sa_req_out_vc",           r_sa_req_out_vc[0], VC_W'(0));
    chk_bit("T2 c2 sa_req_last",         r_sa_req_last[0], 1'b0);
    chk_bit("T2 c2 sa_gnt",              r_sa_gnt[0], 1'b1);
    chk_bit("T2 c2 sa_pick",             r_sa_pick[0], 1'b1);
    chk("T2 c2 st_flit_data (H)",        r_st_flit_data, H);
    chk4("T2 c2 st_route_next",           r_st_route_next, exp_route_next);
    chk_bit("T2 c2 credit_return",       r_credit[0], 1'b0);

    r_idle();
    chk_bit("T2 c3 req_sa (head held)",  r_req_sa[0], 1'b1);
    chk_bit("T2 c3 sa_gnt",              r_sa_gnt[0], 1'b1);
    chk("T2 c3 st_flit_data (B)",        r_st_flit_data, B);
    chk_bit("T2 c3 sa_req_last",         r_sa_req_last[0], 1'b0);
    chk_bit("T2 c3 credit_return",       r_credit[0], 1'b1);

    r_idle();
    chk_bit("T2 c4 sa_gnt",              r_sa_gnt[0], 1'b1);
    chk("T2 c4 st_flit_data (T)",        r_st_flit_data, T);
    chk_bit("T2 c4 sa_req_last",         r_sa_req_last[0], 1'b1);
    chk_bit("T2 c4 credit_return",       r_credit[0], 1'b1);

    r_idle();
    chk_bit("T2 c5 req_sa",              r_req_sa[0], 1'b0);
    chk_bit("T2 c5 req_va",              r_req_va[0], 1'b0);
    chk_bit("T2 c5 credit_return",       r_credit[0], 1'b0);

    chk("T2 total SA grants", 32'(r_n_sa), 32'd3);
    chk("T2 total VA grants", 32'(r_n_va), 32'd1);
  endtask

  task automatic test_T8_collision();
    logic [FLIT_W-1:0] H, T;

    $display("--- T8: fetch and grant in the same cycle ---");
    do_reset();

    H = mk_head(FLIT_HEAD, DIR_EAST, 3'd5, 3'd5);
    T = mk_payload(FLIT_TAIL, 30'h3333_3333);

    r_step(H, 1'b1, VC_W'(0));
    chk_bit("T8 c0 req_va", r_req_va[0], 1'b0);

    r_idle();
    chk_bit("T8 c1 req_va",           r_req_va[0], 1'b1);
    chk4("T8 c1 va_req_out_port",      r_va_req_out_port[0], DIR_EAST);
    chk_bit("T8 c1 req_sa",           r_req_sa[0], 1'b0);

    r_step(T, 1'b1, VC_W'(0));
    chk_bit("T8 c2 sa_gnt",           r_sa_gnt[0], 1'b1);
    chk("T8 c2 st_flit_data (H)",     r_st_flit_data, H);
    chk_bit("T8 c2 sa_req_last",      r_sa_req_last[0], 1'b0);

    r_idle();
    chk_bit("T8 c3 req_sa (head held across collision)", r_req_sa[0], 1'b1);
    chk_bit("T8 c3 sa_gnt",           r_sa_gnt[0], 1'b1);
    chk("T8 c3 st_flit_data (T)",     r_st_flit_data, T);
    chk_bit("T8 c3 sa_req_last",      r_sa_req_last[0], 1'b1);
    chk_bit("T8 c3 credit_return",    r_credit[0], 1'b1);

    r_idle();
    chk_bit("T8 c4 req_sa",           r_req_sa[0], 1'b0);
    chk_bit("T8 c4 credit_return",    r_credit[0], 1'b0);

    chk("T8 total SA grants", 32'(r_n_sa), 32'd2);
    chk("T8 total VA grants", 32'(r_n_va), 32'd1);
  endtask

  task automatic test_R1_route_capture();
    logic [FLIT_W-1:0] p1, p2;

    $display("--- R1: route capture + live VA output-port mux ---");
    do_reset();

    p1 = mk_head(FLIT_HEAD_TAIL, DIR_NORTH, 3'd1, 3'd3);
    p2 = mk_head(FLIT_HEAD_TAIL, DIR_EAST,  3'd3, 3'd5);

    r_step(p1, 1'b1, VC_W'(0));

    r_idle();
    chk4("R1 c1 pkt1 va_req_out_port", r_va_req_out_port[0], DIR_NORTH);
    chk_bit("R1 c1 req_va",           r_req_va[0], 1'b1);

    r_idle();
    chk4("R1 c2 pkt1 sa_req_out_port", r_sa_req_out_port[0], DIR_NORTH);
    chk_bit("R1 c2 sa_gnt",           r_sa_gnt[0], 1'b1);

    r_step(p2, 1'b1, VC_W'(0));

    r_idle();
    chk4("R1 c4 pkt2 va_req_out_port (LIVE, not stale NORTH)", r_va_req_out_port[0], DIR_EAST);
    chk_bit("R1 c4 req_va",           r_req_va[0], 1'b1);
    chk_bit("R1 c4 req_sa",           r_req_sa[0], 1'b0);

    r_idle();
    chk4("R1 c5 pkt2 sa_req_out_port (LATCHED)", r_sa_req_out_port[0], DIR_EAST);
    chk_bit("R1 c5 sa_gnt",           r_sa_gnt[0], 1'b1);
    chk("R1 c5 st_flit_data",         r_st_flit_data, p2);

    r_idle();
    chk_bit("R1 c6 req_sa",           r_req_sa[0], 1'b0);

    chk("R1 total VA grants", 32'(r_n_va), 32'd2);
    chk("R1 total SA grants", 32'(r_n_sa), 32'd2);
  endtask

  task automatic test_L1_local_port();
    logic [FLIT_W-1:0] pkt;

    $display("--- L1: LOCAL port route compute ---");
    do_reset();

    pkt = mk_head(FLIT_HEAD_TAIL, 4'bxxxx, 3'd3, 3'd5);
    l_step(pkt, 1'b1, VC_W'(0));

    l_idle();
    chk4("L1 east va_req_out_port (LIVE)",  l_va_req_out_port[0], DIR_EAST);

    chk_vec("L1 east credit_return",           l_credit, 2'b01);

    chk_vec("L1 east va_req_single",           l_va_req_single, 2'b01);

    l_idle();
    chk4("L1 east sa_req_out_port (LATCHED)", l_sa_req_out_port[0], DIR_EAST);
    chk_bit("L1 east sa_gnt",              l_sa_gnt[0], 1'b1);
    chk_vec("L1 east sa_req_last",         l_sa_req_last, 2'b01);

    chk_vc("L1 east sa_req_out_vc",          l_sa_req_out_vc[0], VC_W'(0));
    chk("L1 east st_flit_data",            l_st_flit_data, pkt);

    chk4("L1 east st_route_next",          l_st_route_next, DIR_EAST);

    l_idle();
    chk_bit("L1 east done",                l_req_sa[0], 1'b0);

    pkt = mk_head(FLIT_HEAD_TAIL, 4'bxxxx, 3'd5, 3'd3);
    l_step(pkt, 1'b1, VC_W'(0));

    l_idle();
    chk4("L1 south va_req_out_port (LIVE)", l_va_req_out_port[0], DIR_SOUTH);
    chk_vec("L1 south credit_return",          l_credit, 2'b01);
    chk_vec("L1 south va_req_single",          l_va_req_single, 2'b01);

    l_idle();
    chk4("L1 south sa_req_out_port",        l_sa_req_out_port[0], DIR_SOUTH);
    chk_bit("L1 south sa_gnt",             l_sa_gnt[0], 1'b1);
    chk_vec("L1 south sa_req_last",        l_sa_req_last, 2'b01);
    chk_vc("L1 south sa_req_out_vc",         l_sa_req_out_vc[0], VC_W'(0));
    chk("L1 south st_flit_data",           l_st_flit_data, pkt);

    chk4("L1 south st_route_next",         l_st_route_next, DIR_SOUTH);

    l_idle();
    chk_bit("L1 south done",               l_req_sa[0], 1'b0);

    pkt = mk_head(FLIT_HEAD_TAIL, 4'bxxxx, CUR_Y, CUR_X);
    l_step(pkt, 1'b1, VC_W'(0));

    l_idle();
    chk4("L1 self va_req_out_port",         l_va_req_out_port[0], DIR_LOCAL);
    chk_vec("L1 self credit_return",           l_credit, 2'b01);
    chk_vec("L1 self va_req_single",           l_va_req_single, 2'b01);

    l_idle();
    chk4("L1 self sa_req_out_port",         l_sa_req_out_port[0], DIR_LOCAL);
    chk_bit("L1 self sa_gnt",              l_sa_gnt[0], 1'b1);
    chk_vec("L1 self sa_req_last",         l_sa_req_last, 2'b01);
    chk_vc("L1 self sa_req_out_vc",          l_sa_req_out_vc[0], VC_W'(0));
    chk("L1 self st_flit_data",            l_st_flit_data, pkt);
    chk4("L1 self st_route_next",          l_st_route_next, DIR_LOCAL);

    l_idle();
    chk_bit("L1 self done",                l_req_sa[0], 1'b0);

    chk("L1 total VA grants", 32'(l_n_va), 32'd3);
    chk("L1 total SA grants", 32'(l_n_sa), 32'd3);

  endtask

  task automatic test_V1_two_vc();
    logic [FLIT_W-1:0] f0, f1;

    $display("--- V1: two VCs concurrently ---");
    do_reset();

    f0 = mk_head(FLIT_HEAD_TAIL, DIR_NORTH, 3'd1, 3'd3);
    f1 = mk_head(FLIT_HEAD_TAIL, DIR_SOUTH, 3'd5, 3'd3);

    r_step(f0, 1'b1, VC_W'(0));

    r_step(f1, 1'b1, VC_W'(1));
    chk_bit("V1 c1 req_va[0] (VC0 at VA)",        r_req_va[0], 1'b1);
    chk4("V1 c1 VC0 va_req_out_port (LIVE)",       r_va_req_out_port[0], DIR_NORTH);
    chk_bit("V1 c1 req_sa[0] (VA not latched)",   r_req_sa[0], 1'b0);

    chk_bit("V1 c1 req_va[1] (VC1 not fetched)",  r_req_va[1], 1'b0);

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

    r_idle();
    chk_bit("V1 c3 sa_gnt[0] (released)",         r_sa_gnt[0], 1'b0);
    chk_bit("V1 c3 sa_gnt[1]",                    r_sa_gnt[1], 1'b1);
    chk_bit("V1 c3 sa_pick[1]",                   r_sa_pick[1], 1'b1);
    chk("V1 c3 st_flit_data (VC1's)",             r_st_flit_data, f1);
    chk4("V1 c3 VC1 sa_req_out_port",              r_sa_req_out_port[1], DIR_SOUTH);
    chk_bit("V1 c3 VC0 idle",                     r_req_sa[0], 1'b0);

    r_idle();
    chk_bit("V1 c4 req_sa[0]",        r_req_sa[0], 1'b0);
    chk_bit("V1 c4 req_sa[1]",        r_req_sa[1], 1'b0);

    chk("V1 total VA grants", 32'(r_n_va), 32'd2);
    chk("V1 total SA grants", 32'(r_n_sa), 32'd2);
  endtask

  task automatic test_C1_credits();
    logic [FLIT_W-1:0] pkts[6];
    int unsigned credits;
    logic [FLIT_W-1:0] n_before;

    $display("--- C1: credit return accounting ---");
    do_reset();

    credits = 0;
    n_before = 32'(r_n_sa);

    for (int k = 0; k < 6; k++) begin
      pkts[k] = mk_head(FLIT_HEAD_TAIL,
                        ((k % 2) != 0) ? DIR_SOUTH : DIR_EAST,
                        3'd1 + 3'(k),
                        3'd1);
    end

    for (int k = 0; k < 6; k++) begin

      r_step(pkts[k], 1'b1, VC_W'(k % 2));

      @(negedge clk);
      #SETTLE;
      credits += 32'(r_credit[0]) + 32'(r_credit[1]);

      r_flt_data  = '0;
      r_flt_valid = 1'b0;
      r_vc_id     = '0;
      #SETTLE;
    end

    repeat (6) begin
      @(negedge clk);
      #SETTLE;
      credits += 32'(r_credit[0]) + 32'(r_credit[1]);
    end

    chk("C1 credits returned", credits, 32'd6);
    chk("C1 flits switched",   32'(r_n_sa) - n_before, 32'd6);
  endtask

  task automatic test_dynamic_assignment();
    logic [FLIT_W-1:0] h, b, t;
    logic [VC_W-1:0] assigned;
    remap_local = 1;
    h = mk_head(FLIT_HEAD, DIR_EAST, 3'd3, 3'd4);
    b = mk_payload(FLIT_BODY, 30'h1234_5678);
    t = mk_payload(FLIT_TAIL, 30'h0BAD_C0DE);
    for (int v = 0; v < NUM_VC; v++) begin
      assigned = VC_W'((v / (NUM_VC/2)) * (NUM_VC/2) + ((v+1) % (NUM_VC/2)));
      l_step(h, 1, VC_W'(v));
      l_step(b, 1, VC_W'(v));
      chk_bit("D VA requested for each input FIFO", l_req_va[v], 1);
      l_step(t, 1, VC_W'(v));
      chk_vc("D HEAD captures assigned output VC", l_sa_req_out_vc[v], assigned);
      chk("D HEAD payload selected from incoming FIFO", l_st_flit_data, h);

      remap_local = 0;
      l_idle();
      chk_vc("D BODY retains assigned VC", l_sa_req_out_vc[v], assigned);
      chk("D BODY payload", l_st_flit_data, b);
      l_idle();
      chk_vc("D TAIL retains assigned VC", l_sa_req_out_vc[v], assigned);
      chk("D TAIL payload", l_st_flit_data, t);
      l_idle();
      chk_bit("D final transfer clears assignment", l_req_sa[v], 0);
      remap_local = 1;
    end
    remap_local = 0;
  endtask

  initial begin

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
    test_dynamic_assignment();

    $display("========================================");
    $display("Checks : %0d", checks);
    $display("Errors : %0d", errors);
    if (errors == 0) $display("ALL TESTS PASSED");
    else $display("TEST FAILED");
    $display("========================================");
    $finish;
  end

  initial begin
    #(CLK_PERIOD * 2000);
    $display("ERROR: tb_noc_input_port timed out");
    $finish;
  end

  initial begin
    $dumpfile("sim/noc_input_port.vcd");
    $dumpvars(0, tb_noc_input_port);
  end

endmodule
