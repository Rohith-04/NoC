// Buffers input VCs and maintains packet routing and output-VC assignments.

`timescale 1ns / 1ps

module noc_input_port #(
    parameter int         FLIT_W        = 40,

    parameter int         DEPTH         = 4,
    parameter int         NUM_VC        = 4,
    parameter logic [2:0] CUR_X         = '0,
    parameter logic [2:0] CUR_Y         = '0,
    parameter bit         IS_LOCAL_PORT = 0
) (
    input logic clk,
    input logic rst_n,

    input logic [FLIT_W-1:0] flit_data,
    input logic        flit_valid,
    input logic [VC_W-1:0]  vc_id,

    output logic [NUM_VC-1:0] credit_return_valid,

    output logic [NUM_VC-1:0] req_va,
    output logic [3:0]        va_req_out_port  [NUM_VC],
    output logic [NUM_VC-1:0] va_req_single,
    input  logic [NUM_VC-1:0] va_gnt,
    input  logic [NUM_VC-1:0][VC_W-1:0] va_gnt_out_vc,

    output logic [NUM_VC-1:0] req_sa,
    output logic [3:0]        sa_req_out_port [NUM_VC],
    output logic [VC_W-1:0]        sa_req_out_vc   [NUM_VC],
    output logic [NUM_VC-1:0] sa_req_last,
    input  logic [NUM_VC-1:0] sa_gnt,
    input  logic [NUM_VC-1:0] sa_pick,

    output logic [FLIT_W-1:0] st_flit_data,
    output logic [3:0]  st_route_next
);

  localparam int VC_W = (NUM_VC > 1) ? $clog2(NUM_VC) : 1;

  initial begin
    assert ((NUM_VC == 2) || (NUM_VC == 4) || (NUM_VC == 8))
    else $fatal(1, "noc_input_port: NUM_VC must be 2, 4 or 8 so that VC_W = clog2(NUM_VC) addresses it exactly, got %0d", NUM_VC);

    assert (FLIT_W >= 16)
    else $fatal(1, "noc_input_port: FLIT_W must be at least 16, got %0d", FLIT_W);
  end

  localparam logic [1:0] FLIT_BODY      = 2'b00;
  localparam logic [1:0] FLIT_HEAD      = 2'b01;
  localparam logic [1:0] FLIT_TAIL      = 2'b10;
  localparam logic [1:0] FLIT_HEAD_TAIL = 2'b11;

  localparam logic [3:0] DIR_LOCAL = 4'b0000;
  localparam logic [3:0] DIR_NORTH = 4'b0001;
  localparam logic [3:0] DIR_EAST  = 4'b0010;
  localparam logic [3:0] DIR_WEST  = 4'b0100;
  localparam logic [3:0] DIR_SOUTH = 4'b1000;

  logic [NUM_VC-1:0] head_valid;

  logic [NUM_VC-1:0] arrive;

  logic [3:0] out_port [NUM_VC];

  // Indexed by input FIFO; values identify assigned downstream FIFOs.
  logic [VC_W-1:0] out_vc [NUM_VC];
  logic [NUM_VC-1:0] assignment_valid;

  logic [NUM_VC-1:0] in_pkt;

  logic [NUM_VC-1:0] fifo_wr_enable;
  logic [NUM_VC-1:0] fetch;

  logic [FLIT_W-1:0] fifo_data_out [NUM_VC];

  logic [NUM_VC-1:0] fifo_empty;
  logic [NUM_VC-1:0] fifo_full;
  logic [NUM_VC-1:0] fifo_err;

  logic [2:0] rc_dest_x [NUM_VC];
  logic [2:0] rc_dest_y [NUM_VC];

  logic [3:0] rc_route_in [NUM_VC];

  logic [3:0] rc_route_self [NUM_VC];

  logic [3:0] rc_route_next [NUM_VC];

  logic [1:0] flit_type [NUM_VC];
  logic [NUM_VC-1:0] is_head;
  logic [NUM_VC-1:0] is_last;

  genvar i;

  generate

    for (i = 0; i < NUM_VC; i++) begin : gen_vc

      always_comb begin
        fifo_wr_enable[i] = flit_valid && (vc_id == VC_W'(i));
      end

      always_comb begin
        fetch[i] = (!head_valid[i] || sa_gnt[i]) &&
                   (!fifo_empty[i] || fifo_wr_enable[i]);
      end

      fifo #(
          .WIDTH(FLIT_W),
          .DEPTH(DEPTH)
      ) u_fifo (
          .clk       (clk),
          .rst_n     (rst_n),

          .wr_enable (fifo_wr_enable[i]),
          .rd_enable (fetch[i]),

          .data_in   (flit_data),
          .data_out  (fifo_data_out[i]),

          .empty     (fifo_empty[i]),
          .full      (fifo_full[i]),
          .err       (fifo_err[i])
      );

      always_comb begin
        flit_type[i]   = fifo_data_out[i][1:0];

        rc_route_in[i] = fifo_data_out[i][13:10];
        rc_dest_y[i]   = fifo_data_out[i][9:7];
        rc_dest_x[i]   = fifo_data_out[i][6:4];

        is_head[i]     = flit_type[i][0];
        is_last[i]     = flit_type[i][1];
      end

      route_compute #(
          .CUR_X         (CUR_X),
          .CUR_Y         (CUR_Y),
          .IS_LOCAL_PORT (IS_LOCAL_PORT)
      ) u_route_compute (
          .dest_x     (rc_dest_x[i]),
          .dest_y     (rc_dest_y[i]),
          .route_in   (rc_route_in[i]),

          .route_self (rc_route_self[i]),
          .route_next (rc_route_next[i])
      );

      always_comb begin
        req_va[i]       = head_valid[i] && !assignment_valid[i] && is_head[i];
        va_req_single[i] = (flit_type[i] == FLIT_HEAD_TAIL);
      end

      always_comb begin
        va_req_out_port[i] = arrive[i] ? rc_route_self[i] : out_port[i];
      end

      always_comb begin
        req_sa[i]          = head_valid[i] && assignment_valid[i];
        sa_req_out_port[i] = out_port[i];
        sa_req_out_vc[i]   = out_vc[i];
        sa_req_last[i]     = is_last[i];
      end

    end

  endgenerate

  always_ff @(posedge clk) begin

    if (!rst_n) begin

      head_valid          <= '0;
      arrive              <= '0;
      credit_return_valid <= '0;
      in_pkt              <= '0;

      for (int v = 0; v < NUM_VC; v++) begin
        out_port[v] <= DIR_LOCAL;
      end

    end

    else begin

      arrive              <= fetch;
      credit_return_valid <= fetch;

      for (int v = 0; v < NUM_VC; v++) begin

        if (fetch[v]) begin
          head_valid[v] <= 1'b1;
        end
        else if (sa_gnt[v]) begin
          head_valid[v] <= 1'b0;
        end

        if (arrive[v] && is_head[v]) begin
          out_port[v] <= rc_route_self[v];
        end

        if (arrive[v]) begin
          if (is_head[v]) in_pkt[v] <= !is_last[v];
          else if (is_last[v]) in_pkt[v] <= 1'b0;
        end

      end

    end
  end

  always_ff @(posedge clk) begin

    if (!rst_n) begin

      assignment_valid <= '0;
      for (int v = 0; v < NUM_VC; v++) out_vc[v] <= '0;

    end

    else begin

      for (int v = 0; v < NUM_VC; v++) begin

        // Capture once per packet; BODY and TAIL retain this mapping.
        if (va_gnt[v]) begin
          assignment_valid[v] <= 1'b1;
          out_vc[v] <= va_gnt_out_vc[v];
        end

        // Release only after final SA grants the packet's last flit.
        if (sa_gnt[v] && is_last[v]) begin
          assignment_valid[v] <= 1'b0;
        end

      end

    end

  end

  always_comb begin

    st_flit_data = '0;
    st_route_next = '0;

    for (int v = 0; v < NUM_VC; v++) begin
      if (sa_pick[v]) begin
        st_flit_data  |= fifo_data_out[v];
        st_route_next |= rc_route_next[v];
      end
    end

  end

  initial begin
    assert ((FLIT_BODY == 2'b00) && (FLIT_HEAD == 2'b01) &&
            (FLIT_TAIL == 2'b10) && (FLIT_HEAD_TAIL == 2'b11))
      else $error("noc_input_port: flit type constants have drifted from the spec encoding");
  end

  genvar g;

  generate
    for (g = 0; g < NUM_VC; g = g + 1) begin : gen_assert_vc

      assert property (@(posedge clk) disable iff (!rst_n)
                       va_gnt[g] |-> req_va[g])
        else $error("noc_input_port: va_gnt without va_req on VC %0d", g);

      assert property (@(posedge clk) disable iff (!rst_n)
                       sa_gnt[g] |-> req_sa[g])
        else $error("noc_input_port: sa_gnt without sa_req on VC %0d", g);

      assert property (@(posedge clk) disable iff (!rst_n)
                       sa_gnt[g] |-> sa_pick[g])
        else $error("noc_input_port: sa_gnt without sa_pick on VC %0d", g);

      assert property (@(posedge clk) disable iff (!rst_n)
                       fetch[g] |-> (!head_valid[g] || sa_gnt[g]))
        else $error("noc_input_port: fetch with head register stuck on VC %0d", g);

      assert property (@(posedge clk) disable iff (!rst_n)
                       fetch[g] |-> (!fifo_empty[g] || fifo_wr_enable[g]))
        else $error("noc_input_port: fetch from empty VC %0d with no bypass write", g);

      assert property (@(posedge clk) disable iff (!rst_n)
                       !(fifo_wr_enable[g] && fifo_full[g]))
        else $error("noc_input_port: wrote into full VC %0d FIFO - credit accounting broken", g);

      assert property (@(posedge clk) disable iff (!rst_n) !fifo_err[g])
        else $error("noc_input_port: FIFO raised err on VC %0d", g);

      assert property (@(posedge clk) disable iff (!rst_n)
                       assignment_valid[g] && !(sa_gnt[g] && is_last[g]) |=>
                       assignment_valid[g] && $stable(out_vc[g]) && $stable(out_port[g]))
        else $error("noc_input_port: packet assignment changed while owned");
      assert property (@(posedge clk) disable iff (!rst_n)
                       va_gnt[g] |-> (int'(va_gnt_out_vc[g]) / (NUM_VC/2) == g / (NUM_VC/2)))
        else $error("noc_input_port: allocation crossed traffic classes");

      assert property (@(posedge clk) disable iff (!rst_n)
                       va_gnt[g] |-> !assignment_valid[g])
        else $error("noc_input_port: va_gnt while assignment already valid on VC %0d", g);

      assert property (@(posedge clk) disable iff (!rst_n)
                       head_valid[g] |->
                         (is_head[g] === ((flit_type[g] == FLIT_HEAD) ||
                                          (flit_type[g] == FLIT_HEAD_TAIL))) &&
                         (is_last[g] === ((flit_type[g] == FLIT_TAIL) ||
                                          (flit_type[g] == FLIT_HEAD_TAIL))))
        else $error("noc_input_port: flit type encoding broken on VC %0d: type=%b",
                    g, flit_type[g]);

      assert property (@(posedge clk) disable iff (!rst_n)
                       head_valid[g] |->
                         ((out_port[g] == DIR_LOCAL) || (out_port[g] == DIR_NORTH) ||
                          (out_port[g] == DIR_EAST)  || (out_port[g] == DIR_WEST)  ||
                          (out_port[g] == DIR_SOUTH)))
        else $error("noc_input_port: out_port not a legal direction on VC %0d: %b",
                    g, out_port[g]);

      assert property (@(posedge clk) disable iff (!rst_n)
                       arrive[g] |-> (in_pkt[g] ? !is_head[g] : is_head[g]))
        else $error("noc_input_port: flit sequence broken on VC %0d: type=%b while in_pkt=%b",
                    g, flit_type[g], in_pkt[g]);

    end

    assert property (@(posedge clk) disable iff (!rst_n)
                     $countones(sa_pick) <= 1)
      else $error("noc_input_port: sa_pick not one-hot: %b", sa_pick);

    assert property (@(posedge clk) disable iff (!rst_n)
                     $countones(sa_gnt) <= 1)
      else $error("noc_input_port: multiple VCs granted on one port: %b", sa_gnt);

  endgenerate

endmodule
