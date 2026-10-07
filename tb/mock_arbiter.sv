// mock_arbiter.sv
//
// Testbench support: stands in for the real `arbiter` when a single input
// port is under test (the arbiter itself is build step 3, and even once it
// exists a port-level bench needs grant timing it controls to the cycle).
//
// It models exactly the two behaviours an input port depends on:
//
//   VA  - combinational accept in the request cycle. The spec locks this
//         ("the allocator is combinational in the request cycle; the input
//         port latches assignment_valid at the clock edge"), and the input
//         port's arrival-cycle timing depends on it. The output VC is chosen
//         round-robin PER INPUT VC so `out_vc` capture gets exercised with
//         more than one value rather than a constant zero.
//
//   SA  - one round-robin pick across this port's requesting VCs, granted
//         immediately. Stage 2 of the real arbiter is collapsed because here
//         it has a single client, but the property the input port cares
//         about is preserved: at most one VC switched per port per cycle,
//         and sa_gnt always implies sa_pick.
//
// Grant counters are exported so a test can assert that nothing was granted
// twice, twice over, or dropped.

module mock_arbiter #(
    parameter int NUM_VC = 2
) (
    input logic clk,
    input logic rst_n,

    // VA side
    input  logic [NUM_VC-1:0] va_req,
    output logic [NUM_VC-1:0] va_gnt,
    output logic [1:0]        va_gnt_out_vc [NUM_VC],

    // SA side
    input  logic [NUM_VC-1:0] sa_req,
    output logic [NUM_VC-1:0] sa_gnt,
    output logic [NUM_VC-1:0] sa_pick,

    // Grant counters, read by the TB to confirm nothing was granted twice
    // or dropped.
    output int unsigned n_va_grants,
    output int unsigned n_sa_grants
);

  // Per-input-VC round-robin pointer over the output VCs.
  logic [1:0] va_rr [NUM_VC];

  // Stage-1 pointer across this port's VCs.
  logic rr_sa;

  int unsigned va_cnt;
  int unsigned sa_cnt;

  //---------------------------------------------------------------------------
  // VA: accept combinationally in the request cycle.
  //
  // va_req is a function of registers only (head_valid, assignment_valid,
  // arrive, and data_out through route_compute), so this combinationally
  // driven grant introduces no loop.
  //---------------------------------------------------------------------------
  always_comb begin
    va_gnt = va_req;
    for (int v = 0; v < NUM_VC; v++) begin
      va_gnt_out_vc[v] = va_rr[v];
    end
  end

  //---------------------------------------------------------------------------
  // SA: round-robin pick, granted immediately.
  //
  // `~rr_sa` is the "other" VC for NUM_VC=2 (rr_sa is a single bit).
  //---------------------------------------------------------------------------
  always_comb begin
    sa_pick = '0;

    if (sa_req[rr_sa]) begin
      sa_pick[rr_sa] = 1'b1;
    end
    else if (sa_req[~rr_sa]) begin
      sa_pick[~rr_sa] = 1'b1;
    end

    sa_gnt = sa_pick;
  end

  //---------------------------------------------------------------------------
  // State updates
  //---------------------------------------------------------------------------
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      rr_sa   <= 1'b0;
      va_cnt  <= '0;
      sa_cnt  <= '0;
      for (int v = 0; v < NUM_VC; v++) begin
        va_rr[v] <= 2'd0;
      end
    end
    else begin
      // Rotate the output-VC choice after every grant to this input VC,
      // wrapping at NUM_VC. Without the wrap a round-robin pointer on 2 bits
      // walks 0,1,2,3 and hands out out_vc=2 -- an index that does not exist
      // for NUM_VC=2, which would be stored by the input port and then used
      // as a credit-mask index.
      for (int v = 0; v < NUM_VC; v++) begin
        if (va_gnt[v]) begin
          va_rr[v] <= (va_rr[v] == 2'(NUM_VC - 1)) ? 2'd0 : (va_rr[v] + 2'd1);
        end
      end

      // Stage-1 pointer rotates only when the picked VC actually won --
      // here grant always follows pick, so "won" means "was picked with a
      // request outstanding".
      if (|sa_gnt) begin
        rr_sa <= ~rr_sa;
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
