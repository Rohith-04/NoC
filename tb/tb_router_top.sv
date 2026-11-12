// Self-checking tests for router_top.

`timescale 1ns / 1ps

module tb_router_top;

  import noc_tb_pkg::*;

  localparam int          NUM_PORTS   = 5;
  parameter  int          NUM_VC      = 4;

  localparam int          VC_W        = (NUM_VC > 1) ? $clog2(NUM_VC) : 1;
  localparam int          LOCAL_IDX   = 0;
  localparam int          NORTH_IDX   = 1;
  localparam int          EAST_IDX    = 2;
  localparam int          WEST_IDX    = 3;
  localparam int          SOUTH_IDX   = 4;
  parameter  int          FIFO_DEPTH  = 4;
  localparam int          LOCAL_CRED  = 4;
  localparam realtime     CLK_PERIOD  = 10ns;

  localparam int          CRED_LAT    = 2;

  localparam logic [2:0]  CUR_X = 3'd1;
  localparam logic [2:0]  CUR_Y = 3'd1;

  localparam logic [3:0]  DIR_LOCAL = 4'b0000;
  localparam logic [3:0]  DIR_NORTH = 4'b0001;
  localparam logic [3:0]  DIR_EAST  = 4'b0010;
  localparam logic [3:0]  DIR_WEST  = 4'b0100;
  localparam logic [3:0]  DIR_SOUTH = 4'b1000;

  logic                            clk;
  logic                            rst_n;

  logic [NUM_PORTS-1:0][FLIT_W-1:0]      in_flit_data;
  logic [NUM_PORTS-1:0]            in_flit_valid;
  logic [NUM_PORTS-1:0][VC_W-1:0]       in_vc_id;

  logic [NUM_PORTS-1:0][FLIT_W-1:0]      out_flit_data;
  logic [NUM_PORTS-1:0]            out_flit_valid;
  logic [NUM_PORTS-1:0][VC_W-1:0]       out_vc_id;

  logic [NUM_PORTS-1:0][NUM_VC-1:0] credit_return_valid;
  logic [NUM_PORTS-1:0][NUM_VC-1:0] ds_credit_valid;

  initial clk = 0;
  always #(CLK_PERIOD / 2) clk = ~clk;

  router_top #(
      .NUM_PORTS   (NUM_PORTS),
      .NUM_VC      (NUM_VC),
      .LOCAL_IDX   (LOCAL_IDX),
      .FIFO_DEPTH  (FIFO_DEPTH),
      .LOCAL_CREDITS(LOCAL_CRED),
      .CUR_X       (CUR_X),
      .CUR_Y       (CUR_Y),
      .HAS_LOCAL   (1'b1),
      .HAS_NORTH   (1'b1),
      .HAS_EAST    (1'b1),
      .HAS_WEST    (1'b1),
      .HAS_SOUTH   (1'b1)
  ) dut (
      .clk                  (clk),
      .rst_n                (rst_n),
      .in_flit_data         (in_flit_data),
      .in_flit_valid        (in_flit_valid),
      .in_vc_id             (in_vc_id),
      .out_flit_data        (out_flit_data),
      .out_flit_valid       (out_flit_valid),
      .out_vc_id            (out_vc_id),
      .credit_return_valid  (credit_return_valid),
      .ds_credit_valid      (ds_credit_valid)
  );

  typedef struct {
    int          port;
    int          vc;
    logic [FLIT_W-1:0] data;
  } rx_t;

  rx_t rx[$];

  always @(posedge clk) begin : rx_logger
    rx_t e;
    if (rst_n) begin
      for (int o = 0; o < NUM_PORTS; o++) begin
        if (out_flit_valid[o]) begin

          e.port = o;
          e.vc   = int'(out_vc_id[o]);
          e.data = out_flit_data[o];
          rx.push_back(e);
        end
      end
    end
  end

  task automatic clear_rx();
    rx.delete();
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

  function automatic logic [1:0] rx_origin(input int i);
    return flit_burst(rx[i].data);
  endfunction

  function automatic int rx_port(input int i);
    return rx[i].port;
  endfunction

  function automatic logic [3:0] rx_route(input int i);
    return flit_route(rx[i].data);
  endfunction

  bit credit_en = 1'b1;

  logic [CRED_LAT:0][NUM_PORTS-1:0][NUM_VC-1:0] cr_pipe;

  int held_credits [NUM_PORTS][NUM_VC];

  always @(posedge clk) begin : credit_pipe
    if (!rst_n) begin
      cr_pipe <= '0;
      for (int o = 0; o < NUM_PORTS; o++) begin
        for (int k = 0; k < NUM_VC; k++) held_credits[o][k] <= 0;
      end
    end else begin
      cr_pipe[0] <= '0;
      for (int o = 0; o < NUM_PORTS; o++) begin

        for (int k = 0; k < NUM_VC; k++) begin
          if (out_flit_valid[o] && (out_vc_id[o] == VC_W'(k))) cr_pipe[0][o][k] <= 1'b1;
        end
      end
      for (int i = 1; i <= CRED_LAT; i++) begin
        cr_pipe[i] <= cr_pipe[i-1];
      end

      for (int o = 0; o < NUM_PORTS; o++) begin
        for (int k = 0; k < NUM_VC; k++) begin
          if (!credit_en) begin
            if (cr_pipe[CRED_LAT][o][k]) held_credits[o][k] <= held_credits[o][k] + 1;
          end else if ((held_credits[o][k] != 0) && !cr_pipe[CRED_LAT][o][k]) begin
            held_credits[o][k] <= held_credits[o][k] - 1;
          end
        end
      end
    end
  end

  always_comb begin : credit_gate
    for (int o = 0; o < NUM_PORTS; o++) begin
      for (int k = 0; k < NUM_VC; k++) begin
        ds_credit_valid[o][k] = credit_en &
                                (cr_pipe[CRED_LAT][o][k] | (held_credits[o][k] != 0));
      end
    end
  end

  typedef struct {
    int          port;
    logic [VC_W-1:0] vc;
    logic [FLIT_W-1:0] data;
  } tx_t;

  tx_t tx_q[$];
  int  inflight[NUM_PORTS][NUM_VC];

  initial begin
    for (int p = 0; p < NUM_PORTS; p++) begin
      in_flit_data[p]  = '0;
      in_flit_valid[p] = 1'b0;
      in_vc_id[p]      = '0;
      for (int k = 0; k < NUM_VC; k++) inflight[p][k] = 0;
    end
  end

  task automatic send(input int port, input logic [FLIT_W-1:0] data, input logic [VC_W-1:0] vc);
    tx_t t;

    if ((port < 0) || (port >= NUM_PORTS)) begin
      $display("[FAIL] send(): port %0d out of range 0..%0d", port, NUM_PORTS - 1);
      errors++;
      return;
    end
    t.port = port;
    t.vc   = vc;
    t.data = data;

    tx_q.push_back(t);
  endtask

  int drv_vc;
  int drv_idx;

  always @(negedge clk) begin : tx_driver
    if (!rst_n) begin
      for (int p = 0; p < NUM_PORTS; p++) begin
        in_flit_valid[p] = 1'b0;
        for (int k = 0; k < NUM_VC; k++) inflight[p][k] = 0;
      end
    end else begin

      for (int p = 0; p < NUM_PORTS; p++) begin
        for (int k = 0; k < NUM_VC; k++) begin
          if (credit_return_valid[p][k] && inflight[p][k] > 0) inflight[p][k]--;
        end
      end

      for (int p = 0; p < NUM_PORTS; p++) begin
        in_flit_valid[p] = 1'b0;

        drv_idx = -1;
        for (int i = 0; i < tx_q.size(); i++) begin
          if (tx_q[i].port == p) begin
            drv_idx = i;
            break;
          end
        end
        if (drv_idx >= 0) begin
          drv_vc = int'(tx_q[drv_idx].vc);

          if (drv_vc >= NUM_VC) begin
            $display("[FAIL] tx driver saw out-of-range vc_id %0d on port %0d",
                     drv_vc, p);
            errors++;
          end else if (inflight[p][drv_vc] < FIFO_DEPTH) begin
            in_flit_data[p]  = tx_q[drv_idx].data;
            in_vc_id[p]      = tx_q[drv_idx].vc;
            in_flit_valid[p] = 1'b1;
            inflight[p][drv_vc]++;
            tx_q.delete(drv_idx);
          end
        end
      end
    end
  end

  task automatic drain(input int max_cycles);
    int n;
    int left;
    n = 0;
    left = 1;
    while ((left != 0) && (n < max_cycles)) begin
      left = tx_q.size();
      if (left != 0) begin
        @(negedge clk);
        n++;
      end
    end

    repeat (20) @(negedge clk);
    check_true($sformatf("drain completed within %0d cycles", max_cycles), left == 0);
  endtask

  task automatic settle();
    repeat (10) @(negedge clk);
  endtask

  task automatic t1_single_head_tail();
    clear_rx();

    send(LOCAL_IDX, mk_ht(3'd2, 3'd1, DIR_EAST, 2'd0, 18'h1_A11A), VC_W'(0));
    drain(200);

    check("T1a flit count", rx_n(), 1);
    if (rx_n() >= 1) begin
      check("T1a left through EAST", rx_port(0), EAST_IDX);
      check("T1a type is HEAD_TAIL", rx_type(0), FLIT_HEAD_TAIL);
      check("T1a payload survived", rx_tag(0), 18'h1_A11A);

      check("T1a outgoing route is the next hop", rx_route(0), DIR_LOCAL);
    end

    clear_rx();

    send(EAST_IDX, mk_ht(3'd0, 3'd1, DIR_WEST, 2'd0, 18'h1_B22B), VC_W'(0));
    drain(200);

    check("T1b flit count", rx_n(), 1);
    if (rx_n() >= 1) begin
      check("T1b left through WEST", rx_port(0), WEST_IDX);
      check("T1b type is HEAD_TAIL", rx_type(0), FLIT_HEAD_TAIL);
      check("T1b payload survived", rx_tag(0), 18'h1_B22B);
    end

    clear_rx();

    send(NORTH_IDX, mk_ht(3'd1, 3'd2, DIR_SOUTH, 2'd0, 18'h1_C33C), VC_W'(0));
    drain(200);

    check("T1c flit count", rx_n(), 1);
    if (rx_n() >= 1) begin
      check("T1c left through SOUTH", rx_port(0), SOUTH_IDX);
      check("T1c type is HEAD_TAIL", rx_type(0), FLIT_HEAD_TAIL);
      check("T1c payload survived", rx_tag(0), 18'h1_C33C);

      check("T1c outgoing route is the next hop", rx_route(0), DIR_LOCAL);
    end
  endtask

  task automatic t2_three_flit_packet();
    int n0;
    int n1;
    logic [FLIT_W-15:0] tag;
    logic [FLIT_W-1:0] sent_body;
    logic [FLIT_W-1:0] sent_tail;
    tag = 18'h2_3F17;

    clear_rx();

    send(EAST_IDX, mk_head(3'd0, 3'd2, DIR_WEST, 2'd0, tag), VC_W'(0));
    send(EAST_IDX, mk_body(tag), VC_W'(0));
    send(EAST_IDX, mk_tail(tag), VC_W'(0));

    n0 = 0;
    while ((rx_n() == 0) && (n0 < 60)) begin
      @(negedge clk);
      n0++;
    end
    check_true("T2 output appeared within 60 cycles", rx_n() > 0);

    n1 = 0;
    while ((rx_n() < 3) && (n1 < 16)) begin
      @(negedge clk);
      n1++;
    end

    check("T2 all three flits arrived", rx_n(), 3);

    if (rx_n() >= 3) begin

      check("T2 flit 0 is the HEAD", rx_type(0), FLIT_HEAD);
      check("T2 flit 1 is the BODY", rx_type(1), FLIT_BODY);
      check("T2 flit 2 is the TAIL", rx_type(2), FLIT_TAIL);

      check("T2 flit 0 exit port", rx_port(0), WEST_IDX);
      check("T2 flit 1 exit port", rx_port(1), WEST_IDX);
      check("T2 flit 2 exit port", rx_port(2), WEST_IDX);

      check("T2 outgoing route is the next hop", rx_route(0), DIR_SOUTH);

      sent_body = mk_body(tag);
      sent_tail = mk_tail(tag);
      check("T2 BODY flit left unmodified", rx[1].data, sent_body);
      check("T2 TAIL flit left unmodified", rx[2].data, sent_tail);
    end
  endtask

  task automatic t3_back_to_back_packets();
    clear_rx();

    send(EAST_IDX, mk_head(3'd0, 3'd1, DIR_WEST, 2'd0, 18'h3_AA01), VC_W'(0));
    send(EAST_IDX, mk_body(18'h3_AA01), VC_W'(0));
    send(EAST_IDX, mk_tail(18'h3_AA01), VC_W'(0));
    send(EAST_IDX, mk_head(3'd0, 3'd1, DIR_WEST, 2'd0, 18'h3_BB02), VC_W'(0));
    send(EAST_IDX, mk_tail(18'h3_BB02), VC_W'(0));
    drain(400);

    check("T3 both packets arrived (5 flits)", rx_n(), 5);
    if (rx_n() >= 5) begin
      check("T3 p1 HEAD", rx_tag(0), 18'h3_AA01);
      check("T3 p1 BODY", rx_type(1), FLIT_BODY);
      check("T3 p1 TAIL", rx_type(2), FLIT_TAIL);
      check("T3 p2 HEAD follows immediately", rx_tag(3), 18'h3_BB02);
      check("T3 p2 TAIL", rx_type(4), FLIT_TAIL);
      for (int i = 0; i < 5; i++) check($sformatf("T3 flit %0d exit port", i),
                                        rx_port(i), WEST_IDX);
    end
  endtask

  task automatic t4_two_vcs_one_port();
    clear_rx();

    send(WEST_IDX, mk_head(3'd2, 3'd1, DIR_EAST, 2'd0, 18'h4_C000), VC_W'(0));
    send(WEST_IDX, mk_body(18'h4_C000), VC_W'(0));
    send(WEST_IDX, mk_tail(18'h4_C000), VC_W'(0));

    send(WEST_IDX, mk_head(3'd1, 3'd2, DIR_NORTH, 2'd1, 18'h4_C111), VC_W'(1));
    send(WEST_IDX, mk_body(18'h4_C111), VC_W'(1));
    send(WEST_IDX, mk_tail(18'h4_C111), VC_W'(1));
    drain(400);

    check("T4 both VC streams arrived (6 flits)", rx_n(), 6);
    if (rx_n() >= 6) begin : t4_stats
      int n_east, n_north;
      n_east = 0; n_north = 0;
      for (int i = 0; i < rx_n(); i++) begin
        if (rx_port(i) == EAST_IDX) n_east++;
        if (rx_port(i) == NORTH_IDX) n_north++;
      end
      check("T4 three flits left via EAST", n_east, 3);
      check("T4 three flits left via NORTH", n_north, 3);
    end

    if (rx_n() >= 6) begin : t4_stream_check
      int n_ok, seen, vc_a;
      n_ok = 1;
      for (int s = 0; s < 2; s++) begin
        seen = 0;
        vc_a = -1;
        for (int i = 0; i < rx_n(); i++) begin
          if (rx_tag(i) == ((s == 0) ? 18'h4_C000 : 18'h4_C111)) begin
            case (seen)
              0: if (rx_type(i) != FLIT_HEAD)  n_ok = 0;
              1: if (rx_type(i) != FLIT_BODY)  n_ok = 0;
              2: if (rx_type(i) != FLIT_TAIL)  n_ok = 0;
              default: n_ok = 0;
            endcase
            if (vc_a < 0) vc_a = rx[i].vc;
            else if (rx[i].vc != vc_a) n_ok = 0;
            seen++;
          end
        end
        if (seen != 3) n_ok = 0;
      end
      check_true("T4 no payload crossed streams", n_ok != 0);
    end
  endtask

  task automatic t5_two_inputs_one_output();
    int n_from_north;
    int n_from_east;
    int first_six_north;
    int first_six_east;

    clear_rx();

    send(NORTH_IDX, mk_head(3'd1, 3'd1, DIR_LOCAL, 2'd0, 18'h1_0001), VC_W'(0));
    for (int i = 0; i < 4; i++) send(NORTH_IDX, mk_body(18'h1_0001), VC_W'(0));
    send(NORTH_IDX, mk_tail(18'h1_0001), VC_W'(0));

    send(EAST_IDX, mk_head(3'd1, 3'd1, DIR_LOCAL, 2'd0, 18'h2_0002), VC_W'((NUM_VC == 2) ? 1 : 0));
    for (int i = 0; i < 4; i++) send(EAST_IDX, mk_body(18'h2_0002), VC_W'((NUM_VC == 2) ? 1 : 0));
    send(EAST_IDX, mk_tail(18'h2_0002), VC_W'((NUM_VC == 2) ? 1 : 0));

    drain(600);

    check("T5 both packets arrived (12 flits)", rx_n(), 12);

    if (rx_n() >= 12) begin : t5_stats
      logic [1:0] origin;
      n_from_north = 0;
      n_from_east  = 0;
      first_six_north = 0;
      first_six_east  = 0;
      for (int i = 0; i < rx_n(); i++) begin
        origin = rx_origin(i);
        if (origin == 2'b01) n_from_north++;
        else if (origin == 2'b10) n_from_east++;
        if (i < 6) begin
          if (origin == 2'b01) first_six_north++;
          if (origin == 2'b10) first_six_east++;
        end
      end
      check("T5 six from NORTH", n_from_north, 6);
      check("T5 six from EAST", n_from_east, 6);

      check_true("T5 stage-2 alternated between the two ports",
                 (first_six_north >= 2) && (first_six_east >= 2));
      for (int i = 0; i < rx_n(); i++) check($sformatf("T5 flit %0d exit port", i),
                                             rx_port(i), LOCAL_IDX);
    end
  endtask

  task automatic t6_va_contention();
    clear_rx();

    send(NORTH_IDX, mk_head(3'd1, 3'd1, DIR_LOCAL, 2'd0, 18'h6_A0FF), VC_W'(0));
    send(NORTH_IDX, mk_tail(18'h6_A0FF), VC_W'(0));
    send(EAST_IDX,  mk_head(3'd1, 3'd1, DIR_LOCAL, 2'd0, 18'h6_B0FF), VC_W'(0));
    send(EAST_IDX,  mk_tail(18'h6_B0FF), VC_W'(0));
    send(WEST_IDX,  mk_ht  (3'd1, 3'd1, DIR_LOCAL, 2'd0, 18'h6_C1EE), VC_W'(0));
    drain(600);

    check("T6 all three packets arrived (5 flits)", rx_n(), 5);

    if (rx_n() >= 5) begin : t6_stats
      int w_pos;
      int n_north, n_east, n_west;

      w_pos   = -1;
      n_north = 0; n_east = 0; n_west = 0;
      for (int i = 0; i < rx_n(); i++) begin
        if (rx_tag(i) == 18'h6_C1EE) w_pos = i;
        if (rx_tag(i) == 18'h6_A0FF) n_north++;
        if (rx_tag(i) == 18'h6_B0FF) n_east++;
        if (rx_tag(i) == 18'h6_C1EE) n_west++;
      end

      check_true("T6 the single-flit HEAD_TAIL was served", w_pos >= 0);
      check_true("T6 HEAD_TAIL beat the multi-flit requests (first two out)",
                 (w_pos == 0) || (w_pos == 1));
      if (w_pos >= 0) check("T6 WEST's flit left via LOCAL", rx_port(w_pos), LOCAL_IDX);

      check("T6 NORTH's two flits arrived", n_north, 2);
      check("T6 EAST's two flits arrived", n_east, 2);
      check("T6 WEST's one flit arrived", n_west, 1);
    end
  endtask

  task automatic t7_credit_exhaustion();
    int before_reopen;

    credit_en = 1'b0;
    clear_rx();

    for (int i = 0; i < FIFO_DEPTH + 4; i++) begin
      send(LOCAL_IDX, mk_ht(3'd2, 3'd1, DIR_EAST, 2'd0, 18'(18'h7_0000 + i)), VC_W'(0));
    end

    repeat (120) @(negedge clk);

    before_reopen = rx_n();
    check("T7 exactly FIFO_DEPTH flits left before credits returned",
          before_reopen, FIFO_DEPTH);

    repeat (40) @(negedge clk);
    check("T7 no further flits escaped while credits were held", rx_n(), FIFO_DEPTH);

    credit_en = 1'b1;
    drain(400);

    check("T7 every flit eventually left", rx_n(), FIFO_DEPTH + 4);
    if (rx_n() >= FIFO_DEPTH + 4) begin
      check("T7 flit 0 tag", rx_tag(0), 18'h7_0000);
      check("T7 last flit tag", rx_tag(FIFO_DEPTH + 3), 18'(18'h7_0000 + (FIFO_DEPTH + 3)));
      for (int i = 0; i < rx_n(); i++) check($sformatf("T7 flit %0d exit port", i),
                                             rx_port(i), EAST_IDX);
    end
    credit_en = 1'b1;
  endtask

  task automatic t8_fetch_grant_collision();
    int n;
    int lat_first;

    clear_rx();

    send(EAST_IDX, mk_head(3'd0, 3'd1, DIR_WEST, 2'd0, 18'h8_C011), VC_W'(0));
    send(EAST_IDX, mk_body(18'h8_C011), VC_W'(0));
    send(EAST_IDX, mk_tail(18'h8_C011), VC_W'(0));

    n = 0;
    while (!out_flit_valid[WEST_IDX] && (n < 80)) begin
      @(negedge clk);
      n++;
    end
    check_true("T8 the head reached the output link",
               out_flit_valid[WEST_IDX] === 1'b1);
    lat_first = n;
    check("T8 the head is the first flit out", flit_type(out_flit_data[WEST_IDX]),
          FLIT_HEAD);

    @(negedge clk);
    check("T8 BODY on the very next cycle", out_flit_valid[WEST_IDX], 1'b1);
    check("T8 BODY payload is from the same packet", flit_tag(out_flit_data[WEST_IDX]),
          18'h8_C011);
    check("T8 BODY type", flit_type(out_flit_data[WEST_IDX]), FLIT_BODY);

    @(negedge clk);
    check("T8 TAIL on the cycle after that", out_flit_valid[WEST_IDX], 1'b1);
    check("T8 TAIL type", flit_type(out_flit_data[WEST_IDX]), FLIT_TAIL);

    @(negedge clk);
    check("T8 exactly three flits left", rx_n(), 3);
    check_true("T8 first flit appeared within a sane time", lat_first < 80);
  endtask

  task automatic t9_empty_fifo_bypass();
    int c_in;
    int c_out;
    int lat;

    clear_rx();
    send(LOCAL_IDX, mk_ht(3'd2, 3'd1, DIR_EAST, 2'd0, 18'h9_B995), VC_W'(0));

    c_in  = -1;
    c_out = -1;
    for (int c = 0; c < 40; c++) begin
      @(posedge clk);
      if ((c_in  < 0) && (in_flit_valid[LOCAL_IDX] === 1'b1)) c_in  = c;
      if ((c_out < 0) && (out_flit_valid[EAST_IDX] === 1'b1)) c_out = c;
      if ((c_in >= 0) && (c_out >= 0)) break;
    end

    check_true("T9 the flit reached the input link", c_in  >= 0);
    check_true("T9 the flit reached the output link", c_out >= 0);
    if ((c_in >= 0) && (c_out >= 0)) begin
      lat = c_out - c_in;
      check("T9 bypass hop latency is 3 cycles", lat, 3);
    end

    @(negedge clk);
    check("T9 flit arrived", rx_n(), 1);
    if (rx_n() >= 1) begin
      check("T9 payload survived the bypass", rx_tag(0), 18'h9_B995);
      check("T9 type is HEAD_TAIL", rx_type(0), FLIT_HEAD_TAIL);
      check("T9 exit port", rx_port(0), EAST_IDX);
    end
  endtask

  task automatic t_edge_ports();

    clear_rx();
    send(LOCAL_IDX, mk_ht(3'd2, 3'd1, DIR_EAST, 2'd0, 18'hA_0001), VC_W'(0));
    send(LOCAL_IDX, mk_ht(3'd1, 3'd0, DIR_NORTH, 2'd0, 18'hA_0002), VC_W'(0));
    drain(300);
    check("E1 both edge-legal packets arrived", rx_n(), 2);
    if (rx_n() >= 2) begin
      check("E1 first left via EAST", rx_port(0), EAST_IDX);
      check("E1 second left via NORTH", rx_port(1), NORTH_IDX);
    end
  endtask

  task automatic reset_dut();
    rst_n = 1'b0;
    repeat (5) @(posedge clk);
    @(negedge clk);
    rst_n = 1'b1;
    @(negedge clk);
    clear_rx();
  endtask

  initial begin : main
    if ($test$plusargs("vcd")) begin
      $dumpfile("sim/router_top.vcd");
      $dumpvars(0, tb_router_top);
    end

    reset_dut();

    $display("---- T1  single HEAD_TAIL, LOCAL->EAST and EAST->WEST ----");
    t1_single_head_tail();

    $display("---- T2  the section 3 three-flit packet ----");
    t2_three_flit_packet();

    $display("---- T3  two packets back to back in the same VC ----");
    t3_back_to_back_packets();

    $display("---- T4  two VCs on one input port, different outputs ----");
    t4_two_vcs_one_port();

    $display("---- T5  two inputs competing for one output ----");
    t5_two_inputs_one_output();

    $display("---- T6  VA contention: three requesters, two output VCs ----");
    t6_va_contention();

    $display("---- T7  credit exhaustion and recovery ----");
    t7_credit_exhaustion();

    $display("---- T8  fetch and grant in the same cycle ----");
    t8_fetch_grant_collision();

    $display("---- T9  empty-FIFO bypass ----");
    t9_empty_fifo_bypass();

    $display("---- edge-of-mesh ports ----");
    t_edge_ports();

    $display("");
    if (errors == 0) $display("ALL %0d CHECKS PASSED", checks);
    else $display("%0d/%0d CHECKS FAILED", errors, checks);

    $finish;
  end

endmodule
