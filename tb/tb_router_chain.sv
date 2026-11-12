// Self-checking tests for router_chain.

`timescale 1ns / 1ps

module tb_router_chain;

  import noc_tb_pkg::*;

  localparam int          NUM_PORTS  = 5;
  parameter  int          NUM_VC     = 4;

  localparam int          VC_W       = (NUM_VC > 1) ? $clog2(NUM_VC) : 1;
  localparam int          N_RTR      = 3;
  localparam int          LOCAL_IDX  = 0;
  localparam int          EAST_IDX   = 2;
  localparam int          WEST_IDX   = 3;
  parameter  int          FIFO_DEPTH = 4;
  localparam int          LOCAL_CRED = 4;
  localparam realtime     CLK_PERIOD = 10ns;

  localparam int          NI_LAT     = 0;

  localparam int          MAX_STALL  = 500;

  localparam int          PKT_FLITS  = 16;

  localparam logic [2:0]  Y_COORD    = 3'd1;
  localparam logic [2:0]  X_A        = 3'd0;
  localparam logic [2:0]  X_B        = 3'd1;
  localparam logic [2:0]  X_C        = 3'd2;

  localparam logic [3:0]  DIR_LOCAL = 4'b0000;
  localparam logic [3:0]  DIR_EAST  = 4'b0010;
  localparam logic [3:0]  DIR_WEST  = 4'b0100;

  typedef struct {
    int          rtr;
    int          port;
    int          vc;
    int          cyc;
    logic [FLIT_W-1:0] data;
  } rx_t;

  typedef struct {
    logic [TAG_W-1:0] tag;
    int          src;
    int          dest;
    int          len;
    int          vc;

    int          kind;
    int          got;
  } exp_t;

  typedef struct {
    int          rtr;
    int          vc;
    logic [FLIT_W-1:0] data;
  } tx_t;

  tx_t tx_q[$];

  logic                            clk;
  logic                            rst_n;

  logic [NUM_PORTS-1:0][FLIT_W-1:0]      a_in_data;
  logic [NUM_PORTS-1:0]            a_in_valid;
  logic [NUM_PORTS-1:0][VC_W-1:0]       a_in_vc;
  logic [NUM_PORTS-1:0][FLIT_W-1:0]      a_out_data;
  logic [NUM_PORTS-1:0]            a_out_valid;
  logic [NUM_PORTS-1:0][VC_W-1:0]       a_out_vc;
  logic [NUM_PORTS-1:0][NUM_VC-1:0] a_cred_ret;
  logic [NUM_PORTS-1:0][NUM_VC-1:0] a_ds_cred;

  logic [NUM_PORTS-1:0][FLIT_W-1:0]      b_in_data;
  logic [NUM_PORTS-1:0]            b_in_valid;
  logic [NUM_PORTS-1:0][VC_W-1:0]       b_in_vc;
  logic [NUM_PORTS-1:0][FLIT_W-1:0]      b_out_data;
  logic [NUM_PORTS-1:0]            b_out_valid;
  logic [NUM_PORTS-1:0][VC_W-1:0]       b_out_vc;
  logic [NUM_PORTS-1:0][NUM_VC-1:0] b_cred_ret;
  logic [NUM_PORTS-1:0][NUM_VC-1:0] b_ds_cred;

  logic [NUM_PORTS-1:0][FLIT_W-1:0]      c_in_data;
  logic [NUM_PORTS-1:0]            c_in_valid;
  logic [NUM_PORTS-1:0][VC_W-1:0]       c_in_vc;
  logic [NUM_PORTS-1:0][FLIT_W-1:0]      c_out_data;
  logic [NUM_PORTS-1:0]            c_out_valid;
  logic [NUM_PORTS-1:0][VC_W-1:0]       c_out_vc;
  logic [NUM_PORTS-1:0][NUM_VC-1:0] c_cred_ret;
  logic [NUM_PORTS-1:0][NUM_VC-1:0] c_ds_cred;

  logic [N_RTR-1:0][NUM_PORTS-1:0][FLIT_W-1:0]        r_out_data;
  logic [N_RTR-1:0][NUM_PORTS-1:0]              r_out_valid;
  logic [N_RTR-1:0][NUM_PORTS-1:0][VC_W-1:0]         r_out_vc;
  logic [N_RTR-1:0][NUM_PORTS-1:0][NUM_VC-1:0]  r_cred_ret;

  assign r_out_data[0]  = a_out_data;
  assign r_out_data[1]  = b_out_data;
  assign r_out_data[2]  = c_out_data;

  assign r_out_valid[0] = a_out_valid;
  assign r_out_valid[1] = b_out_valid;
  assign r_out_valid[2] = c_out_valid;

  assign r_out_vc[0]    = a_out_vc;
  assign r_out_vc[1]    = b_out_vc;
  assign r_out_vc[2]    = c_out_vc;

  assign r_cred_ret[0]  = a_cred_ret;
  assign r_cred_ret[1]  = b_cred_ret;
  assign r_cred_ret[2]  = c_cred_ret;

  int    cyc        = 0;
  logic [TAG_W-1:0] tag_seq = 18'h0001;

  initial clk = 1'b0;
  always #(CLK_PERIOD / 2) clk = ~clk;

  always @(posedge clk) cyc <= cyc + 1;

  router_top #(
      .NUM_PORTS    (NUM_PORTS),
      .NUM_VC       (NUM_VC),
      .LOCAL_IDX    (LOCAL_IDX),
      .FIFO_DEPTH   (FIFO_DEPTH),
      .LOCAL_CREDITS(LOCAL_CRED),
      .CUR_X        (X_A),
      .CUR_Y        (Y_COORD),
      .HAS_LOCAL    (1'b1),
      .HAS_NORTH    (1'b0),
      .HAS_EAST     (1'b1),
      .HAS_WEST     (1'b0),
      .HAS_SOUTH    (1'b0)
  ) u_a (
      .clk                (clk),
      .rst_n              (rst_n),
      .in_flit_data       (a_in_data),
      .in_flit_valid      (a_in_valid),
      .in_vc_id           (a_in_vc),
      .out_flit_data      (a_out_data),
      .out_flit_valid     (a_out_valid),
      .out_vc_id          (a_out_vc),
      .credit_return_valid(a_cred_ret),
      .ds_credit_valid    (a_ds_cred)
  );

  router_top #(
      .NUM_PORTS    (NUM_PORTS),
      .NUM_VC       (NUM_VC),
      .LOCAL_IDX    (LOCAL_IDX),
      .FIFO_DEPTH   (FIFO_DEPTH),
      .LOCAL_CREDITS(LOCAL_CRED),
      .CUR_X        (X_B),
      .CUR_Y        (Y_COORD),
      .HAS_LOCAL    (1'b1),
      .HAS_NORTH    (1'b0),
      .HAS_EAST     (1'b1),
      .HAS_WEST     (1'b1),
      .HAS_SOUTH    (1'b0)
  ) u_b (
      .clk                (clk),
      .rst_n              (rst_n),
      .in_flit_data       (b_in_data),
      .in_flit_valid      (b_in_valid),
      .in_vc_id           (b_in_vc),
      .out_flit_data      (b_out_data),
      .out_flit_valid     (b_out_valid),
      .out_vc_id          (b_out_vc),
      .credit_return_valid(b_cred_ret),
      .ds_credit_valid    (b_ds_cred)
  );

  router_top #(
      .NUM_PORTS    (NUM_PORTS),
      .NUM_VC       (NUM_VC),
      .LOCAL_IDX    (LOCAL_IDX),
      .FIFO_DEPTH   (FIFO_DEPTH),
      .LOCAL_CREDITS(LOCAL_CRED),
      .CUR_X        (X_C),
      .CUR_Y        (Y_COORD),
      .HAS_LOCAL    (1'b1),
      .HAS_NORTH    (1'b0),
      .HAS_EAST     (1'b0),
      .HAS_WEST     (1'b1),
      .HAS_SOUTH    (1'b0)
  ) u_c (
      .clk                (clk),
      .rst_n              (rst_n),
      .in_flit_data       (c_in_data),
      .in_flit_valid      (c_in_valid),
      .in_vc_id           (c_in_vc),
      .out_flit_data      (c_out_data),
      .out_flit_valid     (c_out_valid),
      .out_vc_id          (c_out_vc),
      .credit_return_valid(c_cred_ret),
      .ds_credit_valid    (c_ds_cred)
  );

  exp_t exp_q[$];

  bit    sb_en = 1'b0;

  int sb_outstanding = 0;
  int sb_got_flits   = 0;
  int sb_complete    = 0;
  int sb_total_flits = 0;

  localparam bit HAS_EAST_P [N_RTR] = '{1'b1, 1'b1, 1'b0};
  localparam bit HAS_WEST_P [N_RTR] = '{1'b0, 1'b1, 1'b1};
  int eject_cnt  [N_RTR];
  int east_cnt   = 0;
  int west_cnt   = 0;
  int bad_port_cnt = 0;

  task automatic sb_eject(input int rtr, input logic [FLIT_W-1:0] data, input int vc);
    logic [TAG_W-1:0] t;
    int          idx;
    int          pos;
    exp_t        pe;
    logic [1:0]  typ;

    t   = flit_tag(data);
    idx = -1;
    for (int i = 0; i < exp_q.size(); i++) begin
      if (exp_q[i].tag == t) begin
        idx = i;
        break;
      end
    end

    if (idx < 0) begin
      checks++;
      $display("[FAIL] %-64s tag %h at router %0d", "scoreboard: flit nobody injected",
               t, rtr);
      errors++;
      return;
    end

    pe   = exp_q[idx];
    check_true("scoreboard: traffic class preserved across hops",
               vc / (NUM_VC/2) == pe.vc / (NUM_VC/2));
    pos  = pe.got;
    typ  = flit_type(data);

    if (pos >= pe.len) begin
      checks++;
      $display("[FAIL] %-64s tag %h router %0d", "scoreboard: more flits than sent",
               t, rtr);
      errors++;
      return;
    end

    checks++;
    if (pe.dest != rtr) begin
      $display("[FAIL] %-64s tag %h got router %0d exp %0d",
               "scoreboard: ejected at the wrong router", t, rtr, pe.dest);
      errors++;
    end

    begin
      bit type_ok;
      type_ok = 1'b1;
      if (pe.len == 1)      type_ok = (typ == FLIT_HEAD_TAIL);
      else if (pos == 0)    type_ok = (typ == FLIT_HEAD);
      else if (pos == pe.len - 1) type_ok = (typ == FLIT_TAIL);
      else                  type_ok = (typ == FLIT_BODY);
      checks++;
      if (!type_ok) begin
        $display("[FAIL] %-64s tag %h pos %0d/%0d type %b",
                 "scoreboard: flit type sequence broken", t, pos, pe.len, typ);
        errors++;
      end
    end

    if ((pe.len == 1) || (pos == 0)) begin
      checks++;
      if ((flit_dst_x(data) != 3'(pe.dest)) || (flit_dst_y(data) != Y_COORD)) begin
        $display("[FAIL] %-64s tag %h dx %0d dy %0d exp dx %0d dy %0d",
                 "scoreboard: header destination corrupted", t, flit_dst_x(data),
                 flit_dst_y(data), pe.dest, Y_COORD);
        errors++;
      end

      checks++;
      if (flit_route(data) != DIR_LOCAL) begin
        $display("[FAIL] %-64s tag %h route %b", "scoreboard: ejected route field",
                 t, flit_route(data));
        errors++;
      end
      checks++;
      if (flit_kind(data) != 2'(pe.kind)) begin
        $display("[FAIL] %-64s tag %h kind %b exp %b",
                 "scoreboard: header KIND field rewritten", t, flit_kind(data), 2'(pe.kind));
        errors++;
      end
    end

    sb_got_flits++;
    pe.got = pos + 1;
    exp_q[idx] = pe;
    if (pe.got == pe.len) begin
      sb_complete++;
      sb_outstanding--;
    end
  endtask

  function automatic bit work_pending();
    return (tx_q.size() > 0) || (sb_outstanding > 0);
  endfunction

  rx_t rx[$];

  always @(posedge clk) begin : rx_logger
    rx_t e;
    if (rst_n) begin
      for (int r = 0; r < N_RTR; r++) begin
        for (int o = 0; o < NUM_PORTS; o++) begin
          if (r_out_valid[r][o]) begin

            e.rtr  = r;
            e.port = o;
            e.vc   = int'(r_out_vc[r][o]);
            e.cyc  = cyc;
            e.data = r_out_data[r][o];
            rx.push_back(e);

            if (o == LOCAL_IDX) eject_cnt[r]++;
            else if (o == EAST_IDX) begin
              if (HAS_EAST_P[r]) east_cnt++; else bad_port_cnt++;
            end
            else if (o == WEST_IDX) begin
              if (HAS_WEST_P[r]) west_cnt++; else bad_port_cnt++;
            end
            else bad_port_cnt++;

            if ((o == LOCAL_IDX) && sb_en) sb_eject(r, e.data, e.vc);
          end
        end
      end
    end
  end

  bit link_packet [N_RTR][NUM_PORTS][NUM_VC];
  logic [TAG_W-1:0] link_tag [N_RTR][NUM_PORTS][NUM_VC];
  always @(posedge clk) begin : check_link_packets
    if (!rst_n) begin
      for (int r = 0; r < N_RTR; r++)
        for (int o = 0; o < NUM_PORTS; o++)
          for (int v = 0; v < NUM_VC; v++) begin
            link_packet[r][o][v] = 0;
            link_tag[r][o][v] = '0;
          end
    end else begin
      for (int r = 0; r < N_RTR; r++)
        for (int o = 0; o < NUM_PORTS; o++)
          if (r_out_valid[r][o]) begin
            logic [VC_W-1:0] v;
            v = r_out_vc[r][o];
            if (flit_is_head(r_out_data[r][o])) begin
              check_true("link VC has no overlapping packet heads", !link_packet[r][o][v]);
              link_tag[r][o][v] = flit_tag(r_out_data[r][o]);
            end else begin
              check_true("link BODY/TAIL belongs to active packet", link_packet[r][o][v]);
              check_true("link packets never interleave on one VC", link_tag[r][o][v] == flit_tag(r_out_data[r][o]));
            end
            link_packet[r][o][v] = !flit_is_last(r_out_data[r][o]);
          end
    end
  end

  task automatic clear_rx();
    rx.delete();
    for (int r = 0; r < N_RTR; r++) eject_cnt[r] = 0;
    east_cnt     = 0;
    west_cnt     = 0;
    bad_port_cnt = 0;
  endtask

  function automatic int rx_n();
    return rx.size();
  endfunction

  function automatic logic [TAG_W-1:0] rx_tag(input int i);
    return flit_tag(rx[i].data);
  endfunction

  function automatic logic [1:0] rx_type(input int i);
    return flit_type(rx[i].data);
  endfunction

  function automatic logic [3:0] rx_route(input int i);
    return flit_route(rx[i].data);
  endfunction

  function automatic int hop_n(input int rtr, input int port, input logic [TAG_W-1:0] tag);
    int n;
    n = 0;
    for (int i = 0; i < rx.size(); i++) begin
      if ((rx[i].rtr == rtr) && (rx[i].port == port) && (flit_tag(rx[i].data) == tag)) n++;
    end
    return n;
  endfunction

  function automatic int max_gap(input int rtr, input int port, input logic [TAG_W-1:0] tag);
    int last;
    int g;
    int m;
    last = -1;
    m    = 0;
    for (int i = 0; i < rx.size(); i++) begin
      if ((rx[i].rtr == rtr) && (rx[i].port == port) && (flit_tag(rx[i].data) == tag)) begin
        if (last >= 0) begin
          g = rx[i].cyc - last;
          if (g > m) m = g;
        end
        last = rx[i].cyc;
      end
    end
    return m;
  endfunction

  function automatic int find_tag(input logic [TAG_W-1:0] tag);
    for (int i = 0; i < rx.size(); i++) begin
      if (flit_tag(rx[i].data) == tag) return i;
    end
    return -1;
  endfunction

  logic [N_RTR-1:0][NI_LAT:0][NUM_VC-1:0] ni_pipe;

  always @(posedge clk) begin : ni_credit_pipe
    if (!rst_n) begin
      ni_pipe <= '0;
    end else begin
      for (int r = 0; r < N_RTR; r++) begin
        ni_pipe[r][0] <= '0;
        for (int k = 0; k < NUM_VC; k++) begin

          if (r_out_valid[r][LOCAL_IDX] && (r_out_vc[r][LOCAL_IDX] == VC_W'(k))) begin
            ni_pipe[r][0][k] <= 1'b1;
          end
        end
        for (int s = 1; s <= NI_LAT; s++) ni_pipe[r][s] <= ni_pipe[r][s-1];
      end
    end
  end

  always_comb begin : ds_credit_assembly
    a_ds_cred = '0;
    b_ds_cred = '0;
    c_ds_cred = '0;

    a_ds_cred[EAST_IDX]  = b_cred_ret[WEST_IDX];
    b_ds_cred[WEST_IDX]  = a_cred_ret[EAST_IDX];

    b_ds_cred[EAST_IDX]  = c_cred_ret[WEST_IDX];
    c_ds_cred[WEST_IDX]  = b_cred_ret[EAST_IDX];

    a_ds_cred[LOCAL_IDX] = ni_pipe[0][NI_LAT];
    b_ds_cred[LOCAL_IDX] = ni_pipe[1][NI_LAT];
    c_ds_cred[LOCAL_IDX] = ni_pipe[2][NI_LAT];
  end

  int  inj_inflight [N_RTR][NUM_VC];

  int  drv_idx;
  int  drv_vc;

  initial begin
    rst_n      = 1'b0;
    a_in_data  = '0;  a_in_valid = '0;  a_in_vc = '0;
    b_in_data  = '0;  b_in_valid = '0;  b_in_vc = '0;
    c_in_data  = '0;  c_in_valid = '0;  c_in_vc = '0;
    for (int r = 0; r < N_RTR; r++) begin
      for (int k = 0; k < NUM_VC; k++) inj_inflight[r][k] = 0;
    end
  end

  task automatic send(input int rtr, input logic [FLIT_W-1:0] data, input logic [VC_W-1:0] vc);
    tx_t t;

    if ((rtr < 0) || (rtr >= N_RTR)) begin
      $display("[FAIL] send(): router %0d out of range 0..%0d", rtr, N_RTR - 1);
      errors++;
      return;
    end
    t.rtr  = rtr;
    t.vc   = vc;
    t.data = data;

    tx_q.push_back(t);
  endtask

  always @(negedge clk) begin : link_and_inject
    if (!rst_n) begin
      a_in_data = '0;  a_in_valid = '0;  a_in_vc = '0;
      b_in_data = '0;  b_in_valid = '0;  b_in_vc = '0;
      c_in_data = '0;  c_in_valid = '0;  c_in_vc = '0;
      for (int r = 0; r < N_RTR; r++) begin
        for (int k = 0; k < NUM_VC; k++) inj_inflight[r][k] = 0;
      end
    end else begin

      for (int r = 0; r < N_RTR; r++) begin
        for (int k = 0; k < NUM_VC; k++) begin
          if (r_cred_ret[r][LOCAL_IDX][k] && (inj_inflight[r][k] > 0)) begin
            inj_inflight[r][k]--;
          end
        end
      end

      a_in_data = '0;  a_in_valid = '0;  a_in_vc = '0;
      b_in_data = '0;  b_in_valid = '0;  b_in_vc = '0;
      c_in_data = '0;  c_in_valid = '0;  c_in_vc = '0;

      a_in_data[EAST_IDX]  = b_out_data[WEST_IDX];
      a_in_valid[EAST_IDX] = b_out_valid[WEST_IDX];
      a_in_vc[EAST_IDX]    = b_out_vc[WEST_IDX];

      b_in_data[WEST_IDX]  = a_out_data[EAST_IDX];
      b_in_valid[WEST_IDX] = a_out_valid[EAST_IDX];
      b_in_vc[WEST_IDX]    = a_out_vc[EAST_IDX];

      b_in_data[EAST_IDX]  = c_out_data[WEST_IDX];
      b_in_valid[EAST_IDX] = c_out_valid[WEST_IDX];
      b_in_vc[EAST_IDX]    = c_out_vc[WEST_IDX];

      c_in_data[WEST_IDX]  = b_out_data[EAST_IDX];
      c_in_valid[WEST_IDX] = b_out_valid[EAST_IDX];
      c_in_vc[WEST_IDX]    = b_out_vc[EAST_IDX];

      for (int r = 0; r < N_RTR; r++) begin
        drv_idx = -1;
        for (int i = 0; i < tx_q.size(); i++) begin
          if (tx_q[i].rtr == r) begin
            drv_idx = i;
            break;
          end
        end
        if (drv_idx >= 0) begin
          drv_vc = tx_q[drv_idx].vc;

          if (drv_vc >= NUM_VC) begin
            $display("[FAIL] tx driver saw out-of-range vc_id %0d on router %0d",
                     drv_vc, r);
            errors++;
          end else if (inj_inflight[r][drv_vc] < FIFO_DEPTH) begin
            case (r)
              0: begin
                a_in_data[LOCAL_IDX]  = tx_q[drv_idx].data;
                a_in_valid[LOCAL_IDX] = 1'b1;
                a_in_vc[LOCAL_IDX]    = VC_W'(tx_q[drv_idx].vc);
              end
              1: begin
                b_in_data[LOCAL_IDX]  = tx_q[drv_idx].data;
                b_in_valid[LOCAL_IDX] = 1'b1;
                b_in_vc[LOCAL_IDX]    = VC_W'(tx_q[drv_idx].vc);
              end
              default: begin
                c_in_data[LOCAL_IDX]  = tx_q[drv_idx].data;
                c_in_valid[LOCAL_IDX] = 1'b1;
                c_in_vc[LOCAL_IDX]    = VC_W'(tx_q[drv_idx].vc);
              end
            endcase
            inj_inflight[r][drv_vc]++;
            tx_q.delete(drv_idx);
          end
        end
      end
    end
  end

  int  last_rx_n  = 0;
  int  stall_cnt  = 0;
  bit  deadlock_seen = 1'b0;

  always @(negedge clk) begin : watchdog
    if (!rst_n) begin
      stall_cnt     = 0;
      last_rx_n     = 0;
      deadlock_seen = 1'b0;
    end else begin
      if (rx_n() != last_rx_n) stall_cnt = 0;
      else stall_cnt++;
      last_rx_n = rx_n();

      if (!deadlock_seen && work_pending() && (stall_cnt > MAX_STALL)) begin
        deadlock_seen = 1'b1;
        checks++;
        $display("[FAIL] %-64s", "deadlock: no flit moved for 500 cycles");
        $display("        queued for injection : %0d", tx_q.size());
        for (int i = 0; i < exp_q.size(); i++) begin
          if (exp_q[i].got < exp_q[i].len) begin
            $display("        tag %h got %0d/%0d", exp_q[i].tag,
                     exp_q[i].got, exp_q[i].len);
          end
        end
        errors++;
      end
    end
  end

  task automatic drain(input int max_cycles);
    int n;
    int quiet;
    int prev;
    n     = 0;
    quiet = 0;
    prev  = -1;
    while ((n < max_cycles) && (quiet < 32)) begin
      @(negedge clk);
      n++;
      if ((tx_q.size() == 0) && (rx_n() == prev)) quiet++;
      else quiet = 0;
      prev = rx_n();
    end
    check_true($sformatf("drain settled within %0d cycles", max_cycles),
               (tx_q.size() == 0) && (quiet >= 32));
  endtask

  task automatic wait_idle(input int max_cycles);
    int n;
    n = 0;
    while (work_pending() && (n < max_cycles)) begin
      @(negedge clk);
      n++;
    end
    check_true($sformatf("all traffic settled within %0d cycles", max_cycles),
               !work_pending());
  endtask

  task automatic settle();
    repeat (12) @(negedge clk);
  endtask

  task automatic dynamic_multihop();
    logic [TAG_W-1:0] blocker, target;
    int base, n, expected_vc;
    localparam int REMAP_FLITS = FIFO_DEPTH + 8;

    if (NUM_VC > 2) begin
      for (int traffic_class = 0; traffic_class < 2; traffic_class++) begin
        reset_dut();
        base = traffic_class * (NUM_VC/2);
        blocker = TAG_W'(18'h3_7000 + traffic_class*2);
        target = blocker + TAG_W'(1);

        send(1, mk_head(X_C, Y_COORD, DIR_LOCAL, 2'(traffic_class*2), blocker), VC_W'(base));
        settle();
        check("D-MH blocker crossed B", hop_n(1, EAST_IDX, blocker), 1);
        check("D-MH blocker reached C", hop_n(2, LOCAL_IDX, blocker), 1);
        send(0, mk_head(X_C, Y_COORD, DIR_LOCAL, 2'(traffic_class*2), target), VC_W'(base));

        for (int pos = 1; pos < REMAP_FLITS-1; pos++)
          send(0, with_route(mk_body(target), 4'(pos)), VC_W'(base));
        send(0, mk_tail(target), VC_W'(base));
        drain(400);
        for (int r = 0; r < N_RTR; r++) begin
          n = 0;
          expected_vc = base + ((r == 0) ? 0 : 1);
          for (int i = 0; i < rx_n(); i++) begin
            if ((rx_tag(i) == target) && (rx[i].rtr == r)) begin
              check("D-MH each hop uses its assigned VC", rx[i].vc, expected_vc);
              check("D-MH traffic class unchanged", rx[i].vc / (NUM_VC/2), traffic_class);
              if (n == 0) begin
                check("D-MH HEAD order", rx_type(i), FLIT_HEAD);
                check("D-MH HEAD payload preserved", rx[i].data & ~ROUTE_MASK,
                      mk_head(X_C, Y_COORD, DIR_LOCAL, 2'(traffic_class*2), target) & ~ROUTE_MASK);
              end else if (n == REMAP_FLITS-1)
                check("D-MH TAIL order and payload", rx[i].data, mk_tail(target));
              else
                check("D-MH distinct BODY order and payload", rx[i].data,
                      with_route(mk_body(target), 4'(n)));
              n++;
            end
          end
          check("D-MH no loss or duplication on each hop", n, REMAP_FLITS);
        end

        send(1, mk_tail(blocker), VC_W'(base));
        drain(400);
        check("D-MH blocker completes B", hop_n(1, EAST_IDX, blocker), 2);
        check("D-MH blocker completes C", hop_n(2, LOCAL_IDX, blocker), 2);
        check("D-MH exact total flit hops", rx_n(), 3*REMAP_FLITS + 4);
      end
      reset_dut();
    end
  endtask

  task automatic t10a_two_hop_head_tail();
    logic [TAG_W-1:0] tag;
    int i0, i1, i2;

    clear_rx();
    tag = 18'hA_2001;
    send(0, mk_ht(X_C, Y_COORD, DIR_LOCAL, 2'd0, tag), VC_W'(0));
    drain(400);

    check("T10a one flit logged across the whole line", rx_n(), 3);
    if (rx_n() >= 3) begin
      i0 = 0;
      i1 = 1;
      i2 = 2;

      check("T10a hop 1 left router A", rx[i0].rtr, 0);
      check("T10a hop 1 left via EAST", rx[i0].port, EAST_IDX);
      check("T10a hop 1 type", rx_type(i0), FLIT_HEAD_TAIL);
      check("T10a hop 1 payload survived", rx_tag(i0), tag);
      check("T10a hop 1 route field is B's next hop", rx_route(i0), DIR_EAST);

      check("T10a hop 2 left router B", rx[i1].rtr, 1);
      check("T10a hop 2 left via EAST", rx[i1].port, EAST_IDX);
      check("T10a hop 2 type", rx_type(i1), FLIT_HEAD_TAIL);
      check("T10a hop 2 payload survived", rx_tag(i1), tag);
      check("T10a hop 2 route field is C's next hop", rx_route(i1), DIR_LOCAL);

      check("T10a ejected at router C", rx[i2].rtr, 2);
      check("T10a ejected via LOCAL", rx[i2].port, LOCAL_IDX);
      check("T10a type at the receiver", rx_type(i2), FLIT_HEAD_TAIL);
      check("T10a payload intact end to end", rx_tag(i2), tag);
    end
  endtask

  task automatic t10b_two_hop_reverse();
    logic [TAG_W-1:0] tag;
    int i0, i1, i2;

    clear_rx();
    tag = 18'hB_2002;
    send(2, mk_ht(X_A, Y_COORD, DIR_LOCAL, 2'd0, tag), VC_W'(0));
    drain(400);

    check("T10b one flit logged across the whole line", rx_n(), 3);
    if (rx_n() >= 3) begin
      i0 = 0;
      i1 = 1;
      i2 = 2;

      check("T10b hop 1 left router C", rx[i0].rtr, 2);
      check("T10b hop 1 left via WEST", rx[i0].port, WEST_IDX);
      check("T10b hop 1 route field is B's next hop", rx_route(i0), DIR_WEST);
      check("T10b hop 1 payload survived", rx_tag(i0), tag);

      check("T10b hop 2 left router B", rx[i1].rtr, 1);
      check("T10b hop 2 left via WEST", rx[i1].port, WEST_IDX);
      check("T10b hop 2 route field is A's next hop", rx_route(i1), DIR_LOCAL);
      check("T10b hop 2 payload survived", rx_tag(i1), tag);

      check("T10b ejected at router A", rx[i2].rtr, 0);
      check("T10b ejected via LOCAL", rx[i2].port, LOCAL_IDX);
      check("T10b payload intact end to end", rx_tag(i2), tag);
    end
  endtask

  task automatic t10c_two_hop_multi_flit();
    logic [TAG_W-1:0] tag;
    logic [FLIT_W-1:0] sent_body;
    logic [FLIT_W-1:0] sent_tail;
    int base;

    clear_rx();
    tag       = 18'hC_2003;
    sent_body = mk_body(tag);
    sent_tail = mk_tail(tag);

    send(0, mk_head(X_C, Y_COORD, DIR_LOCAL, 2'd0, tag), VC_W'(0));
    send(0, mk_body(tag), VC_W'(0));
    send(0, mk_body(tag), VC_W'(0));
    send(0, mk_tail(tag), VC_W'(0));
    drain(600);

    check("T10c four flits at every hop (12 logged)", rx_n(), 12);
    if (rx_n() >= 12) begin

      for (int i = 0; i < 4; i++) begin
        check($sformatf("T10c hop1 flit %0d left router A", i), rx[i].rtr, 0);
        check($sformatf("T10c hop1 flit %0d left via EAST", i), rx[i].port, EAST_IDX);
      end
      check("T10c hop1 HEAD type", rx_type(0), FLIT_HEAD);
      check("T10c hop1 BODY type", rx_type(1), FLIT_BODY);
      check("T10c hop1 BODY type", rx_type(2), FLIT_BODY);
      check("T10c hop1 TAIL type", rx_type(3), FLIT_TAIL);
      check("T10c hop1 HEAD route is B's next hop", rx_route(0), DIR_EAST);
      check("T10c hop1 BODY unmodified", rx[1].data, sent_body);
      check("T10c hop1 BODY unmodified", rx[2].data, sent_body);
      check("T10c hop1 TAIL unmodified", rx[3].data, sent_tail);

      base = 4;
      for (int i = 0; i < 4; i++) begin
        check($sformatf("T10c hop2 flit %0d left router B", i), rx[base+i].rtr, 1);
        check($sformatf("T10c hop2 flit %0d left via EAST", i), rx[base+i].port, EAST_IDX);
      end
      check("T10c hop2 HEAD type", rx_type(base+0), FLIT_HEAD);
      check("T10c hop2 TAIL type", rx_type(base+3), FLIT_TAIL);

      check("T10c hop2 HEAD route is C's next hop", rx_route(base+0), DIR_LOCAL);
      check("T10c hop2 BODY unmodified", rx[base+1].data, sent_body);
      check("T10c hop2 BODY unmodified", rx[base+2].data, sent_body);
      check("T10c hop2 TAIL unmodified", rx[base+3].data, sent_tail);

      base = 8;
      for (int i = 0; i < 4; i++) begin
        check($sformatf("T10c ejected flit %0d at router C", i), rx[base+i].rtr, 2);
        check($sformatf("T10c ejected flit %0d via LOCAL", i), rx[base+i].port, LOCAL_IDX);
      end
      check("T10c ejected HEAD type", rx_type(base+0), FLIT_HEAD);
      check("T10c ejected BODY type", rx_type(base+1), FLIT_BODY);
      check("T10c ejected BODY type", rx_type(base+2), FLIT_BODY);
      check("T10c ejected TAIL type", rx_type(base+3), FLIT_TAIL);
      check("T10c ejected HEAD route", rx_route(base+0), DIR_LOCAL);
      check("T10c payload intact end to end", rx_tag(base+0), tag);
      check("T10c BODY unmodified after two hops", rx[base+1].data, sent_body);
      check("T10c TAIL unmodified after two hops", rx[base+3].data, sent_tail);
    end
  endtask

  task automatic t10d_single_hop_legs();
    logic [TAG_W-1:0] t_ab, t_ba, t_bc;
    int i;

    clear_rx();
    t_ab = 18'hD_2011;
    t_ba = 18'hD_2012;
    t_bc = 18'hD_2013;
    send(0, mk_ht(X_B, Y_COORD, DIR_LOCAL, 2'd0, t_ab), VC_W'(0));
    send(1, mk_ht(X_A, Y_COORD, DIR_LOCAL, 2'd0, t_ba), VC_W'(0));
    send(1, mk_ht(X_C, Y_COORD, DIR_LOCAL, 2'd0, t_bc), VC_W'(0));
    drain(400);

    check("T10d three one-hop packets (6 logged)", rx_n(), 6);

    if (rx_n() >= 6) begin

      i = find_tag(t_ab);
      check_true("T10d A->B left router A via EAST",
                 (i >= 0) && (rx[i].rtr == 0) && (rx[i].port == EAST_IDX));
      check_true("T10d A->B route field says terminate at B",
                 (i >= 0) && (rx_route(i) == DIR_LOCAL));
      check_true("T10d A->B ejected at B",
                 (hop_n(1, LOCAL_IDX, t_ab) == 1) && (hop_n(0, EAST_IDX, t_ab) == 1));

      i = find_tag(t_ba);
      check_true("T10d B->A left router B via WEST",
                 (i >= 0) && (rx[i].rtr == 1) && (rx[i].port == WEST_IDX));
      check_true("T10d B->A ejected at A",
                 (hop_n(0, LOCAL_IDX, t_ba) == 1) && (hop_n(1, WEST_IDX, t_ba) == 1));

      i = find_tag(t_bc);
      check_true("T10d B->C left router B via EAST",
                 (i >= 0) && (rx[i].rtr == 1) && (rx[i].port == EAST_IDX));
      check_true("T10d B->C ejected at C",
                 (hop_n(2, LOCAL_IDX, t_bc) == 1) && (hop_n(1, EAST_IDX, t_bc) == 1));

      for (int k = 0; k < rx_n(); k++) begin
        check_true($sformatf("T10d flit %0d never used an unwired port", k),
                   (rx[k].port == LOCAL_IDX) || (rx[k].port == EAST_IDX) ||
                   (rx[k].port == WEST_IDX));
      end
    end
  endtask

  task automatic t_credit_loop_full_rate();
    logic [TAG_W-1:0] tag;

    clear_rx();
    tag = 18'hF_3001;
    send(0, mk_head(X_C, Y_COORD, DIR_LOCAL, 2'd0, tag), VC_W'(0));
    for (int i = 0; i < PKT_FLITS - 2; i++) send(0, mk_body(tag), VC_W'(0));
    send(0, mk_tail(tag), VC_W'(0));
    drain(800);

    check("CL every flit reached A's east link", hop_n(0, EAST_IDX, tag), PKT_FLITS);
    check("CL every flit crossed B's east link", hop_n(1, EAST_IDX, tag), PKT_FLITS);
    check("CL every flit was ejected at C", hop_n(2, LOCAL_IDX, tag), PKT_FLITS);
    check("CL nothing else left the line", rx_n(), 3 * PKT_FLITS);

    check("CL A->B ran at one flit per cycle", max_gap(0, EAST_IDX, tag), 1);
    check("CL B->C ran at one flit per cycle", max_gap(1, EAST_IDX, tag), 1);
    check("CL ejection at C ran at one flit per cycle", max_gap(2, LOCAL_IDX, tag), 1);
  endtask

  task automatic t11_random_traffic();
    int src;
    int dest;
    int len;
    int vc;
    int kind;
    int sent;
    int n_ht;
    int exp_hops;
    exp_t pe;
    logic [TAG_W-1:0] tag;

    clear_rx();
    exp_q.delete();
    sb_reset();
    sb_en = 1'b1;
    sent = 0;
    n_ht = 0;
    exp_hops = 0;

    for (int s = 0; s < 12; s++) begin
      for (src = 0; src < N_RTR; src++) begin
        len = $urandom_range(1, 6);

        dest = $urandom_range(0, 1);
        if (dest >= src) dest++;
        vc   = $urandom_range(0, NUM_VC - 1);

        kind = (src + dest + len) % 4;
        tag = tag_seq;
        tag_seq = tag_seq + 18'd1;

        pe.tag  = tag;
        pe.src  = src;
        pe.dest = dest;
        pe.len  = len;
        pe.vc   = vc;
        pe.kind = kind;
        pe.got  = 0;
        exp_q.push_back(pe);
        sb_outstanding++;
        sb_total_flits += len;

        exp_hops += len * ((dest > src ? dest - src : src - dest) + 1);

        if (len == 1) begin
          send(src, mk_ht(3'(dest), Y_COORD, DIR_LOCAL, 2'(kind), tag), VC_W'(vc));
          n_ht++;
        end else begin
          send(src, mk_head(3'(dest), Y_COORD, DIR_LOCAL, 2'(kind), tag), VC_W'(vc));
          for (int i = 0; i < len - 2; i++) send(src, mk_body(tag), VC_W'(vc));
          send(src, mk_tail(tag), VC_W'(vc));
        end
        sent++;
      end
    end

    $display("        %0d packets, %0d of them single-flit, %0d flits",
             sent, n_ht, sb_total_flits);
    wait_idle(4000);

    check("T11 every packet fully delivered", sb_complete, sent);
    check("T11 flit conservation (sent == received)", sb_got_flits, sb_total_flits);

    check("T11 the receiver ejected every injected flit",
          eject_cnt[0] + eject_cnt[1] + eject_cnt[2], sb_total_flits);

    check("T11 every hop logged exactly once", rx_n(), exp_hops);
    $display("        %0d flits scored over %0d logged hops",
             sb_got_flits, rx_n());

    for (int r = 0; r < N_RTR; r++) begin
      check_true($sformatf("T11 router %0d ejected traffic", r), eject_cnt[r] > 0);
    end

    check_true("T11 eastbound links carried traffic", east_cnt > 0);
    check_true("T11 westbound links carried traffic", west_cnt > 0);
    $display("        %0d eastbound, %0d westbound flit hops", east_cnt, west_cnt);

    check("T11 flits avoided the absent ports", bad_port_cnt, 0);

    sb_en = 1'b0;
  endtask

  task automatic reset_dut();
    rst_n = 1'b0;
    repeat (5) @(posedge clk);
    @(negedge clk);
    rst_n = 1'b1;
    @(negedge clk);
    clear_rx();
    exp_q.delete();
    sb_en = 1'b0;
    sb_reset();
    deadlock_seen = 1'b0;
  endtask

  task automatic sb_reset();
    sb_outstanding = 0;
    sb_got_flits   = 0;
    sb_complete    = 0;
    sb_total_flits = 0;
  endtask

  initial begin : main
    if ($test$plusargs("vcd")) begin
      $dumpfile("sim/router_chain.vcd");
      $dumpvars(0, tb_router_chain);
    end

    reset_dut();

    dynamic_multihop();

    $display("---- T10a  two-hop HEAD_TAIL, A -> C, route_next at both hops ----");
    t10a_two_hop_head_tail();

    $display("---- T10b  two-hop HEAD_TAIL back, C -> A ----");
    t10b_two_hop_reverse();

    $display("---- T10c  four-flit packet through both hops ----");
    t10c_two_hop_multi_flit();

    $display("---- T10d  the three one-hop legs ----");
    t10d_single_hop_legs();

    $display("---- section 6 credit loop: 16 flits, full rate ----");
    t_credit_loop_full_rate();

    $display("---- T11  random traffic with a scoreboard ----");
    t11_random_traffic();

    $display("");
    if (errors == 0) $display("ALL %0d CHECKS PASSED", checks);
    else $display("%0d/%0d CHECKS FAILED", errors, checks);

    $finish;
  end

endmodule
