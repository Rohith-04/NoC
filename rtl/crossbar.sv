`timescale 1ns / 1ps

// crossbar.sv
//
// Five independent 5:1 muxes plus a second, narrower set for the lookahead
// route. Nothing else: no state, no clocked process, no credit knowledge.
//
//
// Why this block exists as its own module
// ---------------------------------------
// The arbiter decides *who* switches; this decides *what they carry*. Those
// two decisions are made from different inputs -- the arbiter reads the
// request/credit state, the crossbar reads only the post-VC-mux flit data
// that each input port presents -- and keeping them apart is what lets the
// arbiter be verified without modelling 32-bit payloads (section 5, seam 6
// of the spec).
//
// Both muxes are selected by the same `xbar_sel`, which comes out of SA
// stage 2, so `data` and `route_next` can never disagree about which input
// port they came from. Splitting them into two arrays rather than packing
// them together is deliberate: they have different widths (32 and 4) and
// different consumers (noc_output_port's link register and its header
// merge), and a single packed field would force both to be sliced apart
// again at every use.
//
//
// The zero-when-idle rule (section 4.4)
// -------------------------------------
//   xbar_out_data[o] = st_valid[o] ? xbar_in_data[xbar_sel[o]] : 0
//
// The mux output is forced to zero whenever output `o` is not carrying a
// flit, rather than holding its previous selection. A held value would be
// indistinguishable, three modules downstream, from a real flit that
// happened to repeat -- the output port would load a stale payload into the
// link register on a cycle where `flit_valid` is low and the only thing
// keeping the link quiet would be that one bit. Zeroing costs nothing here
// because the mux is combinational, and it makes "no grant" and "grant of
// an all-zero payload" observably different at the port boundary.
//
//
// Index range
// -----------
// `xbar_sel` is 3 bits wide (it counts input ports 0..4) but only values
// below NUM_PORTS are reachable from SA stage 2, which drives it from a
// one-hot over `s1_valid`. An out-of-range value would index past the end
// of `xbar_in_*`, so it is checked rather than assumed -- see the
// assertion at the bottom.
//
//
// Dependencies
// ------------
//   None inside this module; it is a leaf. It reads the arbiter's
//   `xbar_sel`/`st_valid` and the input ports' post-mux datapath.
//

module crossbar #(
    parameter int NUM_PORTS = 5  // fixed by the 5x5 crossbar
) (
    // ------------------------------------------------------------------
    // Clock and reset are not used by any datapath logic in here -- the
    // block is a pure function of its inputs -- but they exist so the
    // assertions at the bottom have an event to sample on. They cost
    // nothing on an unused combinational block and they keep this module's
    // port list the same shape as every other router block.
    // ------------------------------------------------------------------
    input logic clk,
    input logic rst_n,  // synchronous, active low -- matches fifo.sv

    // ------------------------------------------------------------------
    // Datapath in: one entry per input port. Each input port has already
    // resolved its own VC mux (driven by `sa_pick`), so these are
    // post-selection -- the crossbar never has to look at a VC index.
    // ------------------------------------------------------------------
    input  logic [NUM_PORTS-1:0][31:0] xbar_in_data,
    input  logic [NUM_PORTS-1:0][3:0]  xbar_in_route_next,

    // ------------------------------------------------------------------
    // Control in: from SA stage 2. `xbar_sel[o]` is the input port index
    // whose flit leaves through output `o`; `st_valid[o]` says whether any
    // flit leaves through `o` at all.
    // ------------------------------------------------------------------
    input  logic [NUM_PORTS-1:0][2:0]  xbar_sel,
    input  logic [NUM_PORTS-1:0]       st_valid,

    // ------------------------------------------------------------------
    // Datapath out: one entry per output port, consumed by the matching
    // noc_output_port instance (which registers it onto the link).
    // ------------------------------------------------------------------
    output logic [NUM_PORTS-1:0][31:0] xbar_out_data,
    output logic [NUM_PORTS-1:0][3:0]  xbar_out_route_next
);


  //===========================================================================
  // The muxes
  //
  // Both live in one always_comb so they cannot drift apart: they are two
  // views of the same selection and must be gated identically.
  //
  // The loop index is an `int` used as an array index rather than a
  // generate block, because the selection is a *runtime* value (xbar_sel is
  // an SA output) and generate blocks can only express compile-time choices.
  //===========================================================================

  always_comb begin : mux5
    logic [31:0] d;   // scratch: the selected input port's datapath
    logic [3:0]  r;   // scratch: the same port's lookahead route

    // Default first, unconditionally, so that no path through the block can
    // leave an output stale. Assigning the default inside the loop after
    // reading the old value would be a classic inferred-latch recipe.
    xbar_out_data       = '0;
    xbar_out_route_next = '0;

    for (int o = 0; o < NUM_PORTS; o++) begin
      // Declared at the innermost scope and assigned on both arms: an
      // always_comb variable assigned on only one arm is what the latch
      // warnings are for, and `d` is read on the other arm of the ternary
      // below.
      d = '0;
      r = '0;
      if (st_valid[o] && (xbar_sel[o] < 3'(NUM_PORTS))) begin
        d = xbar_in_data[xbar_sel[o]];
        r = xbar_in_route_next[xbar_sel[o]];
      end
      xbar_out_data[o]       = d;
      xbar_out_route_next[o] = r;
    end
  end


  //===========================================================================
  // Assertions
  //
  // These are the crossbar's half of seam 6: the arbiter promises that
  // `xbar_sel` names an input port SA stage 1 already picked, and that
  // promise has to be checked *here*, where the selection is actually
  // consumed -- otherwise a broken grant reaches the link with a
  // plausible-looking payload and only shows up as a protocol error in the
  // *next* router, far from its cause.
  //===========================================================================

  generate
    for (genvar o = 0; o < NUM_PORTS; o++) begin : gen_xbar_assert

      // -- The selection must be in range --------------------------------
      // st_valid[o] means "some input port won output o". If the index it
      // names were out of range the mux above would read past the end of
      // xbar_in_*, so the guard in the always_comb and this assertion are
      // two halves of one statement: the guard keeps the simulation
      // defined, the assertion says the guard should never have to fire.
      assert property (@(posedge clk) disable iff (!rst_n)
                       st_valid[o] |-> (xbar_sel[o] < 3'(NUM_PORTS)))
        else $error("crossbar: output %0d granted input index %0d, out of range 0..%0d",
                    o, xbar_sel[o], NUM_PORTS - 1);

      // -- An idle output must be silent ---------------------------------
      // Not merely "not valid": the datapath itself has to read zero. A
      // held mux output on an idle port is indistinguishable downstream
      // from a real flit, and this is the rule that makes "no grant" and
      // "a grant of an all-zero payload" different things.
      assert property (@(posedge clk) disable iff (!rst_n)
                       !st_valid[o] |->
                         ((xbar_out_data[o] == 32'b0) &&
                          (xbar_out_route_next[o] == 4'b0)))
        else $error("crossbar: idle output %0d drove data=%h route=%h",
                    o, xbar_out_data[o], xbar_out_route_next[o]);

      // -- Data and route_next must name the SAME input port -------------
      // This is the property that would break first if someone re-gated one
      // mux with st_valid and the other with something subtly different, or
      // pointed one of them at a different register. Checked as two
      // independent equalities against the same xbar_sel so that a mismatch
      // is caught here rather than as a wrong route inside the following
      // router.
      assert property (@(posedge clk) disable iff (!rst_n)
                       (st_valid[o] && (xbar_sel[o] < 3'(NUM_PORTS))) |->
                         ((xbar_out_data[o] == xbar_in_data[xbar_sel[o]]) &&
                          (xbar_out_route_next[o] == xbar_in_route_next[xbar_sel[o]])))
        else $error("crossbar: output %0d does not track its selection (%0d)",
                    o, xbar_sel[o]);

    end
  endgenerate

endmodule
