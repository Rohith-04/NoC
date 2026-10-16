`timescale 1ns / 1ps

// noc_mesh.sv
//
// A ROWS x COLS array of router_top with every inter-router link resolved
// here. Nothing but the LOCAL ports reaches the outside: the module
// boundary is a *flat packed boundary*, one packed array indexed [row][col]
// per signal, so the bench driving it never learns how many tiles there are,
// which way they face, or how a NORTH output and a SOUTH input relate.
//
// This file is pure SystemVerilog -- no generated wrapper, no script. The
// shape that makes that possible is the one below, and it is the same shape
// router_top uses for its own five ports:
//
//   * each tile drives a generate-scope local (a whole array at the port
//     endpoint -- see README "Testbench Wiring Rules"; an element select in
//     a port connection freezes at time 0 and silently drops the stimulus);
//   * those locals are folded into the mesh-wide link arrays with a
//     continuous assign at a *constant* genvar index;
//   * a tile's inputs are assembled from its neighbours' folded outputs by
//     another set of constant-index continuous assigns, each guarded by an
//     elaboration-time generate `if` so that a boundary tile never even
//     elaborates the index of the neighbour it does not have.
//
//
// The one rule every link obeys
// ----------------------------
// If tile X's output port `o` feeds tile Y's input port `p`, then exactly
// two wires join them:
//
//     X.out_flit_*[o]  ->  Y.in_flit_*[p]
//     Y.credit_return_valid[p]  ->  X.ds_credit_valid[o]
//
// The second line is the one that gets inverted by hand: a credit for a slot
// in Y's input FIFO travels *back* along the same link, and it is Y -- the
// receiver -- that produces it. Applied uniformly, "the neighbour of this
// tile through port D, and that neighbour's port for this link" gives both
// halves for all four directions from one expression, which is why the four
// blocks below are line-for-line identical apart from the indices:
//
//     D     neighbour      neighbour's port for this link
//     NORTH (r-1,c)        SOUTH
//     SOUTH (r+1,c)        NORTH
//     WEST  (r,c-1)        EAST
//     EAST  (r,c+1)        WEST
//
//
// Edge tiles
// ----------
// A tile with no neighbour on some side declares it absent (HAS_*) and its
// inputs are tied off, exactly as spec 4.6 requires inside router_top. What
// is NOT tied is the outward link: gating it would hide a routing bug that
// the wall check at the bottom of this file is there to catch.
//
//
// Parameters
// ----------
//   ROWS, COLS     geometry. 1..8 each: the header's DEST_X/DEST_Y fields are
//                  three bits, so a destination further than 7 cannot be
//                  named at all. Checked at elaboration.
//   FLIT_W         flit width. Runs at 40 only (linnea_v2 section 1's
//                  recorded deviation) but stays a parameter, and is passed
//                  to every tile so the array cannot be built at one width
//                  and wired at another.
//   NUM_VC         virtual channels; drives VC_W everywhere.
//   FIFO_DEPTH     neighbour input FIFO depth, also the arbiter's DIR_CREDITS.
//   LOCAL_CREDITS  the NI receive buffer depth per VC -- the init value of
//                  each tile's LOCAL credit counter, i.e. how many flits the
//                  bench may have in flight into one tile at once.
//

module noc_mesh #(
    parameter int ROWS          = 2,
    parameter int COLS          = 2,
    parameter int NUM_PORTS     = 5,  // fixed by the 5x5 crossbar
    parameter int FLIT_W        = 40, // flit width (linnea_v2, sect 1)
    parameter int NUM_VC        = 4,  // default per linnea_v2 section 1
    parameter int FIFO_DEPTH    = 4,  // neighbour input FIFO depth
    parameter int LOCAL_CREDITS = 4   // NI receive buffer depth / VC
) (
    input logic clk,
    input logic rst_n,  // synchronous, active low -- matches router_top.sv

    //------------------------------------------------------------------
    // Injection: the source of every tile's LOCAL input. The bench is the
    // network interface on this side of the boundary.
    //------------------------------------------------------------------
    input  logic [ROWS-1:0][COLS-1:0][FLIT_W-1:0] inj_data,
    input  logic [ROWS-1:0][COLS-1:0]             inj_valid,
    input  logic [ROWS-1:0][COLS-1:0][VC_W-1:0]   inj_vc,

    //------------------------------------------------------------------
    // Ejection: each tile's LOCAL output, verbatim. Which [row][col] a flit
    // comes out on IS the answer to "where did it go", so the self-test
    // needs no routing model of its own to check it.
    //------------------------------------------------------------------
    output logic [ROWS-1:0][COLS-1:0][FLIT_W-1:0] ej_data,
    output logic [ROWS-1:0][COLS-1:0]             ej_valid,
    output logic [ROWS-1:0][COLS-1:0][VC_W-1:0]   ej_vc,

    //------------------------------------------------------------------
    // The LOCAL link's credit loop, both halves.
    //
    //   lc_credit     the tile freed a slot in its LOCAL input FIFO. This is
    //                 the bench's injection budget: one per flit it pushed in.
    //   lc_ds_credit  the bench is finished with an ejected flit, so the
    //                 tile's arbiter may spend that LOCAL output slot again.
    //
    // They are separate ports because they are separate links in the same
    // sense as every other direction: credits for what went IN come back from
    // the tile, credits for what came OUT go back to the tile.
    //------------------------------------------------------------------
    output logic [ROWS-1:0][COLS-1:0][NUM_VC-1:0] lc_credit,
    input  logic [ROWS-1:0][COLS-1:0][NUM_VC-1:0] lc_ds_credit
);

  // VC index width (linnea_v2 section 1). Declared in the body and used by
  // the port list above -- the same forward reference router_top.sv relies
  // on, and derived rather than independent so the boundary sideband can
  // never be narrower than the index it carries.
  localparam int VC_W = (NUM_VC > 1) ? $clog2(NUM_VC) : 1;

  //=========================================================================
  // Constants
  //=========================================================================

  // Port index, matching router_top's table: an EAST output of one tile
  // feeds the WEST input of the next, which is why "output port" and
  // "input port" are separate namespaces sharing these five numbers.
  localparam int PORT_LOCAL = 0;
  localparam int PORT_NORTH = 1;
  localparam int PORT_EAST  = 2;
  localparam int PORT_WEST  = 3;
  localparam int PORT_SOUTH = 4;

  //=========================================================================
  // Parameter checks
  //
  // Elaboration-time, with the parameter named in the message. Without these
  // a geometry that cannot be addressed surfaces much later as an index
  // quietly landing outside its array instead of as the configuration error
  // it is.
  //=========================================================================
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

  //=========================================================================
  // Mesh-wide link arrays
  //
  // [row][col][port] -- the outward face of every tile, folded from the
  // generate-scope locals below. A neighbour reads these; the bench never
  // does, which is the point of the boundary.
  //=========================================================================
  logic [ROWS-1:0][COLS-1:0][NUM_PORTS-1:0][FLIT_W-1:0]   L_out_data;
  logic [ROWS-1:0][COLS-1:0][NUM_PORTS-1:0]               L_out_valid;
  logic [ROWS-1:0][COLS-1:0][NUM_PORTS-1:0][VC_W-1:0]     L_out_vc;
  logic [ROWS-1:0][COLS-1:0][NUM_PORTS-1:0][NUM_VC-1:0]   L_cred_ret;

  //=========================================================================
  // The tiles
  //=========================================================================
  generate
    for (genvar r = 0; r < ROWS; r++) begin : g_row
      for (genvar c = 0; c < COLS; c++) begin : g_col

        //-------------------------------------------------------------
        // This tile's five port buses, as generate-scope locals so the
        // instance endpoints are whole arrays (README rule).
        //-------------------------------------------------------------
        logic [NUM_PORTS-1:0][FLIT_W-1:0]  t_in_data;
        logic [NUM_PORTS-1:0]              t_in_valid;
        logic [NUM_PORTS-1:0][VC_W-1:0]    t_in_vc;
        logic [NUM_PORTS-1:0][FLIT_W-1:0]  t_out_data;
        logic [NUM_PORTS-1:0]              t_out_valid;
        logic [NUM_PORTS-1:0][VC_W-1:0]    t_out_vc;
        logic [NUM_PORTS-1:0][NUM_VC-1:0]  t_cred_ret;
        logic [NUM_PORTS-1:0][NUM_VC-1:0]  t_ds_cred;

        //-------------------------------------------------------------
        // LOCAL: straight through the flat boundary. The bench is this
        // tile's network interface, so there is no link arithmetic here
        // at all -- only the two credit halves described on the ports.
        //-------------------------------------------------------------
        assign t_in_data[PORT_LOCAL]  = inj_data[r][c];
        assign t_in_valid[PORT_LOCAL] = inj_valid[r][c];
        assign t_in_vc[PORT_LOCAL]    = inj_vc[r][c];
        assign t_ds_cred[PORT_LOCAL]  = lc_ds_credit[r][c];

        assign ej_data[r][c]   = t_out_data[PORT_LOCAL];
        assign ej_valid[r][c]  = t_out_valid[PORT_LOCAL];
        assign ej_vc[r][c]     = t_out_vc[PORT_LOCAL];
        assign lc_credit[r][c] = t_cred_ret[PORT_LOCAL];

        //-------------------------------------------------------------
        // The four inter-tile links.
        //
        // Each is a generate `if`, not a runtime one: for a boundary tile
        // the index of the neighbour that does not exist is never
        // elaborated at all, so there is no out-of-range constant to be
        // folded away and no tie-off that could accidentally read it.
        //
        // The untaken arm drives zeros -- spec 4.6's tie of the incoming
        // flit_valid and ds_credit_valid, applied at the mesh seam.
        //-------------------------------------------------------------

        // North neighbour: its SOUTH output is our NORTH input; our NORTH
        // output lands on its SOUTH input, whose credit return is therefore
        // what refills our NORTH output credits.
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

        // South neighbour: its NORTH output is our SOUTH input.
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

        // West neighbour: its EAST output is our WEST input.
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

        // East neighbour: its WEST output is our EAST input.
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

        //-------------------------------------------------------------
        // The tile itself.
        //
        // HAS_* is the position, folded to a generate constant, so the
        // tie-off inside router_top and the tie-off above cannot disagree:
        // they are both expressions of the same `r` and `c`.
        //-------------------------------------------------------------
        router_top #(
            .FLIT_W        (FLIT_W),
            .NUM_VC        (NUM_VC),
            .FIFO_DEPTH    (FIFO_DEPTH),
            .LOCAL_CREDITS (LOCAL_CREDITS),
            .CUR_X         (3'(c)),
            .CUR_Y         (3'(r)),
            .HAS_LOCAL     (1'b1),             // every tile has an NI
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

        //-------------------------------------------------------------
        // Fold: instance -> mesh-wide link arrays, at constant genvar
        // indices. The whole 5-port bus goes in; the LOCAL slice is read
        // by the boundary assigns above and the four network slices by
        // whichever neighbour exists.
        //-------------------------------------------------------------
        assign L_out_data[r][c]  = t_out_data;
        assign L_out_valid[r][c] = t_out_valid;
        assign L_out_vc[r][c]    = t_out_vc;
        assign L_cred_ret[r][c]  = t_cred_ret;

      end
    end
  endgenerate

  //=========================================================================
  // The walls
  //
  // spec 4.6 ties the INCOMING side of a port with no neighbour inside
  // router_top, and there asserts that its own crossbar never selects one.
  // This is the other half, observed at the seam where the neighbour would
  // have been -- and it is deliberately the whole wire rather than just
  // valid: "there is no link" has to mean no flit, no VC sideband and no
  // credit either, or the tie is quietly load-bearing somewhere.
  //
  // The outgoing side stays live on purpose (spec 4.6: gating it would hide
  // a routing bug), which is exactly why something has to be watching it.
  // This is where a route_compute that decided a tile at the top edge should
  // go north actually shows up.
  //
  // Looping at runtime with variable row/column indices is what lets one
  // block cover every edge tile of any geometry; the guard on each arm is
  // what makes the three checks legal only where the wall actually is.
  //=========================================================================
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
