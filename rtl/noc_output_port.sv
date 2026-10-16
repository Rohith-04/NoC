`timescale 1ns / 1ps

// noc_output_port.sv
//
// One per output port. Merges the lookahead route into the header and then
// registers the flit onto the link. This register is the LT (link transmit)
// boundary of the router -- everything before it is inside the router's
// timing, everything after it is the physical link.
//
//
// The header merge (section 4.5, seam 10)
// ---------------------------------------
//   merged = xbar_out_data
//   if (merged[0])  merged[13:10] = xbar_out_route_next
//
// The crossbar carries the payload as it sat in the sender's FIFO, with a
// STALE route field: that field was written by the *previous* hop's route
// compute and describes where to go from there, not from here. The
// lookahead route computed by THIS router for the NEXT one is a separate
// 4-bit signal off `st_route_next`, and it is spliced in as the flit
// crosses.
//
// `merged[0]` is the flit type's bit 0, i.e. `is_head`:
//
//     00 BODY   01 HEAD   10 TAIL   11 HEAD_TAIL
//
// so the test selects HEAD and HEAD_TAIL and skips BODY and TAIL, whose
// [13:10] are payload bits that must not be disturbed. This is the single
// most encoding-coupled line in the whole router -- change the type
// encoding and the merge silently starts rewriting payload. It is checked
// directly by the assertions below rather than left to be noticed later.
//
// Only [13:10] is written. [3:2] is the KIND field (it was VC_ID when D3 was
// written) and is deliberately ignored: the sideband `vc_id` is the
// authoritative VC, KIND is set once by the source NI and has nothing to do
// with the hop being taken, and rewriting it here would look correct in a
// single-router test and corrupt every packet in a chain.
//
//
// Why the merge is here and not in the crossbar
// ---------------------------------------------
// The crossbar is stateless and knows nothing about flit formats; putting a
// format-dependent field splice in it would force every crossbar port to
// carry route_next for a path that only HEAD flits use. The merge belongs
// with the one register that is about to hold the flit, and it has to
// complete before that register loads -- which is exactly where this module
// puts it.
//
//
// The credit/latency consequence of this register
// -----------------------------------------------
// section 6: the register is one cycle of the credit loop. If the physical
// link needs more pipelining it is added *after* this point and the loop
// grows by that many cycles; nothing inside the router changes.
//
//
// Dependencies
// ------------
//   None inside this module; it is a leaf. Driven by the crossbar and the
//   arbiter, drives the downstream router's (or the NI's) input port.
//

module noc_output_port #(
    // Flit width. The header merge writes only [13:10], so the width shows
    // up here purely as the payload path -- but the "nothing outside
    // [13:10] moved" assertion below is expressed in terms of this, because
    // a 32-bit mask silently stops covering the upper bits once the word
    // grows past 32.
    parameter int FLIT_W = 40,
    parameter int NUM_VC = 4   // only used to size the VC sideband below
) (
    input logic clk,
    input logic rst_n,  // synchronous, active low -- matches fifo.sv

    // ------------------------------------------------------------------
    // From the crossbar. `xbar_out_data` is only valid when `st_valid` is
    // high -- the crossbar forces it to zero otherwise -- but the merge is
    // applied unconditionally and the register gates it with `st_valid`, so
    // the two cases cannot differ.
    // ------------------------------------------------------------------
    input  logic [FLIT_W-1:0] xbar_out_data,
    input  logic [3:0]  xbar_out_route_next,

    // ------------------------------------------------------------------
    // Control from the arbiter: whether this output carries a flit this
    // cycle, and which downstream VC it belongs to (the `vc_id` sideband
    // the next router's input port demuxes its FIFOs with).
    // ------------------------------------------------------------------
    input  logic        st_valid,
    input  logic [VC_W-1:0]  st_out_vc,

    // ------------------------------------------------------------------
    // The link itself, registered. One cycle of the credit loop lives in
    // this module (section 6); see the header comment.
    // ------------------------------------------------------------------
    output logic [FLIT_W-1:0] flit_data,
    output logic        flit_valid,
    output logic [VC_W-1:0]  vc_id
);

  // VC index width (section 1 of linnea_v2): enough bits to name any of
  // NUM_VC virtual channels. Derived here rather than passed in, so a
  // -GNUM_VC sweep cannot leave the sideband narrower than the index it
  // carries.
  localparam int VC_W = (NUM_VC > 1) ? $clog2(NUM_VC) : 1;


  //===========================================================================
  // Header merge -- combinational, feeds only the register below
  //
  // Written as "default to the incoming payload, then overlay" rather than
  // as a case statement so that the untouched bits are obviously the
  // payload bits: a case statement would have to list every flit type and
  // would silently drop any type that is added later.
  //===========================================================================

  logic [FLIT_W-1:0] merged;

  // One-hot mask for the ROUTE field, [13:10]. Sized to the flit so that
  // `~ROUTE_BITS` covers every bit *except* the route for whatever FLIT_W
  // is -- a 32-bit literal would be zero-extended into a 40-bit compare and
  // quietly stop checking the upper eight bits.
  localparam logic [FLIT_W-1:0] ROUTE_BITS = 'h3C00;

  always_comb begin : header_merge
    // Default: the payload exactly as it arrived from the crossbar. Any
    // bit not explicitly overwritten below survives unchanged, which is
    // what makes BODY/TAIL payloads safe by construction.
    merged = xbar_out_data;

    // is_head == type[0] == HEAD (01) or HEAD_TAIL (11).
    //
    // The condition is written as a test of the *low type bit* rather than
    // as `type == HEAD || type == HEAD_TAIL`, because that is precisely the
    // definition the rest of the design uses (section 2, "is_head =
    // type[0]"), and having one spelling here means an encoding change has
    // exactly one place to break and one assertion to trip.
    if (xbar_out_data[0]) begin
      // Only the route field. [3:2] (KIND, set by the source NI) and [1:0] (type) are left
      // alone -- see assumption D3 in the header comment.
      merged[13:10] = xbar_out_route_next;
    end
  end


  //===========================================================================
  // Link register -- the LT boundary
  //
  // `flit_valid` is registered from `st_valid`, so a grant in cycle g puts
  // the flit on the wire in g+1 (section 3's timeline: grant in c2, header
  // on the output link in c3).
  //
  // Reset clears `flit_valid` and, for determinism on a waveform, the data
  // and sideband too -- an unreset link register would show its previous
  // value across a reset and look like a flit being held forever.
  //===========================================================================

  always_ff @(posedge clk) begin : link_reg
    if (!rst_n) begin
      flit_data  <= '0;
      flit_valid <= 1'b0;
      vc_id      <= '0;
    end else begin
      // Gating the payload with st_valid costs nothing (the crossbar
      // already drives zero when idle) and guarantees the data and the
      // valid bit cannot disagree about whether a flit was presented.
      flit_data  <= st_valid ? merged : '0;
      flit_valid <= st_valid;
      vc_id      <= st_valid ? st_out_vc : '0;
    end
  end


  //===========================================================================
  // Assertions
  //
  // The merge is pure combinational logic on a format field, so it is
  // checked as a combinational property -- checking it one cycle later, at
  // the register, would confirm the register and not the splice.
  //===========================================================================

  // -- The lookahead route must be a legal direction -----------------------
  // A 2-bit type field has no illegal values, so asserting "the encoding is
  // valid" would assert nothing. The thing that *can* be corrupted and still
  // reach the next router is route_next, so that is what gets checked: one
  // of the five one-hot direction codes (section 2), and only while a flit
  // is actually crossing -- an idle port's route_next is a don't-care by the
  // spec's own definition ("outputs are only meaningful while a HEAD is on
  // data_out").
  assert property (@(posedge clk) disable iff (!rst_n)
                   (st_valid && xbar_out_data[0]) |->
                     ((xbar_out_route_next == 4'b0000) || (xbar_out_route_next == 4'b0001) ||
                      (xbar_out_route_next == 4'b0010) || (xbar_out_route_next == 4'b0100) ||
                      (xbar_out_route_next == 4'b1000)))
    else $error("noc_output_port: route_next %b is not a legal direction",
                xbar_out_route_next);

  // -- A head's route field is replaced by the lookahead -------------------
  assert property (@(posedge clk) disable iff (!rst_n)
                   (st_valid && xbar_out_data[0]) |->
                     (merged[13:10] == xbar_out_route_next))
    else $error("noc_output_port: HEAD route not updated (have %h, want %h)",
                merged[13:10], xbar_out_route_next);

  // -- A non-head's route field is payload and must survive ----------------
  // The mirror image of the check above. Without it, a merge condition that
  // accidentally became "always" would still pass the HEAD check and quietly
  // corrupt every BODY and TAIL flit.
  assert property (@(posedge clk) disable iff (!rst_n)
                   (st_valid && !xbar_out_data[0]) |->
                     (merged[13:10] == xbar_out_data[13:10]))
    else $error("noc_output_port: non-HEAD payload [13:10] was overwritten");

  // -- The KIND field is never touched (D3, renamed from VC_ID) -----------------------
  // Ungated by st_valid: the splice must not depend on whether a flit is
  // actually present, and this is the cheapest way to say so.
  assert property (@(posedge clk) disable iff (!rst_n)
                   merged[3:2] == xbar_out_data[3:2])
    else $error("noc_output_port: KIND field [3:2] was modified by the merge");

  // -- Everything outside [13:10] survives the merge -----------------------
  // The complement of the two checks above, stated once for the whole word
  // so that a future edit to some other field is caught here too.
  assert property (@(posedge clk) disable iff (!rst_n)
                   (merged & ~ROUTE_BITS) == (xbar_out_data & ~ROUTE_BITS))
    else $error("noc_output_port: merge modified bits outside [13:10]");

  // -- The register is exactly one cycle behind the grant ------------------
  // section 3: grant in c2, header on the wire in c3.
  //
  // Written as `|=>` (the non-overlapped implication, "in the cycle after")
  // rather than the equivalent `|-> ##1`: the latter is not accepted by this
  // toolchain, and `|=>` is the more direct statement of the intent anyway.
  // The reset exclusion matters here -- without `disable iff` the first
  // sample after reset release would compare against an undefined previous
  // cycle and fail spuriously.
  assert property (@(posedge clk) disable iff (!rst_n)
                   st_valid |=> flit_valid)
    else $error("noc_output_port: flit_valid did not follow a grant");

  assert property (@(posedge clk) disable iff (!rst_n)
                   !st_valid |=> !flit_valid)
    else $error("noc_output_port: flit_valid asserted without a grant");

  // -- The sideband travels with its flit ----------------------------------
  // A `vc_id` that disagreed with the flit beside it would make the next
  // router buffer into the wrong FIFO while the credit is decremented in
  // the right one -- an error that only shows up many cycles later as a
  // mis-sequenced packet.
  assert property (@(posedge clk) disable iff (!rst_n)
                   st_valid |=> (flit_valid && (vc_id == $past(st_out_vc))))
    else $error("noc_output_port: vc_id sideband did not travel with its flit");

endmodule
