`timescale 1ns / 1ps

// arbiter.sv
//
// VA + SA + credit bookkeeping for one router. Owns everything that is
// *shared* between input ports; owns nothing that is *per-VC assignment*
// state (that lives in the input port -- this block never knows which
// packet an input port is holding, only which output it is asking for).
//
//
// Structure
// ---------
//   VA   VC-matched (linnea_v2 section 4.4). One row per (output port,
//        output VC); a row's candidates are the input ports requesting that
//        port *at that same VC index*, so input VC and output VC are never
//        allowed to disagree. No column stage is needed -- a requester maps
//        to exactly one row -- and the grant is not registered (section 1.1
//        of the spec), so the input port latches `out_port` and its
//        `assignment_valid` flag at the same edge the arbiter latches
//        `alloc_busy`. There is no downstream-VC register on that edge any
//        more: matched VCs make it a copy of the index that fetched it.
//
//   SA   two stages. Stage 1 picks one VC *within* an input port, masked by
//        the credit count for that VC's target output. Stage 2 picks one
//        input port *per output*. Splitting it this way is what makes the
//        crossbar selection a single one-hot vector per output.
//
//   CRED per (output, output VC) counter. Init = the number of free slots
//        the *downstream* consumer has, which is why DIR_CREDITS tracks the
//        FIFO depth used by noc_input_port while LOCAL_CREDITS tracks the
//        NI receive buffer. Decrement on switch, increment on return, and a
//        simultaneous +1/-1 nets to zero (section 1.1).
//
// The two combinational halves do not read each other, deliberately: VA is
// not credit-gated (assumption D2) and SA does not know about VA's
// reservation. That independence is what lets them be verified separately.
//
//
// Port index encoding (section 2)
// -------------------------------
//   LOCAL 0   NORTH 1   EAST 2   WEST 3   SOUTH 4
//
// The 4-bit direction codes that arrive on `*_req_out_port` are one-hot
// (`0000 LOCAL, 0001 NORTH, 0010 EAST, 0100 WEST, 1000 SOUTH`) and are
// converted to the index above by `dir_to_idx` as soon as they enter this
// module. Everything internal -- row indices, `xbar_sel`, the pointers --
// is an index. Keeping exactly one representation per boundary is what
// stops direction/index mix-ups from silently selecting the wrong port.
//
//
// Dependencies
// ------------
//   None inside this module; it is a leaf. It reads per-port state from
//   noc_input_port and drives it back combinationally.
//

module arbiter #(
    parameter int NUM_PORTS     = 5,    // fixed by the 5x5 crossbar
    parameter int NUM_VC        = 4,    // default per linnea_v2 section 1
    parameter int LOCAL_IDX     = 0,    // index of the LOCAL port (section 2)
    parameter int DIR_CREDITS   = 4,    // neighbour input FIFO depth: init for
                                        // credit_count[o != LOCAL][*]
    parameter int LOCAL_CREDITS = 4     // NI receive buffer depth per VC: init
                                        // for credit_count[LOCAL][*]
) (
    input logic clk,
    input logic rst_n,  // synchronous, active low -- matches fifo.sv

    // ------------------------------------------------------------------
    // VA -- combinational in the request cycle (no grant register)
    // ------------------------------------------------------------------
    input  logic [NUM_PORTS-1:0][NUM_VC-1:0]       va_req,
    input  logic [NUM_PORTS-1:0][NUM_VC-1:0][3:0]  va_req_out_port,
    input  logic [NUM_PORTS-1:0][NUM_VC-1:0]       va_req_single,
    output logic [NUM_PORTS-1:0][NUM_VC-1:0]       va_gnt,

    // ------------------------------------------------------------------
    // SA
    // ------------------------------------------------------------------
    input  logic [NUM_PORTS-1:0][NUM_VC-1:0]       sa_req,
    input  logic [NUM_PORTS-1:0][NUM_VC-1:0][3:0]  sa_req_out_port,
    input  logic [NUM_PORTS-1:0][NUM_VC-1:0][VC_W-1:0]  sa_req_out_vc,
    input  logic [NUM_PORTS-1:0][NUM_VC-1:0]       sa_req_last,
    output logic [NUM_PORTS-1:0][NUM_VC-1:0]       sa_gnt,
    output logic [NUM_PORTS-1:0][NUM_VC-1:0]       sa_pick,   // stage-1 pick

    // ------------------------------------------------------------------
    // Switch result -> crossbar and output port
    // ------------------------------------------------------------------
    output logic [NUM_PORTS-1:0][2:0]  xbar_sel,   // input port index, 0..4
    output logic [NUM_PORTS-1:0]       st_valid,
    output logic [NUM_PORTS-1:0][VC_W-1:0]  st_out_vc,  // downstream VC sideband

    // ------------------------------------------------------------------
    // Credits returned by the downstream router / NI (assumption D1: a
    // per-VC vector, not one pulse plus a tag -- two VCs can fetch in the
    // same cycle, so a single tag cannot carry both)
    // ------------------------------------------------------------------
    input  logic [NUM_PORTS-1:0][NUM_VC-1:0] ds_credit_valid
);

  // =========================================================================
  // Local parameters
  // =========================================================================

  // Widths of the round-robin pointer/chooser spaces.
  //
  // OIDX_W is the port space, and rr_pick_port returns NUM_PORTS from it as
  // its "nobody" sentinel -- so the width has to hold one past the last port
  // index too. That holds because NUM_PORTS is locked at 5 (clog2(5) = 3,
  // which carries 0..7); it is not a property the formula guarantees in
  // general, so if ports are ever added this line moves with them.
  localparam int OIDX_W = (NUM_PORTS > 1) ? $clog2(NUM_PORTS) : 1;   // 3 for 5
  localparam int VC_W = (NUM_VC > 1) ? $clog2(NUM_VC) : 1;         // 1 for 2, 2 for 4, 3 for 8

  // Credit counters must hold 0..max(DIR_CREDITS, LOCAL_CREDITS).
  localparam int CRED_MAX = (DIR_CREDITS > LOCAL_CREDITS) ? DIR_CREDITS : LOCAL_CREDITS;
  localparam int CRED_W   = $clog2(CRED_MAX + 1);                    // 4 for 8

  // Direction codes (section 2). Y grows downward, so SOUTH is the
  // increasing-Y direction.
  localparam logic [3:0] DIR_LOCAL = 4'b0000;
  localparam logic [3:0] DIR_NORTH = 4'b0001;
  localparam logic [3:0] DIR_EAST  = 4'b0010;
  localparam logic [3:0] DIR_WEST  = 4'b0100;
  localparam logic [3:0] DIR_SOUTH = 4'b1000;

  // =========================================================================
  // Helper functions
  // =========================================================================

  // -------------------------------------------------------------------
  // dir_to_idx: one-hot direction -> port index.
  //
  // 0000->0, 0001->1, 0010->2, 0100->3, 1000->4, i.e. "the set-bit position
  // plus one, with all-zero mapping to LOCAL" (section 2). An illegal code
  // maps to LOCAL as a defined fallback; a separate assertion catches the
  // code being illegal in the first place, so this fallback can never mask
  // a real bug by quietly routing to the wrong port.
  // -------------------------------------------------------------------
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

  // -------------------------------------------------------------------
  // rr_pick_vc / rr_pick_port
  //
  // Round-robin over a mask, starting the search AT `start` and wrapping.
  // Returns the selected index, or the mask width itself ("nobody") when
  // the mask is empty. Returning a value outside the legal range rather
  // than a sentinel of 0 keeps "no winner" distinguishable from "port 0
  // won", which matters because stage 2 must not grant anything when there
  // are no requesters.
  //
  // The two copies differ only in width. Small per-width functions beat one
  // function taking an over-wide mask: the caller would otherwise have to
  // zero-extend and re-truncate at every call site, which is exactly where
  // index bugs hide. (There was a third, wider copy over the flattened
  // (port, VC) requester space; VA no longer needs it, since a row's
  // candidates are ports of one fixed VC.)
  // -------------------------------------------------------------------
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

  // -------------------------------------------------------------------
  // xy_legal: the 16 legal (input port, output port) pairs of section 2.
  //
  //   LOCAL -> N, E, W, S
  //   N     -> S, LOCAL        S -> N, LOCAL
  //   E     -> W, N, S, LOCAL  W -> E, N, S, LOCAL
  //
  // XY dimension-order routing fixes this table independently of the
  // destination: a packet arriving from the east has already had its X
  // corrected, so it can only continue west, turn north/south, or
  // terminate. Anything outside the table means a packet would turn back
  // the way it came -- a routing deadlock waiting to happen -- so it is
  // asserted rather than tolerated.
  // -------------------------------------------------------------------
  function automatic bit xy_legal(input int p, input int o);
    case (p)
      0: xy_legal = (o == 1) || (o == 2) || (o == 3) || (o == 4);  // LOCAL
      1: xy_legal = (o == 4) || (o == 0);                           // NORTH
      2: xy_legal = (o == 3) || (o == 1) || (o == 4) || (o == 0);   // EAST
      3: xy_legal = (o == 2) || (o == 1) || (o == 4) || (o == 0);   // WEST
      4: xy_legal = (o == 1) || (o == 0);                           // SOUTH
      default: xy_legal = 1'b0;
    endcase
  endfunction

  // Init value for one credit counter.
  function automatic logic [CRED_W-1:0] credit_init(input int o);
    credit_init = (o == LOCAL_IDX) ? CRED_W'(LOCAL_CREDITS) : CRED_W'(DIR_CREDITS);
  endfunction

  // Depth a counter may hold, as a function of its output port.
  function automatic logic [CRED_W-1:0] credit_max(input int o);
    credit_max = (o == LOCAL_IDX) ? CRED_W'(LOCAL_CREDITS) : CRED_W'(DIR_CREDITS);
  endfunction

  // =========================================================================
  // State (section 4.3 "Internal state")
  // =========================================================================

  // A row (output port o, output VC k) is reserved once VA grants it and
  // stays reserved until the LAST flit of that packet wins SA -- so no
  // second packet can be handed the same downstream VC while the first is
  // still draining into it.
  logic [NUM_PORTS-1:0][NUM_VC-1:0] alloc_busy;

  // Free slots downstream. The whole credit loop (section 6) exists to keep
  // this between 0 and the downstream depth; it is never allowed to leave
  // that range, asserted at the bottom.
  logic [NUM_PORTS-1:0][NUM_VC-1:0][CRED_W-1:0] credit_count;

  // Round-robin pointers.
  //
  //   rr_va[o][k]  which input port row (o, k) considers first. The row is
  //                pinned to a single VC already -- its own k, because a
  //                VC-matched allocator only ever asks input VC k for output
  //                VC k -- so the only thing left to arbitrate between is
  //                the NUM_PORTS ports. That is what keeps this pointer at
  //                OIDX_W rather than the flattened (port, VC) width it
  //                needed when one row could see every VC at once.
  //   rr1[p]       which VC of input port p stage 1 considers first.
  //   rr2[o]       which input port output o considers first in stage 2.
  logic [OIDX_W-1:0] rr_va [NUM_PORTS][NUM_VC];
  logic [VC_W-1:0] rr1 [NUM_PORTS];
  logic [OIDX_W-1:0] rr2 [NUM_PORTS];

  // =========================================================================
  // VA -- row stage (linnea_v2 section 4.4, VC-matched)
  //
  // For every (output port o, output VC k) row, the candidates are the input
  // ports p that satisfy BOTH of:
  //
  //     va_req[p][k]                                   -- asking at all
  //     idx(va_req_out_port[p][k]) == o                -- asking for THIS port
  //
  // Note what is absent: there is no scan over an input VC v. A row's output
  // VC and a candidate's input VC are the SAME index k, which is the whole
  // content of "VC-matched". The input VC therefore appears in the row index
  // rather than in the candidate list, and the candidate set collapses from
  // NUM_PORTS*NUM_VC requesters to at most NUM_PORTS ports.
  //
  // The row is also disabled outright when it is already reserved, and the
  // two HEAD_TAIL tiers apply as before: single-flit requesters first, then
  // round-robin within that tier. The single tier is what lets a one-flit
  // packet preempt the queue -- it cannot deadlock against a long packet,
  // because the long packet's row is either free (so it competes normally)
  // or reserved (so the row is disabled for everyone, tier included, and the
  // single cannot starve it either).
  //
  // Why the column stage is gone
  // ----------------------------
  // The old separable allocator let a requester win several rows at once,
  // because it was scanned into every row asking for its output port, and
  // then threw all but one away. Here a requester (p, k) is eligible for row
  // (o, k) only where o is the single port va_req_out_port[p][k] names -- so
  // it appears in exactly one row and can win at most one. There is nothing
  // left to arbitrate away, and the dropped-row waste the old column stage
  // documented goes with it. va_kept at the bottom asserts this rather than
  // leaving it as a claim in a comment.
  // =========================================================================

  logic [OIDX_W-1:0] row_pidx [NUM_PORTS][NUM_VC];  // winning input port, or NUM_PORTS
  logic              row_val  [NUM_PORTS][NUM_VC];  // row produced a winner

  always_comb begin : va_rows
    for (int o = 0; o < NUM_PORTS; o++) begin
      for (int k = 0; k < NUM_VC; k++) begin

        // Declared inside the innermost scope rather than at the top of the
        // block: each is written before it is read on every path, which is
        // what keeps them from being inferred as latches.
        logic [NUM_PORTS-1:0] mask;    // candidate input ports for this row
        logic [NUM_PORTS-1:0] single;  // the HEAD_TAIL tier within them
        int unsigned          win;

        mask   = '0;
        single = '0;
        win    = NUM_PORTS;   // rr_pick_port's "nobody" sentinel

        // The candidate scan runs unconditionally so that the row's
        // reservation status sits on the eligibility test rather than
        // wrapped around the loop. (Putting the test around it instead
        // leaves the temporaries unassigned on the reserved path, which the
        // tool correctly reads as a latch.)
        for (int p = 0; p < NUM_PORTS; p++) begin
          if (!alloc_busy[o][k] && va_req[p][k] &&
              (dir_to_idx(va_req_out_port[p][k]) == 3'(o))) begin
            mask[p] = 1'b1;
            if (va_req_single[p][k]) single[p] = 1'b1;
          end
        end

        // --- tiering: prefer single-flit, else everyone ---
        // When the row was reserved the mask above is already empty, so this
        // cannot resurrect it.
        if (|single) mask = single;

        win         = rr_pick_port(mask, int'(rr_va[o][k]));
        row_pidx[o][k] = OIDX_W'(win);
        row_val[o][k]  = (win != NUM_PORTS);

      end
    end
  end

  // =========================================================================
  // VA -- final grants
  //
  // One row produced at most one winner (the row stage above), and a
  // requester can only have appeared in its own row, so every row that found
  // a candidate is simply granted. There is no second arbitration stage and
  // no row to drop.
  //
  // va_gnt_out_vc is driven as k, the row's own index -- which by VC matching
  // is also the input VC of the requester that won it.
  //
  // It is deliberately NOT a module output any more (linnea_v2 section 4.4).
  // Because the two indices can no longer disagree, the sideband carried no
  // information across the module boundary: the input port's `out_vc` register
  // and the two wires carrying this through router_top existed only to
  // reproduce a value the reader already knew. They are gone.
  //
  // The signal itself is kept, internally, because section 4.5 asks for
  // `granted output VC == input VC index` to be ASSERTED, and that property
  // has no other statement: every downstream user of it now derives the VC
  // from the index it is already holding. Dropping the signal entirely would
  // have satisfied 4.4 while quietly deleting 4.5. It feeds assertions only
  // and folds away when they are compiled out.
  // =========================================================================

  logic [NUM_PORTS-1:0][NUM_VC-1:0][VC_W-1:0] va_gnt_out_vc;

  always_comb begin : va_grants
    va_gnt        = '0;
    va_gnt_out_vc = '0;

    for (int o = 0; o < NUM_PORTS; o++) begin
      for (int k = 0; k < NUM_VC; k++) begin
        if (row_val[o][k]) begin
          va_gnt[row_pidx[o][k]][k] = 1'b1;
          va_gnt_out_vc[row_pidx[o][k]][k] = VC_W'(k);
        end
      end
    end
  end

  // =========================================================================
  // VA -- rows won per requester
  //
  // A count, per (input port, VC), of how many rows that requester won this
  // cycle. It now always reads 0 or 1: with the candidate list pinned to the
  // requester's own VC and its one target port, (p, k) is eligible for
  // exactly one row, and that is precisely why the column stage could be
  // deleted. Keeping the count as a live assertion rather than a comment
  // means a future change that widens the candidate scan -- for instance
  // scanning v again "for flexibility" -- fails here instead of silently
  // reintroducing interleaved packets on one downstream VC.
  //
  // Not synthesizable-significant: it feeds assertions only, and folds away
  // entirely when they are compiled out.
  // =========================================================================

  int unsigned va_kept [NUM_PORTS][NUM_VC];

  always_comb begin : va_kept_rows
    for (int p = 0; p < NUM_PORTS; p++) begin
      for (int v = 0; v < NUM_VC; v++) begin
        va_kept[p][v] = 0;
        for (int o = 0; o < NUM_PORTS; o++) begin
          if (row_val[o][v] && (row_pidx[o][v] == OIDX_W'(p))) va_kept[p][v]++;
        end
      end
    end
  end

  // =========================================================================
  // SA -- stage 1: pick one VC within an input port
  //
  //   elig[p][v] = sa_req[p][v] && credit_count[target][vc] != 0
  //
  // This is the only place credits gate anything. A VC with no downstream
  // credit still holds a valid VA reservation -- it simply waits here, which
  // is exactly what assumption D2 asks for: gating VA as well would let a
  // packet reserve a downstream VC it cannot use yet and block others for no
  // benefit, since the reservation has to survive the wait anyway.
  //
  // `s1_oport` is a port INDEX (the incoming `sa_req_out_port` is a
  // direction; the spec calls this signal s1_out). Converting here, once, is
  // what lets stage 2 compare it directly against an output loop index.
  // =========================================================================

  logic [NUM_PORTS-1:0]             s1_valid;
  logic [NUM_PORTS-1:0][VC_W-1:0] s1_idx;    // which VC was picked
  logic [NUM_PORTS-1:0][VC_W-1:0]        s1_vc;     // that VC's downstream VC
  logic [NUM_PORTS-1:0][2:0]        s1_oport;  // that VC's output port index
  logic [NUM_PORTS-1:0]             s1_last;   // picked VC says "last flit"

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
      // Clamp before use: indexing the fields with the "nobody" sentinel
      // would read one past the VC array. s1_valid keeps the clamped value
      // from being acted on.
      sel = (win != NUM_VC) ? win : 0;

      s1_valid[p] = (win != NUM_VC);
      s1_idx [p]  = VC_W'(sel);
      s1_vc  [p]  = sa_req_out_vc[p][sel];
      s1_oport[p] = dir_to_idx(sa_req_out_port[p][sel]);
      s1_last[p]  = s1_valid[p] && sa_req_last[p][sel];

      // sa_pick is stage 1 only -- one-hot per port regardless of whether
      // stage 2 later grants it. The input port uses it to qualify which
      // VC's flit is being presented; the crossbar independently picks the
      // winner via xbar_sel, so a pick without a grant is harmless (the
      // crossbar output is masked by st_valid) while a grant without a pick
      // would put an unqualified flit on the wire.
      sa_pick[p] = '0;
      if (win != NUM_VC) sa_pick[p][sel] = 1'b1;

    end
  end

  // =========================================================================
  // SA -- stage 2: pick one input port per output
  //
  //   req2[p] = s1_valid[p] && (s1_out[p] == o)
  //   w       = round-robin winner over req2 (pointer rr2[o])
  //
  // Because stage 1 already collapsed each input port to a single candidate,
  // this arbiter has at most NUM_PORTS requesters and its winner is directly
  // the crossbar select -- no second merge step.
  // =========================================================================

  logic [NUM_PORTS-1:0][2:0] s2_sel;
  logic [NUM_PORTS-1:0]      s2_any;

  always_comb begin : sa_stage2
    for (int o = 0; o < NUM_PORTS; o++) begin

      logic [NUM_PORTS-1:0] req2;
      logic [OIDX_W-1:0]    w;

      for (int p = 0; p < NUM_PORTS; p++) req2[p] = s1_valid[p] && (s1_oport[p] == 3'(o));

      s2_any[o] = |req2;
      // rr_pick_port returns NUM_PORTS ("nobody"), which still fits in
      // OIDX_W bits for the locked 5-port configuration -- so the sentinel
      // is representable and the cast is not aliasing it onto a legal index.
      w = OIDX_W'(rr_pick_port(req2, int'(rr2[o])));

      // With no requester, drive 0 rather than the sentinel: it keeps
      // xbar_sel a legal index at all times, and the value is meaningless
      // because st_valid masks it all the way to the link register.
      s2_sel[o] = s2_any[o] ? w : '0;

    end
  end

  assign xbar_sel = s2_sel;
  assign st_valid = s2_any;

  // =========================================================================
  // SA -- results
  //
  // `st_out_vc` is only meaningful when st_valid is high, so it is cleared
  // otherwise rather than left pointing at a VC nobody asked for: the credit
  // decrement below keys off st_valid, but leaving a stale value there would
  // let a future bug in that gating silently corrupt credit accounting.
  // =========================================================================

  always_comb begin : sa_results
    st_out_vc = '0;
    sa_gnt    = '0;

    for (int o = 0; o < NUM_PORTS; o++) begin
      if (st_valid[o]) begin
        // Walk rather than index directly so that every index in the
        // assignments below is the loop constant: it keeps the per-port
        // grant an ordinary bit set instead of a two-level dynamic select.
        for (int p = 0; p < NUM_PORTS; p++) begin
          if (OIDX_W'(p) == xbar_sel[o]) begin
            st_out_vc[o] = s1_vc[p];
            sa_gnt[p][s1_idx[p]] = 1'b1;
          end
        end
      end
    end
  end

  // =========================================================================
  // Credit direction flags
  //
  // Computed here rather than inline in the clocked block so that the
  // sequential process contains no blocking temporaries -- the counters are
  // the one piece of state where mixing blocking and non-blocking
  // assignment would be genuinely hard to reason about.
  // =========================================================================

  logic [NUM_PORTS-1:0][NUM_VC-1:0] cr_dec;  // a flit is switching out
  logic [NUM_PORTS-1:0][NUM_VC-1:0] cr_inc;  // downstream returned one

  // The exact condition under which a row is released, factored out so the
  // sequential block and the assertions talk about one shared signal. An
  // assertion that re-derives the condition it is meant to police can drift
  // away from the RTL and end up checking a rule nobody implements.
  logic [NUM_PORTS-1:0][NUM_VC-1:0] cr_release;

  always_comb begin : credit_flags
    for (int o = 0; o < NUM_PORTS; o++)
      for (int k = 0; k < NUM_VC; k++) begin
        cr_dec[o][k] = st_valid[o] && (st_out_vc[o] == VC_W'(k));
        // A row is released only when the LAST flit of the packet owning it
        // actually switches out of that row -- which is precisely cr_dec
        // plus "the winner's flit is a tail". Both are keyed off the same
        // cycle, so a row cannot be released on the strength of a tail that
        // is still waiting for a credit.
        cr_release[o][k] = st_valid[o] && s1_last[xbar_sel[o]] && (st_out_vc[o] == VC_W'(k));
      end
  end

  assign cr_inc = ds_credit_valid;

  // =========================================================================
  // Sequential state
  // =========================================================================

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

      // ---- credits ----------------------------------------------------
      // Decrement on switch-out, increment on return. Both true at once
      // means a flit left and a slot was freed in the same cycle -- the two
      // cancel, so neither branch fires and the value simply holds, which
      // is the "net to zero" of section 1.1 stated directly as control flow
      // rather than as arithmetic that could wrap.
      for (int o = 0; o < NUM_PORTS; o++)
        for (int k = 0; k < NUM_VC; k++) begin
          if (cr_dec[o][k] && !cr_inc[o][k]) credit_count[o][k] <= credit_count[o][k] - 1'b1;
          else if (!cr_dec[o][k] && cr_inc[o][k])
            credit_count[o][k] <= credit_count[o][k] + 1'b1;
        end

      // ---- SA stage-1 pointer ----------------------------------------
      // rr1 advances ONLY when the picked VC actually won stage 2. A VC
      // that keeps losing to a sibling and is rotated past anyway would
      // never be picked again once the sibling stopped requesting -- the
      // pointer would have walked away from the only pending requester.
      for (int p = 0; p < NUM_PORTS; p++)
        if (s1_valid[p] && st_valid[s1_oport[p]] && (xbar_sel[s1_oport[p]] == 3'(p)))
          rr1[p] <= VC_W'((int'(s1_idx[p]) + 1) % NUM_VC);

      // ---- SA stage-2 pointer ----------------------------------------
      for (int o = 0; o < NUM_PORTS; o++)
        if (st_valid[o]) rr2[o] <= OIDX_W'((int'(xbar_sel[o]) + 1) % NUM_PORTS);

      // ---- alloc_busy: release, then reserve --------------------------
      // Ordered release-then-reserve so that if both ever targeted the same
      // row the reservation would win (the row ends up owned by the new
      // packet, which is the safe answer). They cannot in fact co-occur:
      // VA only grants a row when !alloc_busy, and alloc_busy stays high
      // until the tail has switched out, so a row cannot be simultaneously
      // finishing and free. There is an assertion for exactly that.
      for (int o = 0; o < NUM_PORTS; o++)
        for (int k = 0; k < NUM_VC; k++)
          if (cr_release[o][k]) alloc_busy[o][k] <= 1'b0;

      for (int o = 0; o < NUM_PORTS; o++)
        for (int k = 0; k < NUM_VC; k++)
          if (row_val[o][k]) begin
            alloc_busy[o][k] <= 1'b1;
            // Advance past the port that won, in port space -- the row is
            // pinned to k, so the port index is all that needs rotating.
            rr_va[o][k] <= OIDX_W'((int'(row_pidx[o][k]) + 1) % NUM_PORTS);
          end

    end
  end

  // =========================================================================
  // Assertions
  //
  // SVA, unconditional -- the same tool parses these today and will parse
  // them again when the network moves to the commercial simulator.
  // =========================================================================

  generate
    for (genvar go = 0; go < NUM_PORTS; go++) begin : gen_cr_bound
      for (genvar gk = 0; gk < NUM_VC; gk++) begin : gen_cr_bound_vc

        // -- Credit bounds ------------------------------------------------
        // The credit loop (section 6) is sized so that correct traffic can
        // never violate this; leaving the range is therefore a logic bug
        // rather than a congestion condition, and is worth failing on.
        assert property (@(posedge clk) disable iff (!rst_n)
                         credit_count[go][gk] <= credit_max(go))
          else $error("arbiter: credit_count[%0d][%0d] out of range: %0d",
                      go, gk, credit_count[go][gk]);

        // A switch-out must have a credit to spend. This is the same
        // condition stage 1 masked on, so a failure means the mask and the
        // counter disagreed within one cycle.
        assert property (@(posedge clk) disable iff (!rst_n)
                         cr_dec[go][gk] |-> (credit_count[go][gk] != '0))
          else $error("arbiter: switched out on [%0d][%0d] with no credit", go, gk);

        // A credit return must not overflow the downstream depth -- an extra
        // return means a slot was freed twice.
        assert property (@(posedge clk) disable iff (!rst_n)
                         (cr_inc[go][gk] && !cr_dec[go][gk]) |->
                         (credit_count[go][gk] < credit_max(go)))
          else $error("arbiter: credit return overflow on [%0d][%0d]", go, gk);

        // -- alloc_busy stays consistent with the two events that move it --
        //
        // Release: a row can only fall out of the reserved state if it was
        // reserved in the first place. Checked in the same cycle, against
        // the same pre-edge value the release is acting on.
        assert property (@(posedge clk) disable iff (!rst_n)
                         cr_release[go][gk] |-> alloc_busy[go][gk])
          else $error("arbiter: row [%0d][%0d] released but was never reserved", go, gk);

        // Reserve and release in the same cycle would leave the row owned by
        // nobody and everybody at once: VA only grants a row when it is
        // free, and it stays reserved until the tail has switched out, so
        // the two cannot overlap.
        assert property (@(posedge clk) disable iff (!rst_n)
                         !(cr_release[go][gk] && row_val[go][gk]))
          else $error("arbiter: row [%0d][%0d] released and reserved in the same cycle",
                      go, gk);

      end
    end
  endgenerate

  generate
    for (genvar gp = 0; gp < NUM_PORTS; gp++) begin : gen_sa

      // -- SA stage 1: at most one pick per input port --------------------
      assert property (@(posedge clk) disable iff (!rst_n)
                       $countones(sa_pick[gp]) <= 1)
        else $error("arbiter: stage-1 pick not one-hot on port %0d: %b", gp, sa_pick[gp]);

      // -- SA stage 2: at most one grant per input port -------------------
      assert property (@(posedge clk) disable iff (!rst_n)
                       $countones(sa_gnt[gp]) <= 1)
        else $error("arbiter: multiple stage-2 grants on port %0d: %b", gp, sa_gnt[gp]);

      for (genvar gv = 0; gv < NUM_VC; gv++) begin : gen_sa_gnt

        // A grant implies the stage-1 pick for the same VC -- otherwise the
        // input port would be told to fetch a VC that was never selected.
        assert property (@(posedge clk) disable iff (!rst_n)
                         sa_gnt[gp][gv] |-> sa_pick[gp][gv])
          else $error("arbiter: grant without stage-1 pick on port %0d vc %0d", gp, gv);

        // -- Never grant a VC whose target had no credit (section 4.3) ----
        // The mask is applied in stage 1; this checks the grant end-to-end
        // so that a future change to either place cannot drift apart
        // silently.
        assert property (@(posedge clk) disable iff (!rst_n)
                         sa_gnt[gp][gv] |->
                         (credit_count[dir_to_idx(sa_req_out_port[gp][gv])]
                                           [sa_req_out_vc[gp][gv]] != '0))
          else $error("arbiter: granted port %0d vc %0d with zero credit", gp, gv);

        // -- XY legality (section 2: 16 legal pairs of 25) ----------------
        // Fires on the grant, which is the point at which an illegal turn
        // would actually reach the crossbar.
        assert property (@(posedge clk) disable iff (!rst_n)
                         sa_gnt[gp][gv] |->
                         xy_legal(int'(gp), int'(dir_to_idx(sa_req_out_port[gp][gv]))))
          else $error("arbiter: illegal XY pair in->out (%0d -> %0d) on port %0d vc %0d",
                      gp, dir_to_idx(sa_req_out_port[gp][gv]), gp, gv);

        // -- Direction codes must be one-hot-or-zero ----------------------
        // dir_to_idx falls back to LOCAL for an illegal code; this makes
        // sure that fallback is never what produced an answer.
        assert property (@(posedge clk) disable iff (!rst_n)
                         sa_req[gp][gv] |-> $onehot0(sa_req_out_port[gp][gv]))
          else $error("arbiter: sa_req_out_port not one-hot0 on port %0d vc %0d: %b",
                      gp, gv, sa_req_out_port[gp][gv]);

        assert property (@(posedge clk) disable iff (!rst_n)
                         va_req[gp][gv] |-> $onehot0(va_req_out_port[gp][gv]))
          else $error("arbiter: va_req_out_port not one-hot0 on port %0d vc %0d: %b",
                      gp, gv, va_req_out_port[gp][gv]);

      end

      // -- VA: a requester wins at most one row --------------------------
      //
      // The requester identity is the (input port, VC) pair and NOT the
      // port: two VCs of one input port are two independent requesters, each
      // with its own assignment_valid flag in the input port, and each
      // asks with its own va_req. A port-wide count would call a legal --
      // and necessary -- outcome a bug; the first run of T11's mixed-VC
      // random traffic tripped it for exactly that reason.
      //
      // Under a VC-matched allocator this is structural: (p, k) is eligible
      // only for row (idx(va_req_out_port[p][k]), k), one row by construction.
      // It is asserted anyway because it is the property the deleted column
      // stage used to enforce, and a change that scanned input VC v inside a
      // row indexed by k would break it before anything else noticed.
      //
      // The second property is structural rather than stateful: the row
      // stage only ever considers va_req candidates, so a grant always
      // answers a request. It is here because it is the only check on the
      // decode out of row_pidx, which a re-indexing refactor could get wrong
      // while leaving every other property in this file intact.
      for (genvar gv = 0; gv < NUM_VC; gv++) begin : gen_va_req

        assert property (@(posedge clk) disable iff (!rst_n)
                         va_kept[gp][gv] <= 1)
          else $error("arbiter: requester (port %0d, vc %0d) won %0d rows",
                      gp, gv, va_kept[gp][gv]);

        assert property (@(posedge clk) disable iff (!rst_n)
                         va_gnt[gp][gv] |-> va_req[gp][gv])
          else $error("arbiter: VA granted port %0d vc %0d without a request", gp, gv);

        // =========================================================================
        // The VC-matched property itself (linnea_v2 section 4.5)
        //
        // A grant on input VC gv reserves output VC exactly gv -- the row
        // that was handed out is the row the requester's own index names, so
        // the sideband cannot report a partner from a neighbouring row.
        //
        // Stated on the grant rather than on a later consumer because this
        // is the only point where the two indices are still separately
        // observable: past here the port either registers the signal once or
        // derives from it, and a mismatch introduced downstream surfaces as
        // a credit miscount rather than as the misallocation it really is.
        //
        // Non-vacuous precisely because of how the row stage above builds its
        // candidate list: the mask is indexed by the row's own k, so this can
        // only hold if nobody widened it back to an arbitrary input VC.
        // =========================================================================
        assert property (@(posedge clk) disable iff (!rst_n)
                         va_gnt[gp][gv] |-> (va_gnt_out_vc[gp][gv] == VC_W'(gv)))
          else $error("arbiter: VA granted port %0d input vc %0d but reserved output vc %0d",
                      gp, gv, va_gnt_out_vc[gp][gv]);

      end

    end
  endgenerate

endmodule
