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
//         port's arrival-cycle timing depends on it. There is no output VC
//         to choose: linnea_v2 section 4.4 matches input VC v to output VC
//         v, so the assignment is the index itself and the mock has no
//         decision left to model here. (It used to round-robin one, purely
//         to give the port's now-deleted `out_vc` register something to
//         capture.)
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
    parameter int NUM_VC = 4
) (
    input logic clk,
    input logic rst_n,

    // VA side
    input  logic [NUM_VC-1:0] va_req,
    output logic [NUM_VC-1:0] va_gnt,

    // SA side
    input  logic [NUM_VC-1:0] sa_req,
    output logic [NUM_VC-1:0] sa_gnt,
    output logic [NUM_VC-1:0] sa_pick,

    // Grant counters, read by the TB to confirm nothing was granted twice
    // or dropped.
    output int unsigned n_va_grants,
    output int unsigned n_sa_grants
);

  // VC index width (section 1 of linnea_v2): derived, so the VA sideband can
  // never be narrower than the index it carries. Declared in the body because
  // the port list above already refers to it.
  localparam int VC_W = (NUM_VC > 1) ? $clog2(NUM_VC) : 1;

  // Stage-1 pointer across this port's VCs.
  logic [VC_W-1:0] rr_sa;

  int unsigned va_cnt;
  int unsigned sa_cnt;

  //---------------------------------------------------------------------------
  // VA: accept combinationally in the request cycle.
  //
  // va_req is a function of registers only (head_valid, assignment_valid,
  // arrive, and data_out through route_compute), so this combinationally
  // driven grant introduces no loop.
  //
  // Nothing else is driven: the downstream VC is the requester's own index
  // (linnea_v2 section 4.4), so there is no sideband left to carry.
  //---------------------------------------------------------------------------
  assign va_gnt = va_req;

  //---------------------------------------------------------------------------
  // SA: round-robin pick, granted immediately.
  //
  // The scan starts AT rr_sa and wraps, so for NUM_VC = 2 it is bit-for-bit
  // the old `sa_req[rr_sa] ? rr_sa : ~rr_sa` form. That form only ever
  // considered two VCs -- a single rr_sa bit and its complement -- which
  // would silently ignore VC2 and VC3 now that the port has four.
  //---------------------------------------------------------------------------
  always_comb begin : sa_stage1
    logic [VC_W-1:0] idx;

    sa_pick = '0;

    for (int i = 0; i < NUM_VC; i++) begin
      idx = VC_W'((int'(rr_sa) + i) % NUM_VC);
      // First requester found, wrapping forward from rr_sa.
      if (((|sa_pick) == 1'b0) && sa_req[idx]) sa_pick[idx] = 1'b1;
    end

    sa_gnt = sa_pick;
  end

  //---------------------------------------------------------------------------
  // State updates
  //---------------------------------------------------------------------------
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      rr_sa   <= '0;
      va_cnt  <= '0;
      sa_cnt  <= '0;
    end
    else begin
      // Stage-1 pointer rotates only when the picked VC actually won --
      // here grant always follows pick, so "won" means "was picked with a
      // request outstanding". Wrapping forward is the same move as the old
      // `~rr_sa` when there are two VCs.
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
