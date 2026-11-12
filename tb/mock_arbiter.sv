// Provides combinational VA grants and single-input round-robin SA for tests.

module mock_arbiter #(
    parameter int NUM_VC = 4
) (
    input logic clk,
    input logic rst_n,

    input  logic [NUM_VC-1:0] va_req,
    output logic [NUM_VC-1:0] va_gnt,

    input  logic [NUM_VC-1:0] sa_req,
    output logic [NUM_VC-1:0] sa_gnt,
    output logic [NUM_VC-1:0] sa_pick,

    output int unsigned n_va_grants,
    output int unsigned n_sa_grants
);

  localparam int VC_W = (NUM_VC > 1) ? $clog2(NUM_VC) : 1;

  logic [VC_W-1:0] rr_sa;

  int unsigned va_cnt;
  int unsigned sa_cnt;

  assign va_gnt = va_req;

  always_comb begin : sa_stage1
    logic [VC_W-1:0] idx;

    sa_pick = '0;

    for (int i = 0; i < NUM_VC; i++) begin
      idx = VC_W'((int'(rr_sa) + i) % NUM_VC);

      if (((|sa_pick) == 1'b0) && sa_req[idx]) sa_pick[idx] = 1'b1;
    end

    sa_gnt = sa_pick;
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      rr_sa   <= '0;
      va_cnt  <= '0;
      sa_cnt  <= '0;
    end
    else begin

      if (|sa_gnt) begin
        rr_sa <= (rr_sa == VC_W'(NUM_VC - 1)) ? '0 : (rr_sa + VC_W'(1));
      end

      for (int v = 0; v < NUM_VC; v++) begin
        if (va_gnt[v]) va_cnt <= va_cnt + 1;
        if (sa_gnt[v]) sa_cnt <= sa_cnt + 1;
      end
    end
  end

  assign n_va_grants = va_cnt;
  assign n_sa_grants = sa_cnt;

endmodule
