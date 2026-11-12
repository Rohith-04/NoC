// Connects five input ports, allocation, crossbar, and five output ports.

`timescale 1ns / 1ps

module router_top #(
    parameter int         NUM_PORTS     = 5,
    parameter int         FLIT_W        = 40,
    parameter int         NUM_VC        = 4,
    parameter int         LOCAL_IDX     = 0,
    parameter int         FIFO_DEPTH    = 4,

    parameter int         LOCAL_CREDITS = 4,
    parameter logic [2:0] CUR_X         = '0,
    parameter logic [2:0] CUR_Y         = '0,
    parameter bit         HAS_LOCAL     = 1'b1,
    parameter bit         HAS_NORTH     = 1'b1,
    parameter bit         HAS_EAST      = 1'b1,
    parameter bit         HAS_WEST      = 1'b1,
    parameter bit         HAS_SOUTH     = 1'b1
) (
    input logic clk,
    input logic rst_n,

    input  logic [NUM_PORTS-1:0][FLIT_W-1:0]      in_flit_data,
    input  logic [NUM_PORTS-1:0]                  in_flit_valid,
    input  logic [NUM_PORTS-1:0][VC_W-1:0]             in_vc_id,

    output logic [NUM_PORTS-1:0][FLIT_W-1:0]      out_flit_data,
    output logic [NUM_PORTS-1:0]                  out_flit_valid,
    output logic [NUM_PORTS-1:0][VC_W-1:0]             out_vc_id,
    output logic [NUM_PORTS-1:0][NUM_VC-1:0]      credit_return_valid,

    input  logic [NUM_PORTS-1:0][NUM_VC-1:0]      ds_credit_valid
);

  localparam int VC_W = (NUM_VC > 1) ? $clog2(NUM_VC) : 1;

  initial begin
    assert ((NUM_VC == 2) || (NUM_VC == 4) || (NUM_VC == 8))
    else $fatal(1, "router_top: NUM_VC must be 2, 4 or 8 so that VC_W = clog2(NUM_VC) addresses it exactly, got %0d", NUM_VC);

    assert (FLIT_W >= 16)
    else $fatal(1, "router_top: FLIT_W must be at least 16, got %0d", FLIT_W);

    assert ((FIFO_DEPTH >= 2) && ((FIFO_DEPTH & (FIFO_DEPTH - 1)) == 0))
    else $fatal(1, "router_top: FIFO_DEPTH must be a power of two >= 2, got %0d", FIFO_DEPTH);
  end

  localparam bit HAS_P [NUM_PORTS] =
      '{HAS_LOCAL, HAS_NORTH, HAS_EAST, HAS_WEST, HAS_SOUTH};

  logic [NUM_PORTS-1:0][NUM_VC-1:0]       a_va_req;
  logic [NUM_PORTS-1:0][NUM_VC-1:0][3:0]  a_va_req_out_port;
  logic [NUM_PORTS-1:0][NUM_VC-1:0]       a_va_req_single;
  logic [NUM_PORTS-1:0][NUM_VC-1:0]       a_va_gnt;
  logic [NUM_PORTS-1:0][NUM_VC-1:0][VC_W-1:0] a_va_gnt_out_vc;

  logic [NUM_PORTS-1:0][NUM_VC-1:0]       a_sa_req;
  logic [NUM_PORTS-1:0][NUM_VC-1:0][3:0]  a_sa_req_out_port;
  logic [NUM_PORTS-1:0][NUM_VC-1:0][VC_W-1:0]  a_sa_req_out_vc;
  logic [NUM_PORTS-1:0][NUM_VC-1:0]       a_sa_req_last;
  logic [NUM_PORTS-1:0][NUM_VC-1:0]       a_sa_gnt;
  logic [NUM_PORTS-1:0][NUM_VC-1:0]       a_sa_pick;

  logic [NUM_PORTS-1:0][2:0]              a_xbar_sel;
  logic [NUM_PORTS-1:0]                   a_st_valid;
  logic [NUM_PORTS-1:0][VC_W-1:0]              a_st_out_vc;

  logic [NUM_PORTS-1:0][FLIT_W-1:0] xbar_in_data;
  logic [NUM_PORTS-1:0][3:0]  xbar_in_route_next;
  logic [NUM_PORTS-1:0][FLIT_W-1:0] xbar_out_data;
  logic [NUM_PORTS-1:0][3:0]  xbar_out_route_next;

  generate
    for (genvar p = 0; p < NUM_PORTS; p = p + 1) begin : gen_in_port

      logic [FLIT_W-1:0]  l_flit_data;
      logic               l_flit_valid;
      logic [VC_W-1:0]         l_vc_id;
      logic [NUM_VC-1:0]  l_credit_return;

      logic [NUM_VC-1:0]  l_req_va;
      logic [3:0]         l_va_req_out_port [NUM_VC];
      logic [NUM_VC-1:0]  l_va_req_single;
      logic [NUM_VC-1:0][VC_W-1:0] l_va_gnt_out_vc;
      logic [NUM_VC-1:0]  l_va_gnt;

      logic [NUM_VC-1:0]  l_req_sa;
      logic [3:0]         l_sa_req_out_port [NUM_VC];
      logic [VC_W-1:0]         l_sa_req_out_vc [NUM_VC];
      logic [NUM_VC-1:0]  l_sa_req_last;
      logic [NUM_VC-1:0]  l_sa_gnt;
      logic [NUM_VC-1:0]  l_sa_pick;

      logic [FLIT_W-1:0]  l_st_flit_data;
      logic [3:0]         l_st_route_next;

      assign l_flit_data  = HAS_P[p] ? in_flit_data[p]  : '0;
      assign l_flit_valid = HAS_P[p] ? in_flit_valid[p] : 1'b0;
      assign l_vc_id      = HAS_P[p] ? in_vc_id[p]      : '0;

      noc_input_port #(
          .FLIT_W       (FLIT_W),

          .DEPTH        (FIFO_DEPTH),
          .NUM_VC       (NUM_VC),
          .CUR_X        (CUR_X),
          .CUR_Y        (CUR_Y),

          .IS_LOCAL_PORT(p == LOCAL_IDX)
      ) u_in_port (
          .clk                (clk),
          .rst_n              (rst_n),
          .flit_data          (l_flit_data),
          .flit_valid         (l_flit_valid),
          .vc_id              (l_vc_id),
          .credit_return_valid(l_credit_return),
          .req_va             (l_req_va),
          .va_req_out_port    (l_va_req_out_port),
          .va_req_single      (l_va_req_single),
          .va_gnt             (l_va_gnt),
          .va_gnt_out_vc      (l_va_gnt_out_vc),
          .req_sa             (l_req_sa),
          .sa_req_out_port    (l_sa_req_out_port),
          .sa_req_out_vc      (l_sa_req_out_vc),
          .sa_req_last        (l_sa_req_last),
          .sa_gnt             (l_sa_gnt),
          .sa_pick            (l_sa_pick),
          .st_flit_data       (l_st_flit_data),
          .st_route_next      (l_st_route_next)
      );

      assign a_va_req[p]       = l_req_va;
      assign a_va_req_single[p] = l_va_req_single;
      assign a_sa_req[p]       = l_req_sa;
      assign a_sa_req_last[p]  = l_sa_req_last;

      assign l_va_gnt = a_va_gnt[p];
      assign l_va_gnt_out_vc = a_va_gnt_out_vc[p];
      assign l_sa_gnt = a_sa_gnt[p];
      assign l_sa_pick = a_sa_pick[p];

      for (genvar v = 0; v < NUM_VC; v = v + 1) begin : gen_vc_fold

        assign a_va_req_out_port[p][v] = l_va_req_out_port[v];
        assign a_sa_req_out_port[p][v] = l_sa_req_out_port[v];
        assign a_sa_req_out_vc[p][v]   = l_sa_req_out_vc[v];

      end

      assign xbar_in_data[p]        = l_st_flit_data;
      assign xbar_in_route_next[p]  = l_st_route_next;
      assign credit_return_valid[p] = l_credit_return;

    end
  endgenerate

  arbiter #(
      .NUM_PORTS    (NUM_PORTS),
      .NUM_VC       (NUM_VC),
      .LOCAL_IDX    (LOCAL_IDX),
      .DIR_CREDITS  (FIFO_DEPTH),
      .LOCAL_CREDITS(LOCAL_CREDITS)
  ) u_arb (
      .clk             (clk),
      .rst_n           (rst_n),

      .va_req          (a_va_req),
      .va_req_out_port (a_va_req_out_port),
      .va_req_single   (a_va_req_single),
      .va_gnt          (a_va_gnt),
      .va_gnt_out_vc   (a_va_gnt_out_vc),

      .sa_req          (a_sa_req),
      .sa_req_out_port (a_sa_req_out_port),
      .sa_req_out_vc   (a_sa_req_out_vc),
      .sa_req_last     (a_sa_req_last),
      .sa_gnt          (a_sa_gnt),
      .sa_pick         (a_sa_pick),

      .xbar_sel        (a_xbar_sel),
      .st_valid        (a_st_valid),
      .st_out_vc       (a_st_out_vc),

      .ds_credit_valid (ds_credit_valid)
  );

  crossbar #(
      .NUM_PORTS(NUM_PORTS),
      .FLIT_W   (FLIT_W)
  ) u_xbar (
      .clk                (clk),
      .rst_n              (rst_n),
      .xbar_in_data       (xbar_in_data),
      .xbar_in_route_next (xbar_in_route_next),
      .xbar_sel           (a_xbar_sel),
      .st_valid           (a_st_valid),
      .xbar_out_data      (xbar_out_data),
      .xbar_out_route_next(xbar_out_route_next)
  );

  generate
    for (genvar p = 0; p < NUM_PORTS; p = p + 1) begin : gen_out_port

      logic [FLIT_W-1:0] l_xbar_data;
      logic [3:0]  l_xbar_route_next;
      logic        l_st_valid;
      logic [VC_W-1:0]  l_st_out_vc;

      logic [FLIT_W-1:0] l_flit_data;
      logic        l_flit_valid;
      logic [VC_W-1:0]  l_vc_id;

      assign l_xbar_data       = xbar_out_data[p];
      assign l_xbar_route_next = xbar_out_route_next[p];
      assign l_st_valid        = a_st_valid[p];
      assign l_st_out_vc       = a_st_out_vc[p];

      noc_output_port #(

          .FLIT_W(FLIT_W),
          .NUM_VC(NUM_VC)
      ) u_out_port (
          .clk                (clk),
          .rst_n              (rst_n),
          .xbar_out_data      (l_xbar_data),
          .xbar_out_route_next(l_xbar_route_next),
          .st_valid           (l_st_valid),
          .st_out_vc          (l_st_out_vc),
          .flit_data          (l_flit_data),
          .flit_valid         (l_flit_valid),
          .vc_id              (l_vc_id)
      );

      assign out_flit_data[p] = l_flit_data;
      assign out_flit_valid[p] = l_flit_valid;
      assign out_vc_id[p]     = l_vc_id;

    end
  endgenerate

  // synthesis translate_off

  // Verification-only ownership model, independent of input-port state.
  logic [NUM_PORTS-1:0][NUM_VC-1:0] check_owned;
  logic [NUM_PORTS-1:0][NUM_VC-1:0][3:0] check_port;
  logic [NUM_PORTS-1:0][NUM_VC-1:0][VC_W-1:0] check_vc;
  int unsigned check_owners [NUM_PORTS][NUM_VC];

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      check_owned <= '0;
      check_port <= '0;
      check_vc <= '0;
    end else begin
      for (int p = 0; p < NUM_PORTS; p++)
        for (int v = 0; v < NUM_VC; v++) begin
          if (a_va_gnt[p][v]) begin
            check_owned[p][v] <= 1'b1;
            check_port[p][v] <= a_va_req_out_port[p][v];
            check_vc[p][v] <= a_va_gnt_out_vc[p][v];
          end
          if (a_sa_gnt[p][v] && a_sa_req_last[p][v]) check_owned[p][v] <= 1'b0;
        end
    end
  end

  always_comb begin
    for (int o = 0; o < NUM_PORTS; o++)
      for (int k = 0; k < NUM_VC; k++) begin
        check_owners[o][k] = 0;
        for (int p = 0; p < NUM_PORTS; p++)
          for (int v = 0; v < NUM_VC; v++)
            if (check_owned[p][v] && (check_vc[p][v] == VC_W'(k)) &&
                (check_port[p][v] == ((o == 0) ? 4'b0 : (4'b1 << (o-1)))))
              check_owners[o][k]++;
      end
  end

  for (genvar p = 0; p < NUM_PORTS; p++) begin : gen_assignment_check
    for (genvar v = 0; v < NUM_VC; v++) begin : gen_vc_check
      assert property (@(posedge clk) disable iff (!rst_n)
                       a_va_gnt[p][v] |-> !check_owned[p][v])
        else $error("router_top: input VC allocated twice");
      assert property (@(posedge clk) disable iff (!rst_n)
                       a_sa_req[p][v] |-> check_owned[p][v] &&
                       (a_sa_req_out_port[p][v] == check_port[p][v]) &&
                       (a_sa_req_out_vc[p][v] == check_vc[p][v]))
        else $error("router_top: SA does not use packet's allocated resource");
      assert property (@(posedge clk) disable iff (!rst_n)
                       check_owners[p][v] <= 1)
        else $error("router_top: multiple live owners of one output VC");
      for (genvar o = 0; o < NUM_PORTS; o++) begin : gen_transmit_check
        localparam logic [3:0] OUT_DIR = (o == 0) ? 4'b0 : (4'b1 << (o-1));
        assert property (@(posedge clk) disable iff (!rst_n)
                         (a_sa_gnt[p][v] && a_sa_req_out_port[p][v] == OUT_DIR) |->
                         a_st_valid[o] && (a_xbar_sel[o] == 3'(p)) &&
                         (a_st_out_vc[o] == check_vc[p][v]))
          else $error("router_top: transmitted VC differs from allocation");
      end
    end
  end
  // synthesis translate_on

  generate
    for (genvar p = 0; p < NUM_PORTS; p = p + 1) begin : gen_top_assert

      assert property (@(posedge clk) disable iff (!rst_n)
                       a_sa_gnt[p] == (a_sa_gnt[p] & a_sa_pick[p]))
        else $error("router_top: port %0d granted without a stage-1 pick", p);

      assert property (@(posedge clk) disable iff (!rst_n)
                       !HAS_P[p] |-> !(|credit_return_valid[p]))
        else $error("router_top: port %0d has no link but returned credits %b",
                    p, credit_return_valid[p]);

      assert property (@(posedge clk) disable iff (!rst_n)
                       !HAS_P[p] |-> !a_st_valid[p])
        else $error("router_top: something was routed out of absent port %0d", p);

      assert property (@(posedge clk) disable iff (!rst_n)
                       a_sa_gnt[p] == (a_sa_gnt[p] & a_sa_req[p]))
        else $error("router_top: port %0d granted a VC that did not request (gnt=%b req=%b)",
                    p, a_sa_gnt[p], a_sa_req[p]);

    end
  endgenerate

endmodule
