`timescale 1ns / 1ps

//------------------------------------------------------------------------------
// NoC Input Port
//
// Terminates one incoming router link and owns everything that belongs to the
// receive side of that link:
//
//   - one FIFO per virtual channel (flit buffering + flow control),
//   - one route_compute instance per virtual channel (RC + lookahead),
//   - the per-VC packet control state (route latch, output-VC assignment),
//   - the request side of the VA and SA arbiters.
//
// It deliberately does NOT allocate, arbitrate or switch. Those live in
// `arbiter` and `crossbar`. This module only asks for what it needs and obeys
// the grants it is handed. Keeping the split here is what makes the arbiter
// testable on its own with a mock input port, and the input port testable on
// its own with a mock arbiter.
//
// Packet flow (one VC shown; NUM_VC identical copies run in parallel):
//
//   incoming link
//        |
//        v
//   VC demultiplex (by sideband vc_id)
//        |
//        v
//   per-VC FIFO -- fetch --> credit_return (registered, one cycle later)
//        |
//        v
//   data_out = active flit                    <- the per-VC "head register"
//        |
//        +----> route_compute --> route_self  (this router's exit port)
//        |                     \-> route_next (lookahead for next router)
//        |
//        +----> VA request   (fresh packet still needs a downstream VC)
//        |
//        +----> SA request   (packet already owns a downstream VC)
//                          |
//                          v
//                    sa_pick chooses this VC's flit for the crossbar
//
//
// The timing rule everything else follows
// ---------------------------------------
// The FIFO's data_out is REGISTERED: a read issued in cycle t places the
// fetched flit on data_out in t+1. Every signal in this module is defined
// relative to that one fact:
//
//   cycle t       fetch[v] = 1  (fifo_rd_enable asserted; data_out stale)
//   cycle t+1     data_out = fetched flit, head_valid = 1, arrive = 1
//                   ^ ARRIVAL CYCLE. route_compute is live against this
//                     flit's header, and the first VA request is issued now.
//   end of t+1    out_port latched from rc_route_self
//   cycle t+2     out_port stable; SA request can be issued (once VA granted)
//
// `arrive` is simply the registered form of `fetch`. It is the ONLY event
// that marks "a freshly fetched flit is on data_out", so route capture keys
// off `arrive && is_head` -- NOT off an edge of `head_valid`. Using a
// head_valid edge mixes two different things (a flit becoming active and a
// flit arriving) and, when head_valid is already high across a grant, misses
// the event entirely.
//
//
// The fetch rule (option ii)
// --------------------------
//     fetch = (!head_valid || sa_gnt) && (!fifo_empty || fifo_wr_enable)
//
// Read it as two independent clauses:
//
//   (!head_valid || sa_gnt)
//       The head register must be free. It is free either because no flit is
//       active, or because the active flit is leaving this cycle (sa_gnt) --
//       in which case the departing flit frees the register at the same edge
//       the new one arrives, so both may happen at once.
//
//   (!fifo_empty || fifo_wr_enable)
//       There must be something to fetch: either a buffered flit, or a flit
//       arriving on the link right now, which the FIFO's empty-bypass will
//       forward straight to data_out without ever entering storage.
//
// When fetch and sa_gnt coincide, head_valid stays 1 (fetch wins the
// assignment ordering in the sequential block below). This is what buys one
// flit per cycle per VC. The alternative -- letting the grant clear
// head_valid -- strands the flit that was just fetched.
//
//
// Credits
// -------
// credit_return_valid is registered: `credit_return_valid <= fetch`. A credit
// therefore means "one FIFO slot was freed by a prefetch read", not "one
// flit left the router". data_out is extra storage on top of the FIFO depth
// and is not counted, so the downstream side sees depth+1 physical slots
// against `depth` credits -- conservative by exactly one slot, which is what
// makes the loop safe against the same-cycle arrival/departure case.
//
// Registering also keeps the credit wire off this module's combinational
// path (assumption D4 in the spec).
//
//
// Flit format
// -----------
//
// HEAD / HEAD_TAIL (linnea_v2 section 3.2 -- the field map above the low 14
// bits is still marked proposed there, but the low 14 are fixed):
//
//   [39]     PAR      parity; reserved, passed through untouched
//   [38]     EXT      extension flag; must be 0 for now
//   [37:35]  SRC_Y
//   [34:32]  SRC_X
//   [31:30]  BURST
//   [29:22]  LEN
//   [21:14]  ID
//   [13:10]  ROUTE    rewritten at every hop (lookahead)
//    [9:7]   DEST_Y
//    [6:4]   DEST_X
//    [3:2]   KIND     packet kind, set by the source NI; routers ignore it
//    [1:0]   FLIT_TYPE
//
// BODY / TAIL:
//
//   [39:2]   PAYLOAD
//    [1:0]   FLIT_TYPE
//
// Everything this module reads is in the low 14 bits (linnea_v2 section 2),
// so everything above ROUTE is opaque payload here and the field map can
// still move without touching this file. In particular the VC a packet
// occupies is link-level sideband, not a flit field: the `vc_id` sideband is
// authoritative (assumption D3), and the output port's header merge never
// rewrites [3:2] -- which used to be VC_ID and is now KIND.
//
//
// Type encoding shortcuts
// -----------------------
//   00 BODY       is_head = 0  is_last = 0
//   01 HEAD       is_head = 1  is_last = 0
//   10 TAIL       is_head = 0  is_last = 1
//   11 HEAD_TAIL  is_head = 1  is_last = 1
//
// i.e. is_head = type[0] and is_last = type[1]. Both shortcuts depend on this
// exact encoding, so an assertion at the bottom of the file pins it down.
//
//
// Dependencies
// ------------
//   fifo
//       Synchronous per-VC FIFO. Registered data_out, empty-bypass, and
//       rejects reads on empty with no simultaneous write.
//
//   route_compute
//       Pure combinational routing + lookahead. Combinational passthrough,
//       never latches anything.
//
// See also: linnea_router_implementation_spec.md sections 4.2, 5, 6, 9.
//------------------------------------------------------------------------------

module noc_input_port #(
    parameter int         FLIT_W        = 40,
    // Input FIFO depth. This MUST track the caller's FIFO_DEPTH -- the
    // arbiter's directional credit pool is sized from the same number, and
    // a pool larger than the buffer overruns it (a pool smaller only wastes
    // bandwidth). It used to be hardcoded to 8 while router_top.FIFO_DEPTH
    // only reached DIR_CREDITS, so the two silently disagreed.
    parameter int         DEPTH         = 4,
    parameter int         NUM_VC        = 4,
    parameter logic [2:0] CUR_X         = '0,
    parameter logic [2:0] CUR_Y         = '0,
    parameter bit         IS_LOCAL_PORT = 0
) (
    input logic clk,
    input logic rst_n,

    //--------------------------------------------------------------------------
    // Incoming link
    //
    // vc_id is sideband: it selects which per-VC FIFO receives this flit. It
    // is authoritative for routing and flow control. A HEAD's [3:2] used to
    // carry a VC that went stale after the first hop (assumption D3); it is
    // KIND now, set once by the source NI and ignored here for a simpler
    // reason -- the router is not its consumer at all.
    //--------------------------------------------------------------------------

    input logic [FLIT_W-1:0] flit_data,
    input logic        flit_valid,
    input logic [VC_W-1:0]  vc_id,

    //--------------------------------------------------------------------------
    // Credit return to the upstream router
    //
    // One bit per VC, so two VCs may free a slot in the same cycle. Asserted
    // the cycle AFTER the fetch that freed the slot (registered).
    //--------------------------------------------------------------------------

    output logic [NUM_VC-1:0] credit_return_valid,

    //--------------------------------------------------------------------------
    // Virtual-channel allocation (VA) interface
    //
    // va_req[v]         this VC holds a HEAD/HEAD_TAIL and does not yet own
    //                   a downstream VC.
    // va_req_out_port[v] the output port the packet needs from THIS router.
    //                   Live RC output in the arrival cycle, the latched
    //                   copy in every cycle after -- see the mux below.
    // va_req_single[v]  the packet is a single flit (HEAD_TAIL). VA uses it
    //                   as a priority tier so short packets jump ahead.
    // va_gnt[v]         VA won this case; from here the packet owns
    //                   downstream VC v itself -- linnea_v2 section 4.4
    //                   matches the two, so there is no separately
    //                   transmitted assignment to hand back.
    //--------------------------------------------------------------------------

    output logic [NUM_VC-1:0] req_va,
    output logic [3:0]        va_req_out_port  [NUM_VC],
    output logic [NUM_VC-1:0] va_req_single,
    input  logic [NUM_VC-1:0] va_gnt,

    //--------------------------------------------------------------------------
    // Switch allocation (SA) interface
    //
    // sa_req[v]          this VC holds a flit AND owns a downstream VC.
    // sa_req_out_port[v] which output port it wants (stage-2 target).
    // sa_req_out_vc[v]   which downstream VC it targets (credit mask index).
    //                    Constantly v: see the note where it is driven.
    // sa_req_last[v]     the active flit is the packet's last one (TAIL or
    //                    HEAD_TAIL). The arbiter releases its output-VC
    //                    reservation when it sees this AND grants.
    // sa_gnt[v]          stage 2 granted this VC; its flit crosses this cycle.
    // sa_pick[v]         stage 1 picked this VC; selects the pre-crossbar mux
    //                    early so the data mux is not on the stage-2 path.
    //                    sa_gnt implies sa_pick.
    //--------------------------------------------------------------------------

    output logic [NUM_VC-1:0] req_sa,
    output logic [3:0]        sa_req_out_port [NUM_VC],
    output logic [VC_W-1:0]        sa_req_out_vc   [NUM_VC],
    output logic [NUM_VC-1:0] sa_req_last,
    input  logic [NUM_VC-1:0] sa_gnt,
    input  logic [NUM_VC-1:0] sa_pick,

    //--------------------------------------------------------------------------
    // Crossbar-facing datapath
    //
    // Single post-mux outputs. The OR-mux over VCs is resolved here (driven
    // by sa_pick) so the crossbar only has to mux across input PORTS, which
    // keeps the 5:1 crossbar mux from stacking a 2:1 VC mux inside it.
    //
    // st_route_next is the lookahead route for the downstream router; the
    // output port merges it into [13:10] of a HEAD flit as it loads the link
    // register.
    //--------------------------------------------------------------------------

    output logic [FLIT_W-1:0] st_flit_data,
    output logic [3:0]  st_route_next
);

  // VC index width (section 1 of linnea_v2): enough bits to name any of
  // NUM_VC virtual channels. Derived here rather than passed in, so a
  // -GNUM_VC sweep cannot leave the FIFO-select or request sidebands
  // narrower than the index they carry.
  localparam int VC_W = (NUM_VC > 1) ? $clog2(NUM_VC) : 1;

  //-------------------------------------------------------------------------
  // Parameter checks
  //
  // DEPTH's own rule is enforced by fifo; what matters here is that this
  // module's DEPTH and NUM_VC stay addressable, because both are swept from
  // outside.
  //-------------------------------------------------------------------------

  initial begin
    assert ((NUM_VC == 2) || (NUM_VC == 4) || (NUM_VC == 8))
    else $fatal(1, "noc_input_port: NUM_VC must be 2, 4 or 8 so that VC_W = clog2(NUM_VC) addresses it exactly, got %0d", NUM_VC);

    assert (FLIT_W >= 16)
    else $fatal(1, "noc_input_port: FLIT_W must be at least 16, got %0d", FLIT_W);
  end


  //===========================================================================
  // Protocol constants
  //===========================================================================

  localparam logic [1:0] FLIT_BODY      = 2'b00;
  localparam logic [1:0] FLIT_HEAD      = 2'b01;
  localparam logic [1:0] FLIT_TAIL      = 2'b10;
  localparam logic [1:0] FLIT_HEAD_TAIL = 2'b11;

  // One-hot direction encoding. LOCAL is all-zero so that "not a direction"
  // and "LOCAL" coincide, which makes the reset value of out_port meaningful.
  localparam logic [3:0] DIR_LOCAL = 4'b0000;
  localparam logic [3:0] DIR_NORTH = 4'b0001;
  localparam logic [3:0] DIR_EAST  = 4'b0010;
  localparam logic [3:0] DIR_WEST  = 4'b0100;
  localparam logic [3:0] DIR_SOUTH = 4'b1000;


  //===========================================================================
  // Per-VC control state
  //
  // Everything below is a per-VC register. There is no cross-VC state: two
  // VCs on the same port may be at completely different points in a packet's
  // lifetime simultaneously, which is the entire point of having them.
  //===========================================================================

  // head_valid: data_out holds an active, fetched flit. High in the ARRIVAL
  // cycle (t+1 after a fetch in t), aligned with the data itself.
  logic [NUM_VC-1:0] head_valid;

  // arrive: registered fetch. High in exactly the cycle a freshly fetched
  // flit appears on data_out. This is the single event that says "new flit".
  //
  // Note this is the same register as the old `fifo_rd_enable_d1`; it was
  // renamed because what it means is now load-bearing -- it drives route
  // capture and the live VA output-port mux -- not merely "delayed read".
  logic [NUM_VC-1:0] arrive;

  // out_port: output port of the packet currently at the head of this VC.
  // Captured from route_compute on the arrival cycle and held until the
  // packet's last flit leaves. (Was named `own_route`.)
  logic [3:0] out_port [NUM_VC];

  // assignment_valid: this VC's packet owns a downstream VC, so it is
  // allowed to ask for the switch. Cleared when the last flit is granted.
  //
  // There is no companion `out_vc` any more. It used to hold the output VC
  // VA assigned, because a separable allocator could hand input VC 1 a
  // downstream VC 3 and the port had to remember which. Under linnea_v2
  // section 4.4 the assignment is always the requester's own index, so the
  // register reproduced a value already known at every point of use -- one
  // register of NUM_VC x VC_W bits removed, along with the arbiter output
  // port and the two wires that fed it.
  logic [NUM_VC-1:0] assignment_valid;

  // in_pkt: VERIFICATION ONLY -- no datapath logic reads it. High while this
  // VC is between a HEAD and its TAIL, meaning the flits still to come must
  // be BODY or TAIL. It exists so that the sequence assertion at the bottom
  // of this file can state the rule in the same vocabulary the spec uses
  // ("flit sequence is HEAD, BODY*, TAIL") rather than restating the type
  // encoding at every use.
  logic [NUM_VC-1:0] in_pkt;


  //===========================================================================
  // Per-VC FIFO signals
  //===========================================================================

  logic [NUM_VC-1:0] fifo_wr_enable;
  logic [NUM_VC-1:0] fetch;  // == fifo_rd_enable, by construction

  logic [FLIT_W-1:0] fifo_data_out [NUM_VC];

  logic [NUM_VC-1:0] fifo_empty;
  logic [NUM_VC-1:0] fifo_full;
  logic [NUM_VC-1:0] fifo_err;


  //===========================================================================
  // Route-compute signals
  //===========================================================================

  logic [2:0] rc_dest_x [NUM_VC];
  logic [2:0] rc_dest_y [NUM_VC];

  // ROUTE field carried by an incoming HEAD.
  //
  // For a directional input port this is THIS router's route -- the upstream
  // router already computed it (lookahead) and put it in the header, so
  // route_compute just reads the field instead of recomputing.
  //
  // For the LOCAL input port there is no upstream header yet, so
  // route_compute computes route_self fresh from the destination and this
  // field is structurally ignored (IS_LOCAL_PORT=1).
  logic [3:0] rc_route_in [NUM_VC];

  // This router's exit port for the packet, combinationally.
  logic [3:0] rc_route_self [NUM_VC];

  // Lookahead route for the router one hop downstream, combinationally.
  logic [3:0] rc_route_next [NUM_VC];


  //===========================================================================
  // Active-flit decode
  //
  // Derived from data_out, so these are only meaningful while head_valid is
  // asserted. Everything that consumes them gates on head_valid.
  //===========================================================================

  logic [1:0] flit_type [NUM_VC];
  logic [NUM_VC-1:0] is_head;  // HEAD or HEAD_TAIL   == flit_type[0]
  logic [NUM_VC-1:0] is_last;  // TAIL or HEAD_TAIL   == flit_type[1]


  //===========================================================================
  // Per-VC datapath and request generation
  //===========================================================================

  genvar i;

  generate

    for (i = 0; i < NUM_VC; i++) begin : gen_vc

      //=======================================================================
      // Incoming flit demultiplex
      //
      // Each link flit is written only into the FIFO selected by the
      // sideband vc_id. There is no VC_TAG decoding of the flit payload.
      //=======================================================================

      always_comb begin
        fifo_wr_enable[i] = flit_valid && (vc_id == VC_W'(i));
      end


      //=======================================================================
      // Fetch  (spec equation: option ii)
      //
      //   fetch = (!head_valid || sa_gnt) && (!fifo_empty || fifo_wr_enable)
      //
      // Clause 1 -- the head register is free: either idle, or its occupant
      // is being switched out this very cycle.
      //
      // Clause 2 -- there is something to fetch: a buffered flit, or a flit
      // landing on the link right now that the FIFO will bypass straight to
      // data_out.
      //
      // There is no combinational loop through sa_gnt: sa_gnt is a function
      // of REGISTERED state only (sa_req comes from head_valid and
      // assignment_valid, credits are counters), so it is already settled by
      // the time this expression evaluates.
      //=======================================================================

      always_comb begin
        fetch[i] = (!head_valid[i] || sa_gnt[i]) &&
                   (!fifo_empty[i] || fifo_wr_enable[i]);
      end


      //=======================================================================
      // Per-VC FIFO
      //
      // DEPTH buffer slots. With data_out acting as a further slot, the
      // downstream side holds DEPTH+1 physical positions against the DEPTH
      // credits it is issued -- one slot of slack, which is what absorbs a
      // credit returning in the same cycle a flit is being consumed.
      //=======================================================================

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


      //=======================================================================
      // Flit field extraction
      //
      // Routing metadata is only meaningful for HEAD and HEAD_TAIL; for BODY
      // and TAIL these bits are payload and get ignored because every request
      // below is gated on head_valid (and, for VA, on is_head).
      //=======================================================================

      always_comb begin
        flit_type[i]   = fifo_data_out[i][1:0];

        rc_route_in[i] = fifo_data_out[i][13:10];
        rc_dest_y[i]   = fifo_data_out[i][9:7];
        rc_dest_x[i]   = fifo_data_out[i][6:4];

        is_head[i]     = flit_type[i][0];
        is_last[i]     = flit_type[i][1];
      end


      //=======================================================================
      // Route computation
      //
      // route_self: the output port THIS router needs for this packet.
      // route_next: the route the NEXT router will need -- lookahead, so the
      //             downstream router's RC never sits on a critical path.
      //
      // Both are combinational and only meaningful against a HEAD header on
      // data_out; they are re-evaluated every cycle for free.
      //=======================================================================

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


      //=======================================================================
      // VA request
      //
      //   va_req = head_valid && !assignment_valid && is_head
      //
      // A VC asks for a downstream VC exactly once per packet: when the HEAD
      // is active and no assignment exists yet. BODY/TAIL never ask (they
      // inherit the assignment), and a VC mid-packet never re-asks.
      //
      // va_req_single marks HEAD_TAIL so the allocator can give single-flit
      // packets the higher tier -- they hold an output VC for exactly one
      // cycle, so promoting them costs the winner almost nothing.
      //=======================================================================

      always_comb begin
        req_va[i]       = head_valid[i] && !assignment_valid[i] && is_head[i];
        va_req_single[i] = (flit_type[i] == FLIT_HEAD_TAIL);
      end


      //=======================================================================
      // VA output-port request  (the arrival-cycle live mux)
      //
      //   va_req_out_port = arrive ? rc_route_self : out_port
      //
      // In the arrival cycle out_port still holds the PREVIOUS packet's
      // route (or LOCAL, out of reset), but route_compute is already valid
      // against the new header -- so we take the combinational value.
      //
      // From the next cycle on, out_port has been latched from that very
      // value, so we read the register instead. The two sides are the same
      // number by construction; the mux exists purely to avoid one cycle of
      // dead time between "flit arrives" and "route is requestable".
      //
      // This matters concretely: without the mux, a HEAD arriving into an
      // idle VC would request VA against out_port = LOCAL and win an
      // allocation it has no business having.
      //=======================================================================

      always_comb begin
        va_req_out_port[i] = arrive[i] ? rc_route_self[i] : out_port[i];
      end


      //=======================================================================
      // SA request
      //
      //   sa_req          = head_valid && assignment_valid
      //   sa_req_out_port = out_port      (latched, stable for the packet)
      //   sa_req_out_vc   = the VC index  (credit-mask index)
      //   sa_req_last     = is_last       (TAIL or HEAD_TAIL)
      //
      // sa_req_out_vc is the VC-matched rule in its final form: input VC v
      // was reserved as output VC v, so the credit pool to test is simply
      // this VC's own pool. It used to read a register that captured what VA
      // handed back; with section 4.4 that register held `i` on every write,
      // so the read became a lookup of the index it was being indexed by.
      //
      // sa_req_last is a level, not a pulse: it is asserted for as long as
      // the last flit sits at the head. The arbiter ANDs it with its own
      // grant to decide when to release the output VC, so a stalled TAIL
      // cannot release anything.
      //=======================================================================

      always_comb begin
        req_sa[i]          = head_valid[i] && assignment_valid[i];
        sa_req_out_port[i] = out_port[i];
        sa_req_out_vc[i]   = VC_W'(i);
        sa_req_last[i]     = is_last[i];
      end


      //=======================================================================
      // Arbiter-facing flit type
      //
      // Exposed only as the two single-bit shortcuts; the arbiter never needs
      // the full 2-bit type (req_flit_type's original 2-bit form was
      // replaced by va_req_single + sa_req_last, which are the only two
      // distinctions it acts on).
      //=======================================================================

    end

  endgenerate


  //===========================================================================
  // Head tracking, route capture, and credit return
  //
  // One process owns all three because they all key off the same events
  // (fetch and sa_gnt) and their relative priority is the whole ballgame.
  //
  // RESET STYLE: synchronous active-low, matching `fifo.sv`. The FIFO is a
  // verified module whose reset style is fixed, so this module adopts it
  // rather than the other way round. Mixing async-reset flops with
  // sync-reset flops on the same reset net is a classic synthesis surprise
  // (recovery/removal violations on the async ones, none on the sync ones),
  // so every sequential block in this design uses `@(posedge clk)` + `if
  // (!rst_n)`. Follow this convention in the arbiter and output port too.
  //===========================================================================

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

      //---------------------------------------------------------------------
      // arrive and credit return are both straight registrations of fetch.
      //
      // arrive          -> marks the cycle the fetched flit is on data_out
      // credit_return   -> tells upstream a FIFO slot was freed, one cycle
      //                    after the read that freed it (assumption D4)
      //---------------------------------------------------------------------

      arrive              <= fetch;
      credit_return_valid <= fetch;

      for (int v = 0; v < NUM_VC; v++) begin

        //-------------------------------------------------------------------
        // head_valid: fetch MUST win over sa_gnt.
        //
        // When both happen in the same cycle the next flit is already on its
        // way to data_out, so the VC stays active. Written in this order --
        // fetch first, grant second -- so that a grant arriving alongside a
        // fetch cannot clear the flag the fetch just needs to set.
        //
        // With only `sa_gnt` clearing, and fetch gated on !head_valid, a
        // back-to-back stream would advance one flit every three cycles:
        // fetch, hold, grant, fetch... The `|| sa_gnt` term in fetch is what
        // lets a grant and a fetch share a cycle at all.
        //-------------------------------------------------------------------

        if (fetch[v]) begin
          head_valid[v] <= 1'b1;
        end
        else if (sa_gnt[v]) begin
          head_valid[v] <= 1'b0;
        end

        //-------------------------------------------------------------------
        // Route capture on the ARRIVAL event, not on a head_valid edge.
        //
        // arrive && is_head is true in exactly one cycle per packet head:
        // the cycle its header sits on data_out with route_compute live.
        // A head_valid rising edge would be wrong twice over -- it also
        // fires for the first flit of a packet when head_valid had already
        // been high from the previous flit, and it fires one cycle later
        // than the RC output it is trying to capture.
        //-------------------------------------------------------------------

        if (arrive[v] && is_head[v]) begin
          out_port[v] <= rc_route_self[v];
        end

        //-------------------------------------------------------------------
        // Packet-boundary tracker (verification only -- see the declaration).
        //
        // Advances on `arrive`, which pulses exactly once per flit actually
        // fetched, so it observes every flit on this VC exactly once and in
        // order. That is the property the sequence assertion below is
        // policing: no flit skipped, none seen twice.
        //
        //   HEAD        starts a packet that continues
        //   HEAD_TAIL   is the entire packet, so nothing is left open
        //   BODY        continues whatever is open
        //   TAIL        closes it
        //-------------------------------------------------------------------

        if (arrive[v]) begin
          if (is_head[v]) in_pkt[v] <= !is_last[v];
          else if (is_last[v]) in_pkt[v] <= 1'b0;
        end

      end

    end
  end


  //===========================================================================
  // Output-VC assignment state
  //
  // VA and SA release the same bit from opposite ends:
  //   set   by va_gnt   (packet acquired a downstream VC)
  //   clear by sa_gnt && is_last (packet's final flit switched out)
  //
  // These are written as two separate `if`s rather than if/else because they
  // genuinely cannot overlap for the same VC in the same cycle -- a VC
  // cannot be acquiring an assignment and releasing one simultaneously --
  // but the last-write-wins ordering below makes the outcome well defined
  // regardless of which convention a future edit assumes.
  //===========================================================================

  always_ff @(posedge clk) begin

    if (!rst_n) begin

      assignment_valid <= '0;

    end

    else begin

      for (int v = 0; v < NUM_VC; v++) begin

        // Mark the VC as owning a downstream slot. There is nothing to
        // remember about WHICH slot: linnea_v2 section 4.4 matches input VC
        // v to output VC v, so the ownership is the index itself.
        if (va_gnt[v]) assignment_valid[v] <= 1'b1;

        // Release on the packet's final flit. HEAD_TAIL qualifies as last
        // through is_last, so a single-flit packet sets and clears this in
        // two consecutive cycles without any special-casing.
        if (sa_gnt[v] && is_last[v]) begin
          assignment_valid[v] <= 1'b0;
        end

      end

    end

  end


  //===========================================================================
  // Crossbar-facing OR-mux
  //
  // sa_pick is one-hot across this port's VCs (guaranteed by SA stage 1 and
  // checked below), so OR-ing the masked contributions selects exactly the
  // picked VC and yields 0 when nothing is picked -- which the crossbar
  // ignores because st_valid is low in that case.
  //
  // Driving this here rather than in the crossbar keeps the crossbar a pure
  // 5:1 mux across input PORTS, and puts the VC selection as close to its
  // source as possible.
  //===========================================================================

  always_comb begin

    st_flit_data = '0;
    st_route_next = '0;

    // Plain accumulator: seed with zero, OR in each masked contribution.
    // The self-read on the `|=` is safe because the seed assignment happens
    // first in the same evaluation, so there is no combinational feedback.
    for (int v = 0; v < NUM_VC; v++) begin
      if (sa_pick[v]) begin
        st_flit_data  |= fifo_data_out[v];
        st_route_next |= rc_route_next[v];
      end
    end

  end


  //===========================================================================
  // Assertions
  //
  // SVA, unconditional. Verilator parses it today and VCS will later; there
  // is deliberately no per-simulator conditional anywhere in the RTL.
  //===========================================================================

  //-------------------------------------------------------------------------
  // Elaboration-time: pin the flit type encoding table (spec section 2).
  //
  // is_head/is_last below are dynamic checks that the LOGIC honours these
  // constants; this one is a static check that the CONSTANTS themselves still
  // match the table. Both are needed: editing FLIT_TAIL alone would pass the
  // dynamic check while silently disagreeing with every other module and
  // testbench that hard-codes 2'b10.
  //-------------------------------------------------------------------------
  initial begin
    assert ((FLIT_BODY == 2'b00) && (FLIT_HEAD == 2'b01) &&
            (FLIT_TAIL == 2'b10) && (FLIT_HEAD_TAIL == 2'b11))
      else $error("noc_input_port: flit type constants have drifted from the spec encoding");
  end

  genvar g;

  generate
    for (g = 0; g < NUM_VC; g = g + 1) begin : gen_assert_vc

      // -- Grant/ request consistency -------------------------------------
      // A grant with no outstanding request means the arbiter and this module
      // disagree about the state of the VC. This is seam #6 in the spec.
      assert property (@(posedge clk) disable iff (!rst_n)
                       va_gnt[g] |-> req_va[g])
        else $error("noc_input_port: va_gnt without va_req on VC %0d", g);

      // sa_gnt implies sa_req: the arbiter cannot switch a flit this module
      // did not offer.
      assert property (@(posedge clk) disable iff (!rst_n)
                       sa_gnt[g] |-> req_sa[g])
        else $error("noc_input_port: sa_gnt without sa_req on VC %0d", g);

      // Seam #6: stage 2 must select a VC stage 1 already picked. st_flit_data
      // is muxed by sa_pick, so a sa_gnt without sa_pick would switch garbage.
      assert property (@(posedge clk) disable iff (!rst_n)
                       sa_gnt[g] |-> sa_pick[g])
        else $error("noc_input_port: sa_gnt without sa_pick on VC %0d", g);

      // -- Fetch legality --------------------------------------------------
      // Two independent conditions, each with its own message because when
      // one fires you want to know *which* half of the fetch rule broke:
      //
      //   the head register must be free (idle, or draining this cycle), and
      //   there must be something to fetch (buffered, or bypassing in).
      assert property (@(posedge clk) disable iff (!rst_n)
                       fetch[g] |-> (!head_valid[g] || sa_gnt[g]))
        else $error("noc_input_port: fetch with head register stuck on VC %0d", g);

      // Reading an empty FIFO is only legal when a write is bypassing past
      // it in the same cycle; otherwise the FIFO has no word to hand over.
      assert property (@(posedge clk) disable iff (!rst_n)
                       fetch[g] |-> (!fifo_empty[g] || fifo_wr_enable[g]))
        else $error("noc_input_port: fetch from empty VC %0d with no bypass write", g);

      // -- FIFO protocol violations must be unreachable --------------------
      // `full` may legitimately be reached (all 8 slots occupied), but
      // writing into it means the arbiter handed out more credits than the
      // downstream buffer has slots. Credit accounting, not this module, is
      // what is being indicted when this fires.
      assert property (@(posedge clk) disable iff (!rst_n)
                       !(fifo_wr_enable[g] && fifo_full[g]))
        else $error("noc_input_port: wrote into full VC %0d FIFO - credit accounting broken", g);

      // `err` is the FIFO's own union of the two illegal operations. Asserting
      // it separately from the two checks above is deliberate belt-and-braces:
      // if the FIFO's idea of a violation ever drifts from this module's idea
      // of the protocol, one of the three catches it.
      assert property (@(posedge clk) disable iff (!rst_n) !fifo_err[g])
        else $error("noc_input_port: FIFO raised err on VC %0d", g);

      // -- Output-VC assignment integrity ---------------------------------
      // A VA grant while an assignment is already live would leak the old
      // downstream VC (two packets believing they own it).
      assert property (@(posedge clk) disable iff (!rst_n)
                       va_gnt[g] |-> !assignment_valid[g])
        else $error("noc_input_port: va_gnt while assignment already valid on VC %0d", g);

      // -- Type encoding ---------------------------------------------------
      // is_head gates VA eligibility and route capture; is_last tells the
      // arbiter when to release the output VC. Both shortcuts are stated
      // against the named constants rather than raw bit positions so that a
      // change to the encoding has to be made deliberately, next to the
      // comment that explains why it is safe.
      assert property (@(posedge clk) disable iff (!rst_n)
                       head_valid[g] |->
                         (is_head[g] === ((flit_type[g] == FLIT_HEAD) ||
                                          (flit_type[g] == FLIT_HEAD_TAIL))) &&
                         (is_last[g] === ((flit_type[g] == FLIT_TAIL) ||
                                          (flit_type[g] == FLIT_HEAD_TAIL))))
        else $error("noc_input_port: flit type encoding broken on VC %0d: type=%b",
                    g, flit_type[g]);

      // -- Out_port must be a legal direction -----------------------------
      // Checked against the five legal codes, not merely "one-hot", so that a
      // corrupted value like 4'b0011 (which is one-hot-ish in the wrong way)
      // is caught too.
      //
      // Written out as a chain of == rather than `inside { ... }`: the
      // inside operator lowers to a wildcard equality against a concatenation,
      // and the tool refuses that form when it appears inside a property.
      assert property (@(posedge clk) disable iff (!rst_n)
                       head_valid[g] |->
                         ((out_port[g] == DIR_LOCAL) || (out_port[g] == DIR_NORTH) ||
                          (out_port[g] == DIR_EAST)  || (out_port[g] == DIR_WEST)  ||
                          (out_port[g] == DIR_SOUTH)))
        else $error("noc_input_port: out_port not a legal direction on VC %0d: %b",
                    g, out_port[g]);

      // -- Flit sequence: HEAD, BODY*, TAIL (section 8) --------------------
      //
      // Sampled on `arrive`, which pulses exactly once per flit fetched, so
      // this sees every flit on this VC once and in order. `in_pkt` still
      // holds the state from BEFORE this flit, because the sequential block
      // updates it at this same edge -- which is precisely the "what was I
      // expecting next?" answer the check needs.
      //
      // The two ways this fails are the two that matter:
      //   a continuation flit while no packet is open  -> a header was lost
      //   a head flit while a packet is still open     -> a second header,
      //                                                   or a flit seen twice
      assert property (@(posedge clk) disable iff (!rst_n)
                       arrive[g] |-> (in_pkt[g] ? !is_head[g] : is_head[g]))
        else $error("noc_input_port: flit sequence broken on VC %0d: type=%b while in_pkt=%b",
                    g, flit_type[g], in_pkt[g]);

    end

    // -- sa_pick is one-hot at most ----------------------------------------
    // Not exactly one: when the port has nothing to offer, stage 1 picks
    // nothing and all bits are 0.
    assert property (@(posedge clk) disable iff (!rst_n)
                     $countones(sa_pick) <= 1)
      else $error("noc_input_port: sa_pick not one-hot: %b", sa_pick);

    // At most one VC on this port may be switched in a cycle -- the port has
    // a single flit-wide datapath to the crossbar.
    assert property (@(posedge clk) disable iff (!rst_n)
                     $countones(sa_gnt) <= 1)
      else $error("noc_input_port: multiple VCs granted on one port: %b", sa_gnt);

  endgenerate

endmodule
