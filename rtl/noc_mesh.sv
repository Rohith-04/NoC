// Connects a configurable mesh of routers and reverse credit links.

`timescale 1ns / 1ps

module noc_mesh #(
    parameter int ROWS          = 2,
    parameter int COLS          = 2,
    parameter int NUM_PORTS     = 5,
    parameter int FLIT_W        = 40,
    parameter int NUM_VC        = 4,
    parameter int FIFO_DEPTH    = 4,
    parameter int LOCAL_CREDITS = 4
) (
    input logic clk,
    input logic rst_n,

    input  logic [ROWS-1:0][COLS-1:0][FLIT_W-1:0] inj_data,
    input  logic [ROWS-1:0][COLS-1:0]             inj_valid,
    input  logic [ROWS-1:0][COLS-1:0][VC_W-1:0]   inj_vc,

    output logic [ROWS-1:0][COLS-1:0][FLIT_W-1:0] ej_data,
    output logic [ROWS-1:0][COLS-1:0]             ej_valid,
    output logic [ROWS-1:0][COLS-1:0][VC_W-1:0]   ej_vc,

    output logic [ROWS-1:0][COLS-1:0][NUM_VC-1:0] lc_credit,
    input  logic [ROWS-1:0][COLS-1:0][NUM_VC-1:0] lc_ds_credit
);

  localparam int VC_W = (NUM_VC > 1) ? $clog2(NUM_VC) : 1;

  localparam int PORT_LOCAL = 0;
  localparam int PORT_NORTH = 1;
  localparam int PORT_EAST  = 2;
  localparam int PORT_WEST  = 3;
  localparam int PORT_SOUTH = 4;

  initial begin
    assert ((ROWS >= 1) && (ROWS <= 8) && (COLS >= 1) && (COLS <= 8))
    else $fatal(1, "noc_mesh: ROWS and COLS must each be 1..8 -- the header's DEST_Y/DEST_X are 3 bits, so 8x8 is the largest addressable mesh -- got %0dx%0d", ROWS, COLS);

    assert ((NUM_VC == 2) || (NUM_VC == 4) || (NUM_VC == 8))
    else $fatal(1, "noc_mesh: NUM_VC must be 2, 4 or 8 so that VC_W = clog2(NUM_VC) addresses it exactly, got %0d", NUM_VC);

    assert (FLIT_W >= 16)
    else $fatal(1, "noc_mesh: FLIT_W must be at least 16, got %0d", FLIT_W);

    assert ((FIFO_DEPTH >= 2) && ((FIFO_DEPTH & (FIFO_DEPTH - 1)) == 0))
    else $fatal(1, "noc_mesh: FIFO_DEPTH must be a power of two >= 2, got %0d", FIFO_DEPTH);
  end

  logic [ROWS-1:0][COLS-1:0][NUM_PORTS-1:0][FLIT_W-1:0]   L_out_data;
  logic [ROWS-1:0][COLS-1:0][NUM_PORTS-1:0]               L_out_valid;
  logic [ROWS-1:0][COLS-1:0][NUM_PORTS-1:0][VC_W-1:0]     L_out_vc;
  logic [ROWS-1:0][COLS-1:0][NUM_PORTS-1:0][NUM_VC-1:0]   L_cred_ret;

  generate
    for (genvar r = 0; r < ROWS; r++) begin : g_row
      for (genvar c = 0; c < COLS; c++) begin : g_col

        logic [NUM_PORTS-1:0][FLIT_W-1:0]  t_in_data;
        logic [NUM_PORTS-1:0]              t_in_valid;
        logic [NUM_PORTS-1:0][VC_W-1:0]    t_in_vc;
        logic [NUM_PORTS-1:0][FLIT_W-1:0]  t_out_data;
        logic [NUM_PORTS-1:0]              t_out_valid;
        logic [NUM_PORTS-1:0][VC_W-1:0]    t_out_vc;
        logic [NUM_PORTS-1:0][NUM_VC-1:0]  t_cred_ret;
        logic [NUM_PORTS-1:0][NUM_VC-1:0]  t_ds_cred;

        assign t_in_data[PORT_LOCAL]  = inj_data[r][c];
        assign t_in_valid[PORT_LOCAL] = inj_valid[r][c];
        assign t_in_vc[PORT_LOCAL]    = inj_vc[r][c];
        assign t_ds_cred[PORT_LOCAL]  = lc_ds_credit[r][c];

        assign ej_data[r][c]   = t_out_data[PORT_LOCAL];
        assign ej_valid[r][c]  = t_out_valid[PORT_LOCAL];
        assign ej_vc[r][c]     = t_out_vc[PORT_LOCAL];
        assign lc_credit[r][c] = t_cred_ret[PORT_LOCAL];

        if (r > 0) begin : g_n
          assign t_in_data[PORT_NORTH]  = L_out_data[r-1][c][PORT_SOUTH];
          assign t_in_valid[PORT_NORTH] = L_out_valid[r-1][c][PORT_SOUTH];
          assign t_in_vc[PORT_NORTH]    = L_out_vc[r-1][c][PORT_SOUTH];
          assign t_ds_cred[PORT_NORTH]  = L_cred_ret[r-1][c][PORT_SOUTH];
        end else begin : g_n_tie
          assign t_in_data[PORT_NORTH]  = '0;
          assign t_in_valid[PORT_NORTH] = 1'b0;
          assign t_in_vc[PORT_NORTH]    = '0;
          assign t_ds_cred[PORT_NORTH]  = '0;
        end

        if (r < ROWS-1) begin : g_s
          assign t_in_data[PORT_SOUTH]  = L_out_data[r+1][c][PORT_NORTH];
          assign t_in_valid[PORT_SOUTH] = L_out_valid[r+1][c][PORT_NORTH];
          assign t_in_vc[PORT_SOUTH]    = L_out_vc[r+1][c][PORT_NORTH];
          assign t_ds_cred[PORT_SOUTH]  = L_cred_ret[r+1][c][PORT_NORTH];
        end else begin : g_s_tie
          assign t_in_data[PORT_SOUTH]  = '0;
          assign t_in_valid[PORT_SOUTH] = 1'b0;
          assign t_in_vc[PORT_SOUTH]    = '0;
          assign t_ds_cred[PORT_SOUTH]  = '0;
        end

        if (c > 0) begin : g_w
          assign t_in_data[PORT_WEST]   = L_out_data[r][c-1][PORT_EAST];
          assign t_in_valid[PORT_WEST]  = L_out_valid[r][c-1][PORT_EAST];
          assign t_in_vc[PORT_WEST]     = L_out_vc[r][c-1][PORT_EAST];
          assign t_ds_cred[PORT_WEST]   = L_cred_ret[r][c-1][PORT_EAST];
        end else begin : g_w_tie
          assign t_in_data[PORT_WEST]   = '0;
          assign t_in_valid[PORT_WEST]  = 1'b0;
          assign t_in_vc[PORT_WEST]     = '0;
          assign t_ds_cred[PORT_WEST]   = '0;
        end

        if (c < COLS-1) begin : g_e
          assign t_in_data[PORT_EAST]   = L_out_data[r][c+1][PORT_WEST];
          assign t_in_valid[PORT_EAST]  = L_out_valid[r][c+1][PORT_WEST];
          assign t_in_vc[PORT_EAST]     = L_out_vc[r][c+1][PORT_WEST];
          assign t_ds_cred[PORT_EAST]   = L_cred_ret[r][c+1][PORT_WEST];
        end else begin : g_e_tie
          assign t_in_data[PORT_EAST]   = '0;
          assign t_in_valid[PORT_EAST]  = 1'b0;
          assign t_in_vc[PORT_EAST]     = '0;
          assign t_ds_cred[PORT_EAST]   = '0;
        end

        router_top #(
            .FLIT_W        (FLIT_W),
            .NUM_VC        (NUM_VC),
            .FIFO_DEPTH    (FIFO_DEPTH),
            .LOCAL_CREDITS (LOCAL_CREDITS),
            .CUR_X         (3'(c)),
            .CUR_Y         (3'(r)),
            .HAS_LOCAL     (1'b1),
            .HAS_NORTH     (r > 0),
            .HAS_EAST      (c < COLS-1),
            .HAS_WEST      (c > 0),
            .HAS_SOUTH     (r < ROWS-1)
        ) u_tile (
            .clk                (clk),
            .rst_n              (rst_n),
            .in_flit_data       (t_in_data),
            .in_flit_valid      (t_in_valid),
            .in_vc_id           (t_in_vc),
            .out_flit_data      (t_out_data),
            .out_flit_valid     (t_out_valid),
            .out_vc_id          (t_out_vc),
            .credit_return_valid(t_cred_ret),
            .ds_credit_valid    (t_ds_cred)
        );

        assign L_out_data[r][c]  = t_out_data;
        assign L_out_valid[r][c] = t_out_valid;
        assign L_out_vc[r][c]    = t_out_vc;
        assign L_cred_ret[r][c]  = t_cred_ret;

      end
    end
  endgenerate

  always_ff @(posedge clk) begin : walls
    if (rst_n) begin
      for (int r = 0; r < ROWS; r++) begin
        for (int c = 0; c < COLS; c++) begin
          if (r == 0)
            assert (!L_out_valid[r][c][PORT_NORTH] &&
                    (L_out_data[r][c][PORT_NORTH]  == '0) &&
                    (L_out_vc[r][c][PORT_NORTH]    == '0) &&
                    (L_cred_ret[r][c][PORT_NORTH]  == '0))
            else $error("noc_mesh: tile (%0d,%0d) has no north neighbour but drove or credited its north link", r, c);

          if (r == ROWS-1)
            assert (!L_out_valid[r][c][PORT_SOUTH] &&
                    (L_out_data[r][c][PORT_SOUTH]  == '0) &&
                    (L_out_vc[r][c][PORT_SOUTH]    == '0) &&
                    (L_cred_ret[r][c][PORT_SOUTH]  == '0))
            else $error("noc_mesh: tile (%0d,%0d) has no south neighbour but drove or credited its south link", r, c);

          if (c == 0)
            assert (!L_out_valid[r][c][PORT_WEST] &&
                    (L_out_data[r][c][PORT_WEST]   == '0) &&
                    (L_out_vc[r][c][PORT_WEST]     == '0) &&
                    (L_cred_ret[r][c][PORT_WEST]   == '0))
            else $error("noc_mesh: tile (%0d,%0d) has no west neighbour but drove or credited its west link", r, c);

          if (c == COLS-1)
            assert (!L_out_valid[r][c][PORT_EAST] &&
                    (L_out_data[r][c][PORT_EAST]   == '0) &&
                    (L_out_vc[r][c][PORT_EAST]     == '0) &&
                    (L_cred_ret[r][c][PORT_EAST]   == '0))
            else $error("noc_mesh: tile (%0d,%0d) has no east neighbour but drove or credited its east link", r, c);
        end
      end
    end
  end

endmodule
