// Allocates same-class output VCs, switch access, and downstream credits.

`timescale 1ns / 1ps

module arbiter #(
    parameter int NUM_PORTS     = 5,
    parameter int NUM_VC        = 4,
    parameter int LOCAL_IDX     = 0,
    parameter int DIR_CREDITS   = 4,

    parameter int LOCAL_CREDITS = 4

) (
    input logic clk,
    input logic rst_n,

    input  logic [NUM_PORTS-1:0][NUM_VC-1:0]       va_req,
    input  logic [NUM_PORTS-1:0][NUM_VC-1:0][3:0]  va_req_out_port,
    input  logic [NUM_PORTS-1:0][NUM_VC-1:0]       va_req_single,
    output logic [NUM_PORTS-1:0][NUM_VC-1:0]       va_gnt,
    output logic [NUM_PORTS-1:0][NUM_VC-1:0][VC_W-1:0] va_gnt_out_vc,

    input  logic [NUM_PORTS-1:0][NUM_VC-1:0]       sa_req,
    input  logic [NUM_PORTS-1:0][NUM_VC-1:0][3:0]  sa_req_out_port,
    input  logic [NUM_PORTS-1:0][NUM_VC-1:0][VC_W-1:0]  sa_req_out_vc,
    input  logic [NUM_PORTS-1:0][NUM_VC-1:0]       sa_req_last,
    output logic [NUM_PORTS-1:0][NUM_VC-1:0]       sa_gnt,
    output logic [NUM_PORTS-1:0][NUM_VC-1:0]       sa_pick,

    output logic [NUM_PORTS-1:0][2:0]  xbar_sel,
    output logic [NUM_PORTS-1:0]       st_valid,
    output logic [NUM_PORTS-1:0][VC_W-1:0]  st_out_vc,

    input  logic [NUM_PORTS-1:0][NUM_VC-1:0] ds_credit_valid
);

  localparam int OIDX_W = (NUM_PORTS > 1) ? $clog2(NUM_PORTS) : 1;
  localparam int VC_W = (NUM_VC > 1) ? $clog2(NUM_VC) : 1;

  localparam int CRED_MAX = (DIR_CREDITS > LOCAL_CREDITS) ? DIR_CREDITS : LOCAL_CREDITS;
  localparam int CRED_W   = $clog2(CRED_MAX + 1);

  localparam logic [3:0] DIR_LOCAL = 4'b0000;
  localparam logic [3:0] DIR_NORTH = 4'b0001;
  localparam logic [3:0] DIR_EAST  = 4'b0010;
  localparam logic [3:0] DIR_WEST  = 4'b0100;
  localparam logic [3:0] DIR_SOUTH = 4'b1000;

  function automatic logic [2:0] dir_to_idx(input logic [3:0] dir);
    case (dir)
      DIR_LOCAL: dir_to_idx = 3'd0;
      DIR_NORTH: dir_to_idx = 3'd1;
      DIR_EAST:  dir_to_idx = 3'd2;
      DIR_WEST:  dir_to_idx = 3'd3;
      DIR_SOUTH: dir_to_idx = 3'd4;
      default:   dir_to_idx = 3'd0;
    endcase
  endfunction

  function automatic int unsigned rr_pick_vc(input logic [NUM_VC-1:0] mask,
                                             input int unsigned start);
    rr_pick_vc = NUM_VC;
    for (int i = 0; i < NUM_VC; i++) begin
      int unsigned idx = (start + i) % NUM_VC;
      if ((rr_pick_vc == NUM_VC) && mask[idx]) rr_pick_vc = idx;
    end
  endfunction

  function automatic int unsigned rr_pick_port(input logic [NUM_PORTS-1:0] mask,
                                               input int unsigned start);
    rr_pick_port = NUM_PORTS;
    for (int i = 0; i < NUM_PORTS; i++) begin
      int unsigned idx = (start + i) % NUM_PORTS;
      if ((rr_pick_port == NUM_PORTS) && mask[idx]) rr_pick_port = idx;
    end
  endfunction

  function automatic bit xy_legal(input int p, input int o);
    case (p)
      0: xy_legal = (o == 1) || (o == 2) || (o == 3) || (o == 4);
      1: xy_legal = (o == 4) || (o == 0);
      2: xy_legal = (o == 3) || (o == 1) || (o == 4) || (o == 0);
      3: xy_legal = (o == 2) || (o == 1) || (o == 4) || (o == 0);
      4: xy_legal = (o == 1) || (o == 0);
      default: xy_legal = 1'b0;
    endcase
  endfunction

  function automatic logic [CRED_W-1:0] credit_init(input int o);
    credit_init = (o == LOCAL_IDX) ? CRED_W'(LOCAL_CREDITS) : CRED_W'(DIR_CREDITS);
  endfunction

  function automatic logic [CRED_W-1:0] credit_max(input int o);
    credit_max = (o == LOCAL_IDX) ? CRED_W'(LOCAL_CREDITS) : CRED_W'(DIR_CREDITS);
  endfunction

  logic [NUM_PORTS-1:0][NUM_VC-1:0] alloc_busy;

  logic [NUM_PORTS-1:0][NUM_VC-1:0][CRED_W-1:0] credit_count;

  localparam int NUM_REQ = NUM_PORTS * NUM_VC;
  localparam int REQ_W = $clog2(NUM_REQ);
  localparam int CLASS_VCS = NUM_VC / 2;

  logic [REQ_W-1:0] rr_va [NUM_PORTS][NUM_VC];
  logic [VC_W-1:0] rr1 [NUM_PORTS];
  logic [OIDX_W-1:0] rr2 [NUM_PORTS];
  logic [REQ_W-1:0] row_ridx [NUM_PORTS][NUM_VC];
  logic row_val [NUM_PORTS][NUM_VC];
  int unsigned va_kept [NUM_PORTS][NUM_VC];

  // Earlier rows exclude their winners; each input VC can receive one grant.
  always_comb begin : va_matching
    logic [NUM_REQ-1:0] used_req;
    used_req = '0;
    va_gnt = '0;
    va_gnt_out_vc = '0;
    for (int p = 0; p < NUM_PORTS; p++)
      for (int v = 0; v < NUM_VC; v++) va_kept[p][v] = 0;

    for (int o = 0; o < NUM_PORTS; o++) begin
      used_req = '0;
      for (int k = 0; k < NUM_VC; k++) begin
        int win;
        win = NUM_REQ;
        row_val[o][k] = 1'b0;
        row_ridx[o][k] = '0;

        for (int tier = 0; tier < 2; tier++) begin
          for (int i = 0; i < NUM_REQ; i++) begin
            int r, p, v;
            r = (int'(rr_va[o][k]) + i) % NUM_REQ;
            p = r / NUM_VC;
            v = r % NUM_VC;
            if ((win == NUM_REQ) && !alloc_busy[o][k] && !used_req[r] &&
                va_req[p][v] && (dir_to_idx(va_req_out_port[p][v]) == 3'(o)) &&
                ((v / CLASS_VCS) == (k / CLASS_VCS)) &&
                ((tier == 1) || va_req_single[p][v])) win = r;
          end
        end
        if (win != NUM_REQ) begin
          row_val[o][k] = 1'b1;
          row_ridx[o][k] = REQ_W'(win);
          used_req[win] = 1'b1;
          va_gnt[win / NUM_VC][win % NUM_VC] = 1'b1;
          va_gnt_out_vc[win / NUM_VC][win % NUM_VC] = VC_W'(k);
          va_kept[win / NUM_VC][win % NUM_VC]++;
        end
      end
    end
  end

  int unsigned va_row_count [NUM_PORTS][NUM_VC];
  always_comb begin : count_va_resources
    for (int o = 0; o < NUM_PORTS; o++)
      for (int k = 0; k < NUM_VC; k++) begin
        va_row_count[o][k] = 0;
        for (int p = 0; p < NUM_PORTS; p++)
          for (int v = 0; v < NUM_VC; v++)
            if (va_gnt[p][v] && (dir_to_idx(va_req_out_port[p][v]) == 3'(o)) &&
                (va_gnt_out_vc[p][v] == VC_W'(k))) va_row_count[o][k]++;
      end
  end

  logic [NUM_PORTS-1:0]             s1_valid;
  logic [NUM_PORTS-1:0][VC_W-1:0] s1_idx;
  logic [NUM_PORTS-1:0][VC_W-1:0]        s1_vc;
  logic [NUM_PORTS-1:0][2:0]        s1_oport;
  logic [NUM_PORTS-1:0]             s1_last;

  // Credit eligibility uses the assigned downstream VC.
  always_comb begin : sa_stage1
    for (int p = 0; p < NUM_PORTS; p++) begin

      logic [NUM_VC-1:0] mask;
      int unsigned       win;
      int unsigned       sel;
      int unsigned       o;

      mask = '0;
      for (int v = 0; v < NUM_VC; v++) begin
        o = int'(dir_to_idx(sa_req_out_port[p][v]));
        if (sa_req[p][v] && (credit_count[o][sa_req_out_vc[p][v]] != '0)) mask[v] = 1'b1;
      end

      win = rr_pick_vc(mask, int'(rr1[p]));

      sel = (win != NUM_VC) ? win : 0;

      s1_valid[p] = (win != NUM_VC);
      s1_idx [p]  = VC_W'(sel);
      s1_vc  [p]  = sa_req_out_vc[p][sel];
      s1_oport[p] = dir_to_idx(sa_req_out_port[p][sel]);
      s1_last[p]  = s1_valid[p] && sa_req_last[p][sel];

      sa_pick[p] = '0;
      if (win != NUM_VC) sa_pick[p][sel] = 1'b1;

    end
  end

  logic [NUM_PORTS-1:0][2:0] s2_sel;
  logic [NUM_PORTS-1:0]      s2_any;

  always_comb begin : sa_stage2
    for (int o = 0; o < NUM_PORTS; o++) begin

      logic [NUM_PORTS-1:0] req2;
      logic [OIDX_W-1:0]    w;

      for (int p = 0; p < NUM_PORTS; p++) req2[p] = s1_valid[p] && (s1_oport[p] == 3'(o));

      s2_any[o] = |req2;

      w = OIDX_W'(rr_pick_port(req2, int'(rr2[o])));

      s2_sel[o] = s2_any[o] ? w : '0;

    end
  end

  assign xbar_sel = s2_sel;
  assign st_valid = s2_any;

  always_comb begin : sa_results
    st_out_vc = '0;
    sa_gnt    = '0;

    for (int o = 0; o < NUM_PORTS; o++) begin
      if (st_valid[o]) begin

        for (int p = 0; p < NUM_PORTS; p++) begin
          if (OIDX_W'(p) == xbar_sel[o]) begin
            st_out_vc[o] = s1_vc[p];
            sa_gnt[p][s1_idx[p]] = 1'b1;
          end
        end
      end
    end
  end

  logic [NUM_PORTS-1:0][NUM_VC-1:0] cr_dec;
  logic [NUM_PORTS-1:0][NUM_VC-1:0] cr_inc;

  logic [NUM_PORTS-1:0][NUM_VC-1:0] cr_release;

  always_comb begin : credit_flags
    for (int o = 0; o < NUM_PORTS; o++)
      for (int k = 0; k < NUM_VC; k++) begin
        cr_dec[o][k] = st_valid[o] && (st_out_vc[o] == VC_W'(k));

        cr_release[o][k] = st_valid[o] && s1_last[xbar_sel[o]] && (st_out_vc[o] == VC_W'(k));
      end
  end

  assign cr_inc = ds_credit_valid;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      alloc_busy <= '0;
      for (int o = 0; o < NUM_PORTS; o++) begin
        rr2[o] <= '0;
        for (int k = 0; k < NUM_VC; k++) begin
          rr_va[o][k] <= '0;
          credit_count[o][k] <= credit_init(o);
        end
      end
      for (int p = 0; p < NUM_PORTS; p++) rr1[p] <= '0;

    end else begin

      // Simultaneous credit return and transmission leave the counter unchanged.
      for (int o = 0; o < NUM_PORTS; o++)
        for (int k = 0; k < NUM_VC; k++) begin
          if (cr_dec[o][k] && !cr_inc[o][k]) credit_count[o][k] <= credit_count[o][k] - 1'b1;
          else if (!cr_dec[o][k] && cr_inc[o][k])
            credit_count[o][k] <= credit_count[o][k] + 1'b1;
        end

      for (int p = 0; p < NUM_PORTS; p++)
        if (s1_valid[p] && st_valid[s1_oport[p]] && (xbar_sel[s1_oport[p]] == 3'(p)))
          rr1[p] <= VC_W'((int'(s1_idx[p]) + 1) % NUM_VC);

      for (int o = 0; o < NUM_PORTS; o++)
        if (st_valid[o]) rr2[o] <= OIDX_W'((int'(xbar_sel[o]) + 1) % NUM_PORTS);

      for (int o = 0; o < NUM_PORTS; o++)
        for (int k = 0; k < NUM_VC; k++)
          if (cr_release[o][k]) alloc_busy[o][k] <= 1'b0;

      for (int o = 0; o < NUM_PORTS; o++)
        for (int k = 0; k < NUM_VC; k++)
          if (row_val[o][k]) begin
            alloc_busy[o][k] <= 1'b1;

            rr_va[o][k] <= REQ_W'((int'(row_ridx[o][k]) + 1) % NUM_REQ);
          end

    end
  end

  initial begin
    assert ((NUM_VC == 2) || (NUM_VC == 4) || (NUM_VC == 8))
      else $fatal(1, "arbiter: NUM_VC must be 2, 4, or 8");
  end

  generate
    for (genvar go = 0; go < NUM_PORTS; go++) begin : gen_cr_bound
      for (genvar gk = 0; gk < NUM_VC; gk++) begin : gen_cr_bound_vc

        assert property (@(posedge clk) disable iff (!rst_n)
                         row_val[go][gk] |-> !alloc_busy[go][gk])
          else $error("arbiter: allocated a reserved VC");
        assert property (@(posedge clk) disable iff (!rst_n)
                         (alloc_busy[go][gk] && !cr_release[go][gk]) |=>
                         alloc_busy[go][gk])
          else $error("arbiter: reservation lost without final transmission");

        assert property (@(posedge clk) disable iff (!rst_n)
                         va_row_count[go][gk] <= 1)
          else $error("arbiter: multiple allocations of one output VC");
        assert property (@(posedge clk) disable iff (!rst_n)
                         (va_row_count[go][gk] != 0) == row_val[go][gk])
          else $error("arbiter: grant and reservation disagree");
        assert property (@(posedge clk) disable iff (!rst_n)
                         (cr_dec[go][gk] && !cr_inc[go][gk]) |=>
                         credit_count[go][gk] == $past(credit_count[go][gk]) - CRED_W'(1))
          else $error("arbiter: incorrect mapped credit decrement");
        assert property (@(posedge clk) disable iff (!rst_n)
                         (!cr_dec[go][gk] && cr_inc[go][gk]) |=>
                         credit_count[go][gk] == $past(credit_count[go][gk]) + CRED_W'(1))
          else $error("arbiter: incorrect credit return");
        assert property (@(posedge clk) disable iff (!rst_n)
                         (cr_dec[go][gk] == cr_inc[go][gk]) |=>
                         $stable(credit_count[go][gk]))
          else $error("arbiter: credit count failed to hold");

        assert property (@(posedge clk) disable iff (!rst_n)
                         credit_count[go][gk] <= credit_max(go))
          else $error("arbiter: credit_count[%0d][%0d] out of range: %0d",
                      go, gk, credit_count[go][gk]);

        assert property (@(posedge clk) disable iff (!rst_n)
                         cr_dec[go][gk] |-> (credit_count[go][gk] != '0))
          else $error("arbiter: switched out on [%0d][%0d] with no credit", go, gk);

        assert property (@(posedge clk) disable iff (!rst_n)
                         (cr_inc[go][gk] && !cr_dec[go][gk]) |->
                         (credit_count[go][gk] < credit_max(go)))
          else $error("arbiter: credit return overflow on [%0d][%0d]", go, gk);

        assert property (@(posedge clk) disable iff (!rst_n)
                         cr_release[go][gk] |-> alloc_busy[go][gk])
          else $error("arbiter: row [%0d][%0d] released but was never reserved", go, gk);

        assert property (@(posedge clk) disable iff (!rst_n)
                         !(cr_release[go][gk] && row_val[go][gk]))
          else $error("arbiter: row [%0d][%0d] released and reserved in the same cycle",
                      go, gk);

      end
    end
  endgenerate

  generate
    for (genvar gp = 0; gp < NUM_PORTS; gp++) begin : gen_sa

      assert property (@(posedge clk) disable iff (!rst_n)
                       $countones(sa_pick[gp]) <= 1)
        else $error("arbiter: stage-1 pick not one-hot on port %0d: %b", gp, sa_pick[gp]);

      assert property (@(posedge clk) disable iff (!rst_n)
                       $countones(sa_gnt[gp]) <= 1)
        else $error("arbiter: multiple stage-2 grants on port %0d: %b", gp, sa_gnt[gp]);

      for (genvar gv = 0; gv < NUM_VC; gv++) begin : gen_sa_gnt

        assert property (@(posedge clk) disable iff (!rst_n)
                         sa_gnt[gp][gv] |-> sa_pick[gp][gv])
          else $error("arbiter: grant without stage-1 pick on port %0d vc %0d", gp, gv);

        assert property (@(posedge clk) disable iff (!rst_n)
                         sa_gnt[gp][gv] |->
                         (credit_count[dir_to_idx(sa_req_out_port[gp][gv])]
                                           [sa_req_out_vc[gp][gv]] != '0))
          else $error("arbiter: granted port %0d vc %0d with zero credit", gp, gv);

        assert property (@(posedge clk) disable iff (!rst_n)
                         sa_gnt[gp][gv] |->
                         xy_legal(int'(gp), int'(dir_to_idx(sa_req_out_port[gp][gv]))))
          else $error("arbiter: illegal XY pair in->out (%0d -> %0d) on port %0d vc %0d",
                      gp, dir_to_idx(sa_req_out_port[gp][gv]), gp, gv);

        assert property (@(posedge clk) disable iff (!rst_n)
                         sa_req[gp][gv] |-> $onehot0(sa_req_out_port[gp][gv]))
          else $error("arbiter: sa_req_out_port not one-hot0 on port %0d vc %0d: %b",
                      gp, gv, sa_req_out_port[gp][gv]);

        assert property (@(posedge clk) disable iff (!rst_n)
                         va_req[gp][gv] |-> $onehot0(va_req_out_port[gp][gv]))
          else $error("arbiter: va_req_out_port not one-hot0 on port %0d vc %0d: %b",
                      gp, gv, va_req_out_port[gp][gv]);

      end

      for (genvar gv = 0; gv < NUM_VC; gv++) begin : gen_va_req

        assert property (@(posedge clk) disable iff (!rst_n)
                         va_kept[gp][gv] <= 1)
          else $error("arbiter: requester (port %0d, vc %0d) won %0d rows",
                      gp, gv, va_kept[gp][gv]);

        assert property (@(posedge clk) disable iff (!rst_n)
                         va_gnt[gp][gv] |-> va_req[gp][gv])
          else $error("arbiter: VA granted port %0d vc %0d without a request", gp, gv);

        assert property (@(posedge clk) disable iff (!rst_n)
                         va_gnt[gp][gv] |-> (int'(va_gnt_out_vc[gp][gv]) / CLASS_VCS == gv / CLASS_VCS))
          else $error("arbiter: VA granted port %0d input vc %0d but reserved output vc %0d",
                      gp, gv, va_gnt_out_vc[gp][gv]);

      end

    end
  endgenerate

endmodule
