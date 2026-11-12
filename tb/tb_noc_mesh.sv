// Self-checking tests for noc_mesh.

`timescale 1ns / 1ps

module tb_noc_mesh;

  import noc_tb_pkg::*;

  parameter int ROWS = 2;
  parameter int COLS = 2;

  parameter int NUM_VC = 4;

  parameter int FIFO_DEPTH = 4;
  parameter int LOCAL_CREDITS = FIFO_DEPTH;

  parameter int MAX_LEN = 4;

  localparam int          NUM_PORTS  = 5;
  localparam int          VC_W       = (NUM_VC > 1) ? $clog2(NUM_VC) : 1;
  localparam int          N_TILES    = ROWS * COLS;
  localparam realtime     CLK_PERIOD = 10ns;

  localparam int          MAX_STALL  = 500;

  localparam logic [3:0]  DIR_LOCAL = 4'b0000;
  localparam logic [3:0]  DIR_NORTH = 4'b0001;

  localparam logic [3:0]  INJ_ROUTE = DIR_NORTH;

  typedef struct {
    logic [TAG_W-1:0] tag;
    int          sr, sc;
    int          dr, dc;
    int          len;
    int          vc;

    int          kind;
    int          got;
  } exp_t;

  typedef struct {
    int          sr, sc;
    int          vc;
    logic [FLIT_W-1:0] data;
  } tx_t;

  exp_t exp_q[$];
  tx_t  tx_q[$];

  int  tx_left        = 0;
  int  sb_outstanding = 0;

  int  sb_got_flits   = 0;
  int  sb_complete    = 0;
  int  sb_total_flits = 0;
  int  sb_packets     = 0;

  function automatic bit work_pending();
    return (tx_left > 0) || (sb_outstanding > 0);
  endfunction

  logic                            clk;
  logic                            rst_n;

  logic [ROWS-1:0][COLS-1:0][FLIT_W-1:0]   inj_data;
  logic [ROWS-1:0][COLS-1:0]               inj_valid;
  logic [ROWS-1:0][COLS-1:0][VC_W-1:0]     inj_vc;

  logic [ROWS-1:0][COLS-1:0][FLIT_W-1:0]   ej_data;
  logic [ROWS-1:0][COLS-1:0]               ej_valid;
  logic [ROWS-1:0][COLS-1:0][VC_W-1:0]     ej_vc;

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

  function automatic logic [FLIT_W-1:0] exp_flit(input exp_t p, input int pos);
    if (p.len == 1)
      return mk_ht(3'(p.dc), 3'(p.dr), INJ_ROUTE, 2'(p.kind), p.tag);
    if (pos == 0)
      return mk_head(3'(p.dc), 3'(p.dr), INJ_ROUTE, 2'(p.kind), p.tag);
    if (pos == p.len - 1)
      return mk_tail(p.tag);
    return mk_body(p.tag);
  endfunction

  initial begin
    assert (N_TILES >= 2)
    else $fatal(1, "tb_noc_mesh: ROWS*COLS must be >= 2 -- section 2's XY table has no LOCAL->LOCAL pair, so a single tile has nothing legal to send to (got %0dx%0d)", ROWS, COLS);
  end

  logic [TAG_W-1:0] next_tag = '0;

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

  task automatic inject(input int s, input int d);
    int len;
    len = 1 + ((s * N_TILES + d) % MAX_LEN);
    inject_pkt(s, d, len, (s + d) % NUM_VC, (s + d + len) % 4);
  endtask

  task automatic inject_long(input int s, input int d);
    inject_pkt(s, d, FIFO_DEPTH + 1, (s + d) % NUM_VC, (s + d + 1) % 4);
  endtask

  task automatic build_traffic();

    for (int s = 0; s < N_TILES; s++)
      for (int d = 0; d < N_TILES; d++)
        if (s != d) begin
          inject(s, d);
          inject_long(s, d);
        end
  endtask

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

      for (int r = 0; r < ROWS; r++)
        for (int c = 0; c < COLS; c++)
          for (int k = 0; k < NUM_VC; k++)
            if (lc_credit[r][c][k] && (inj_inflight[r][c][k] > 0))
              inj_inflight[r][c][k]--;

      inj_data  = '0;
      inj_valid = '0;
      inj_vc    = '0;

      for (int r = 0; r < ROWS; r++) begin
        for (int c = 0; c < COLS; c++) begin

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

    pe  = exp_q[idx];
    check_true("mesh packet stays in injected traffic class",
               int'(ej_vc[rr][cc]) / (NUM_VC/2) == pe.vc / (NUM_VC/2));
    pos = pe.got;

    if (pos >= pe.len) begin
      check_true($sformatf("packet %h delivers no more than its %0d flits", t, pe.len), 1'b0);
      return;
    end

    want = exp_flit(pe, pos);

    check_true($sformatf("packet %h reaches (%0d,%0d), the tile it was sent to", t, pe.dr, pe.dc),
               (rr == pe.dr) && (cc == pe.dc));

    if (pos == 0)
      check($sformatf("packet %h header survives, ROUTE aside", t),
            data & ~ROUTE_MASK, want & ~ROUTE_MASK);
    else
      check($sformatf("packet %h flit %0d of %0d byte-identical", t, pos, pe.len),
            data, want);

    if (pos == 0) begin

      check_true($sformatf("packet %h KIND unchanged by routers", t),
                 flit_kind(data) == flit_kind(want));

      check_true($sformatf("packet %h stamped DIR_LOCAL on its last hop", t),
                 flit_route(data) == DIR_LOCAL);
    end

    sb_got_flits++;
    pe.got = pos + 1;
    exp_q[idx] = pe;
    if (pe.got == pe.len) begin
      sb_complete++;
      sb_outstanding--;
    end
  endtask

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

  task automatic check_coverage();
    for (int r = 0; r < ROWS; r++)
      for (int c = 0; c < COLS; c++)
        check_true($sformatf("tile (%0d,%0d) ejected traffic", r, c),
                   eject_cnt[r][c] > 0);
  endtask

  task automatic final_report();
    $display("");
    $display("        %0dx%0d mesh: %0d packets, %0d flits injected, %0d flits scored",
             ROWS, COLS, sb_packets, sb_total_flits, sb_got_flits);
    if (deadlock_seen)
      $display("        the watchdog fired -- the run stopped making progress");
    $display("");
    report_stats();
  endtask

  initial clk = 1'b0;
  always #(CLK_PERIOD / 2) clk = ~clk;

  initial begin : main
    if ($test$plusargs("vcd")) begin
      $dumpfile("sim/noc_mesh.vcd");
      $dumpvars(0, tb_noc_mesh);
    end

    rst_n = 1'b0;
    repeat (8) @(negedge clk);

    build_traffic();
    sb_en = 1'b1;

    @(negedge clk);
    rst_n = 1'b1;
    @(negedge clk);

    wait_idle(40000);

    settle();

    check("every packet fully delivered", sb_complete, sb_packets);
    check("flit conservation (built == scored)", sb_got_flits, sb_total_flits);

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
