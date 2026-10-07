`timescale 1ns / 1ps

// router_top.sv
//
// The whole router: 5 noc_input_port, 1 arbiter, 1 crossbar, 5
// noc_output_port (section 4.6). Nothing in here is algorithmic -- every
// decision is made by one of those blocks. What this module owns is the
// *wiring*, and on a 5-port VC router the wiring is where an otherwise
// correct design silently breaks.
//
//
// Port index and direction encoding (section 2)
// ---------------------------------------------
//   index   0        1       2      3      4
//   port    LOCAL    NORTH   EAST   WEST   SOUTH
//   dir     0000     0001    0010   0100   1000
//
// A direction converts to an index by its set-bit position plus one, and
// an index converts back by 1 << index. The arbiter, the crossbar and the
// tests all use the same two functions -- see `dir_to_idx` in arbiter.sv.
// An EAST output of this router wires to the WEST input of the neighbour,
// which is why "output port" and "input port" are separate namespaces that
// happen to share these five indices.
//
//
// The three things that make the wiring subtle
// --------------------------------------------
// 1. DIRECTIONALITY AT THE SEAMS. The arbiter speaks packed per-port buses
//    (`[NUM_PORTS-1:0][NUM_VC-1:0]...`), because it sees all five ports at
//    once. A noc_input_port sees one port and speaks per-VC vectors,
//    including two *unpacked* arrays for the request fields. Something has
//    to translate between those two shapes, and doing it in one direction
//    only would leave half the signals undriven. Every fold below is
//    written explicitly, in the correct direction, next to the signal it
//    moves -- there is no implicit conversion anywhere.
//
// 2. PORT ENDPOINTS. A module instance may only be connected to a plain
//    signal or to a whole array. An element select used as the connection
//    (`u(.in(sig[i]))`) does not see writes after time 0 and the connection
//    silently freezes at its initial value. Every instance below is
//    therefore wired to generate-scope local signals, and those locals are
//    folded into the shared buses with a continuous assign at a *constant*
//    genvar index. The same rule is why the tests are written the way they
//    are -- see README "Testbench Wiring Rules".
//
// 3. EDGE-OF-MESH TIE-OFF. A router sitting on the boundary of the mesh
//    has no neighbour on some sides. Spec 4.6: tie the incoming
//    `flit_valid` and `ds_credit_valid` to 0 for those ports, and assert
//    that XY routing never sends anything there. Both halves matter -- the
//    tie keeps an undriven input from floating into a FIFO, and the
//    assertion says the tie should never be load-bearing. Note what is NOT
//    tied: the *outgoing* side. Gating it would hide a routing bug where
//    the assertion would catch it.
//
//
// What is asserted here rather than in a child
// --------------------------------------------
// Only cross-block seams: that a grant implies a pick (arbiter -> input
// port), that an absent port is never selected, that a credit never comes
// back on a link that does not exist, and that the crossbar is fed exactly
// what the input ports presented. Everything a single block can check about
// itself is already checked inside it.
//
//
// Parameters
// ----------
//   FIFO_DEPTH     input-port FIFO depth. Also the arbiter's DIR_CREDITS,
//                  because a downstream credit IS "a free slot in that
//                  downstream FIFO" -- if these two ever disagree the
//                  credit loop over- or under-counts and the router
//                  eventually either stalls or overflows a neighbour.
//   LOCAL_CREDITS  the NI's receive buffer depth per VC, the init value for
//                  credit_count[LOCAL][*].
//   HAS_*          per-direction presence. Index order matches the table
//                  above.
//
//
// Dependencies
// ------------
//   fifo, route_compute (inside noc_input_port); noc_input_port, arbiter,
//   crossbar, noc_output_port.
//

module router_top #(
    parameter int         NUM_PORTS     = 5,  // fixed by the 5x5 crossbar
    parameter int         NUM_VC        = 2,  // fixed by section 1.1
    parameter int         LOCAL_IDX     = 0,  // index of the LOCAL port
    parameter int         FIFO_DEPTH    = 8,  // neighbour input FIFO depth --
                                              // must equal noc_input_port's
                                              // FIFO and arbiter DIR_CREDITS
    parameter int         LOCAL_CREDITS = 4,  // NI receive buffer depth / VC
    parameter logic [2:0] CUR_X         = '0, // this router's coordinates
    parameter logic [2:0] CUR_Y         = '0,
    parameter bit         HAS_LOCAL     = 1'b1,
    parameter bit         HAS_NORTH     = 1'b1,
    parameter bit         HAS_EAST      = 1'b1,
    parameter bit         HAS_WEST      = 1'b1,
    parameter bit         HAS_SOUTH     = 1'b1
) (
    input logic clk,
    input logic rst_n,  // synchronous, active low -- matches fifo.sv

    //------------------------------------------------------------------
    // Incoming links. One entry per PORT, not per neighbour direction:
    // index LOCAL is the network interface, index NORTH is the link coming
    // in from the north neighbour (and therefore carrying the north
    // neighbour's SOUTH output).
    //------------------------------------------------------------------
    input  logic [NUM_PORTS-1:0][31:0]            in_flit_data,
    input  logic [NUM_PORTS-1:0]                  in_flit_valid,
    input  logic [NUM_PORTS-1:0][1:0]             in_vc_id,

    //------------------------------------------------------------------
    // Outgoing links, one entry per port, and the credits this router
    // returns to whoever feeds each incoming link (assumption D1: one bit
    // per VC, because two VCs may free a slot in the same cycle).
    //
    // These two are NOT the same port index: credit_return_valid[p] is
    // consumed by the neighbour that drives in_flit_*[p].
    //------------------------------------------------------------------
    output logic [NUM_PORTS-1:0][31:0]            out_flit_data,
    output logic [NUM_PORTS-1:0]                  out_flit_valid,
    output logic [NUM_PORTS-1:0][1:0]             out_vc_id,
    output logic [NUM_PORTS-1:0][NUM_VC-1:0]      credit_return_valid,

    //------------------------------------------------------------------
    // Credits the downstream consumer of each outgoing link hands back
    // (assumption D1 again, read this way: ds_credit_valid[o][k] is a free
    // slot in the downstream router's input port o, VC k).
    //------------------------------------------------------------------
    input  logic [NUM_PORTS-1:0][NUM_VC-1:0]      ds_credit_valid
);


  //===========================================================================
  // Constants
  //===========================================================================

  // Per-port presence, indexed exactly like every other port-indexed signal
  // in this design. An unpacked array so that element 0 is LOCAL and the
  // declaration reads in the same order as the table in the header -- a
  // packed version written as an assignment pattern would put the first
  // entry at the MSB and silently invert the whole thing.
  localparam bit HAS_P [NUM_PORTS] =
      '{HAS_LOCAL, HAS_NORTH, HAS_EAST, HAS_WEST, HAS_SOUTH};


  //===========================================================================
  // Arbiter-facing buses
  //
  // Packed and indexed [port][vc], matching the arbiter's port list exactly
  // so that each of them can be handed to the instance whole.
  //===========================================================================

  // VA
  logic [NUM_PORTS-1:0][NUM_VC-1:0]       a_va_req;
  logic [NUM_PORTS-1:0][NUM_VC-1:0][3:0]  a_va_req_out_port;
  logic [NUM_PORTS-1:0][NUM_VC-1:0]       a_va_req_single;
  logic [NUM_PORTS-1:0][NUM_VC-1:0]       a_va_gnt;
  logic [NUM_PORTS-1:0][NUM_VC-1:0][1:0]  a_va_gnt_out_vc;

  // SA
  logic [NUM_PORTS-1:0][NUM_VC-1:0]       a_sa_req;
  logic [NUM_PORTS-1:0][NUM_VC-1:0][3:0]  a_sa_req_out_port;
  logic [NUM_PORTS-1:0][NUM_VC-1:0][1:0]  a_sa_req_out_vc;
  logic [NUM_PORTS-1:0][NUM_VC-1:0]       a_sa_req_last;
  logic [NUM_PORTS-1:0][NUM_VC-1:0]       a_sa_gnt;
  logic [NUM_PORTS-1:0][NUM_VC-1:0]       a_sa_pick;

  // Switch result -> crossbar and output ports
  logic [NUM_PORTS-1:0][2:0]              a_xbar_sel;
  logic [NUM_PORTS-1:0]                   a_st_valid;
  logic [NUM_PORTS-1:0][1:0]              a_st_out_vc;


  //===========================================================================
  // Crossbar buses
  //===========================================================================

  logic [NUM_PORTS-1:0][31:0] xbar_in_data;
  logic [NUM_PORTS-1:0][3:0]  xbar_in_route_next;
  logic [NUM_PORTS-1:0][31:0] xbar_out_data;
  logic [NUM_PORTS-1:0][3:0]  xbar_out_route_next;


  //===========================================================================
  // The five input ports
  //
  // Each iteration owns a set of local signals, connects them to the
  // instance as whole signals, and folds them into the shared buses at a
  // constant genvar index. The fold direction differs per signal because
  // the instance and the arbiter disagree about who drives what -- every
  // line below therefore says which way the value travels.
  //===========================================================================

  generate
    for (genvar p = 0; p < NUM_PORTS; p = p + 1) begin : gen_in_port

      // ---- link side -----------------------------------------------------
      logic [31:0]        l_flit_data;
      logic               l_flit_valid;
      logic [1:0]         l_vc_id;
      logic [NUM_VC-1:0]  l_credit_return;   // -> top-level output

      // ---- arbiter-facing ------------------------------------------------
      logic [NUM_VC-1:0]  l_req_va;          // -> a_va_req
      logic [3:0]         l_va_req_out_port [NUM_VC];   // -> a_va_req_out_port
      logic [NUM_VC-1:0]  l_va_req_single;   // -> a_va_req_single
      logic [NUM_VC-1:0]  l_va_gnt;          // <- a_va_gnt
      logic [1:0]         l_va_gnt_out_vc [NUM_VC];     // <- a_va_gnt_out_vc

      logic [NUM_VC-1:0]  l_req_sa;          // -> a_sa_req
      logic [3:0]         l_sa_req_out_port [NUM_VC];   // -> a_sa_req_out_port
      logic [1:0]         l_sa_req_out_vc [NUM_VC];     // -> a_sa_req_out_vc
      logic [NUM_VC-1:0]  l_sa_req_last;     // -> a_sa_req_last
      logic [NUM_VC-1:0]  l_sa_gnt;          // <- a_sa_gnt
      logic [NUM_VC-1:0]  l_sa_pick;         // <- a_sa_pick

      // ---- crossbar-facing -----------------------------------------------
      logic [31:0]        l_st_flit_data;    // -> xbar_in_data
      logic [3:0]         l_st_route_next;   // -> xbar_in_route_next

      // ---- link tie-off (section 4.6) ------------------------------------
      //
      // A port with no neighbour behind it must not see a floating input:
      // an undriven flit_valid would look like a stream of flits and fill
      // the FIFO with X/0. This is the tie half; the assertion at the
      // bottom of this file is the "it should never be needed" half.
      //
      // Reading in_*[p] here is safe: p is a genvar, so the index is fixed
      // at elaboration, and the expression sits on the right of a
      // continuous assign rather than in a port connection.
      assign l_flit_data  = HAS_P[p] ? in_flit_data[p]  : 32'h0;
      assign l_flit_valid = HAS_P[p] ? in_flit_valid[p] : 1'b0;
      assign l_vc_id      = HAS_P[p] ? in_vc_id[p]      : 2'b0;

      noc_input_port #(
          .NUM_VC       (NUM_VC),
          .CUR_X        (CUR_X),
          .CUR_Y        (CUR_Y),
          // A generate constant: this folds to 1'b0 or 1'b1 per instance at
          // elaboration, which is what lets route_compute know whether the
          // header on data_out already carries a route (directional ports)
          // or has to compute one from the destination fields (LOCAL).
          .IS_LOCAL_PORT(p == LOCAL_IDX)
      ) u_in_port (
          .clk                (clk),
          .rst_n              (rst_n),
          .flit_data          (l_flit_data),
          .flit_valid         (l_flit_valid),
          .vc_id              (l_vc_id),
          .credit_return_valid(l_credit_return),
          .req_va             (l_req_va),
          .va_req_out_port    (l_va_req_out_port),
          .va_req_single      (l_va_req_single),
          .va_gnt             (l_va_gnt),
          .va_gnt_out_vc      (l_va_gnt_out_vc),
          .req_sa             (l_req_sa),
          .sa_req_out_port    (l_sa_req_out_port),
          .sa_req_out_vc      (l_sa_req_out_vc),
          .sa_req_last        (l_sa_req_last),
          .sa_gnt             (l_sa_gnt),
          .sa_pick            (l_sa_pick),
          .st_flit_data       (l_st_flit_data),
          .st_route_next      (l_st_route_next)
      );

      // ---- folds: instance -> shared bus (inputs to the arbiter) ----------
      assign a_va_req[p]       = l_req_va;
      assign a_va_req_single[p] = l_va_req_single;
      assign a_sa_req[p]       = l_req_sa;
      assign a_sa_req_last[p]  = l_sa_req_last;

      // ---- folds: shared bus -> instance (outputs from the arbiter) -------
      assign l_va_gnt = a_va_gnt[p];
      assign l_sa_gnt = a_sa_gnt[p];
      assign l_sa_pick = a_sa_pick[p];

      // ---- folds for the two unpacked per-VC request arrays ---------------
      //
      // The instance's port is an unpacked array (so the endpoint is the
      // whole array, per the wiring rule) while the arbiter's port is a
      // packed [port][vc] field. They cannot be assigned to each other
      // directly -- an unpacked array and a packed slice are different
      // types -- so each VC is moved one at a time at a constant index.
      for (genvar v = 0; v < NUM_VC; v = v + 1) begin : gen_vc_fold
        // instance -> arbiter
        assign a_va_req_out_port[p][v] = l_va_req_out_port[v];
        assign a_sa_req_out_port[p][v] = l_sa_req_out_port[v];
        assign a_sa_req_out_vc[p][v]   = l_sa_req_out_vc[v];
        // arbiter -> instance
        assign l_va_gnt_out_vc[v]      = a_va_gnt_out_vc[p][v];
      end

      // ---- folds: instance -> crossbar and -> top-level credit output -----
      assign xbar_in_data[p]        = l_st_flit_data;
      assign xbar_in_route_next[p]  = l_st_route_next;
      assign credit_return_valid[p] = l_credit_return;

    end
  endgenerate


  //===========================================================================
  // Arbiter
  //
  // Every port here is a whole packed bus, so the connection is a single
  // line per signal with no index at the endpoint.
  //===========================================================================

  arbiter #(
      .NUM_PORTS    (NUM_PORTS),
      .NUM_VC       (NUM_VC),
      .LOCAL_IDX    (LOCAL_IDX),
      .DIR_CREDITS  (FIFO_DEPTH),   // a credit == a free slot in the
      .LOCAL_CREDITS(LOCAL_CREDITS)  // downstream FIFO of that same depth
  ) u_arb (
      .clk             (clk),
      .rst_n           (rst_n),
      // VA
      .va_req          (a_va_req),
      .va_req_out_port (a_va_req_out_port),
      .va_req_single   (a_va_req_single),
      .va_gnt          (a_va_gnt),
      .va_gnt_out_vc   (a_va_gnt_out_vc),
      // SA
      .sa_req          (a_sa_req),
      .sa_req_out_port (a_sa_req_out_port),
      .sa_req_out_vc   (a_sa_req_out_vc),
      .sa_req_last     (a_sa_req_last),
      .sa_gnt          (a_sa_gnt),
      .sa_pick         (a_sa_pick),
      // switch result
      .xbar_sel        (a_xbar_sel),
      .st_valid        (a_st_valid),
      .st_out_vc       (a_st_out_vc),
      // credits back from downstream
      .ds_credit_valid (ds_credit_valid)
  );


  //===========================================================================
  // Crossbar
  //
  // Fed directly from the per-input-port folds and from the arbiter's
  // selection, both whole buses.
  //===========================================================================

  crossbar #(
      .NUM_PORTS(NUM_PORTS)
  ) u_xbar (
      .clk                (clk),
      .rst_n              (rst_n),
      .xbar_in_data       (xbar_in_data),
      .xbar_in_route_next (xbar_in_route_next),
      .xbar_sel           (a_xbar_sel),
      .st_valid           (a_st_valid),
      .xbar_out_data      (xbar_out_data),
      .xbar_out_route_next(xbar_out_route_next)
  );


  //===========================================================================
  // The five output ports (the link-transmit registers)
  //
  // Same pattern as the input ports: local signals at the instance's
  // endpoints, folded into the top-level buses at a constant index. What
  // is NOT done here is gating an absent port's output -- see the header
  // comment; the assertion below is the specified behaviour.
  //===========================================================================

  generate
    for (genvar p = 0; p < NUM_PORTS; p = p + 1) begin : gen_out_port

      logic [31:0] l_xbar_data;
      logic [3:0]  l_xbar_route_next;
      logic        l_st_valid;
      logic [1:0]  l_st_out_vc;

      logic [31:0] l_flit_data;      // -> top-level output
      logic        l_flit_valid;     // -> top-level output
      logic [1:0]  l_vc_id;          // -> top-level output

      assign l_xbar_data       = xbar_out_data[p];
      assign l_xbar_route_next = xbar_out_route_next[p];
      assign l_st_valid        = a_st_valid[p];
      assign l_st_out_vc       = a_st_out_vc[p];

      noc_output_port u_out_port (
          .clk                (clk),
          .rst_n              (rst_n),
          .xbar_out_data      (l_xbar_data),
          .xbar_out_route_next(l_xbar_route_next),
          .st_valid           (l_st_valid),
          .st_out_vc          (l_st_out_vc),
          .flit_data          (l_flit_data),
          .flit_valid         (l_flit_valid),
          .vc_id              (l_vc_id)
      );

      assign out_flit_data[p] = l_flit_data;
      assign out_flit_valid[p] = l_flit_valid;
      assign out_vc_id[p]     = l_vc_id;

    end
  endgenerate


  //===========================================================================
  // Assertions -- cross-block seams only
  //
  // Each child already checks everything it can see by itself. What is left
  // is exactly what sits between two children, which neither of them can
  // check without reaching into the other.
  //===========================================================================

  generate
    for (genvar p = 0; p < NUM_PORTS; p = p + 1) begin : gen_top_assert

      // -- Seam 6: a stage-2 grant implies a stage-1 pick -------------------
      // The arbiter picks a VC within the port (stage 1) and then grants it
      // (stage 2); the input port uses sa_pick to select the pre-crossbar
      // data mux. If a grant could arrive without a pick, the flit on the
      // crossbar would be a different VC's flit than the one the arbiter
      // thinks it switched -- both blocks would be individually consistent
      // and the packet would still be corrupted. Stated bitwise rather than
      // as "|gnt |-> |pick", because the rule is per VC: a port could have
      // a pick on VC0 and a grant on VC1 and still satisfy the weaker form.
      // The arbiter asserts this too, but from its side; asserting it here
      // confirms the *connection* rather than either block's internals.
      assert property (@(posedge clk) disable iff (!rst_n)
                       a_sa_gnt[p] == (a_sa_gnt[p] & a_sa_pick[p]))
        else $error("router_top: port %0d granted without a stage-1 pick", p);

      // -- No credit may come back on a link that does not exist ------------
      // credit_return_valid is driven by noc_input_port from its own fetch,
      // and a fetch can only happen if flit_valid reached the FIFO, and
      // flit_valid is tied off above. So this should be structurally
      // impossible -- which is exactly why it is worth stating: if someone
      // later removes the tie to "simplify" the edge ports, this fires
      // instead of the symptom appearing as phantom credits in a neighbour.
      assert property (@(posedge clk) disable iff (!rst_n)
                       !HAS_P[p] |-> !(|credit_return_valid[p]))
        else $error("router_top: port %0d has no link but returned credits %b",
                    p, credit_return_valid[p]);

      // -- Nothing may be routed to a port with no neighbour ---------------
      // The spec's instruction for edge ports, in full: XY routing with an
      // in-range destination never selects an absent direction, so a grant
      // on one is a routing bug, not an edge case to be handled. Note the
      // output is deliberately NOT gated (see the header) -- an actual
      // out_flit_valid here is the bug this is looking for.
      assert property (@(posedge clk) disable iff (!rst_n)
                       !HAS_P[p] |-> !a_st_valid[p])
        else $error("router_top: something was routed out of absent port %0d", p);

      // -- The arbiter can only grant what that port actually asked for -----
      // Both halves of this live inside the arbiter, but the two signals
      // cross a generate fold on their way here, and a fold that pointed at
      // the wrong port would make port p's grant answer port q's request.
      // Each block would stay individually consistent while the pair was
      // crossed, which is exactly the failure this catches.
      assert property (@(posedge clk) disable iff (!rst_n)
                       a_sa_gnt[p] == (a_sa_gnt[p] & a_sa_req[p]))
        else $error("router_top: port %0d granted a VC that did not request (gnt=%b req=%b)",
                    p, a_sa_gnt[p], a_sa_req[p]);

    end
  endgenerate

endmodule
