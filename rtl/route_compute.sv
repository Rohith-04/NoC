// route_compute.sv
//
// Pure combinational lookahead route-compute block. No clk/rst_n -- this
// module never latches anything. The Input Port module is responsible for
// sampling route_self into the per-VC control register on head-flit
// arrival; RC just produces a combinational value every cycle.
//
// One instance per input port (5 per router), parameterized by
// IS_LOCAL_PORT rather than being two separate modules -- only step 1
// below differs by port type; everything after that is identical hardware.
//
// Interface deliberately takes pre-sliced fields (dest_x/dest_y/route_in),
// not the raw flit -- the Input Port already owns flit-format decoding
// (e.g. for its own head/body/tail dispatch), so RC doesn't duplicate
// that knowledge.

module route_compute #(
    parameter logic [2:0] CUR_X         = '0,  // this router's X coord (compile-time, per-instance)
    parameter logic [2:0] CUR_Y         = '0,  // this router's Y coord (compile-time, per-instance)
    parameter bit         IS_LOCAL_PORT = 0    // 1 = Local port instance (dual compute_dir call)
                                               // 0 = N/E/S/W instance (single call + field read)
) (
    input logic [2:0] dest_x,   // packet's destination X (from HEAD field)
    input logic [2:0] dest_y,   // packet's destination Y (from HEAD field)
    input logic [3:0] route_in, // incoming HEAD's ROUTE field -- this router's own_route,
                                // already computed by the sender's RC on the previous hop.
                                // Unused when IS_LOCAL_PORT=1 (no incoming header exists yet).

    output logic [3:0] route_self,  // own_route: this router's exit port for this packet.
                                    // Gates VA. Latched externally into the per-VC register.
    output logic [3:0] route_next   // lookahead route for the NEXT router. Has pipeline slack --
                                    // only needed at ST/header-merge time, not on VA's critical path.
                                    // Lives in its own register outside the VC struct, written at
                                    // SA-win/transmit time -- not this module's concern where it ends up.
);

  // Route direction encoding (see linnea_router_design_reference.md sec 1)
  localparam logic [3:0] DIR_LOCAL = 4'b0000;
  localparam logic [3:0] DIR_NORTH = 4'b0001;
  localparam logic [3:0] DIR_EAST  = 4'b0010;
  localparam logic [3:0] DIR_WEST  = 4'b0100;
  localparam logic [3:0] DIR_SOUTH = 4'b1000;

  // -------------------------------------------------------------------
  // compute_dir: pure XY-DOR comparator/priority-encoder.
  // X corrected first, Y corrected second, LOCAL if both already match.
  // Same function reused for both call sites (route_self at Local,
  // route_next everywhere) -- just fed different (cur_x,cur_y) pairs.
  // -------------------------------------------------------------------
  function automatic logic [3:0] compute_dir(input logic [2:0] cur_x, input logic [2:0] cur_y,
                                             input logic [2:0] tgt_x, input logic [2:0] tgt_y);
    if (cur_x != tgt_x) begin
      // X not yet corrected -- move toward dest_x first, ignore Y entirely
      compute_dir = (tgt_x > cur_x) ? DIR_EAST : DIR_WEST;
    end else if (cur_y != tgt_y) begin
      // X already correct -- now correct Y.
      // Y increases downward: increasing Y = SOUTH (per design reference sec 1)
      compute_dir = (tgt_y > cur_y) ? DIR_SOUTH : DIR_NORTH;
    end else begin
      // Both coordinates match this router -- packet terminates here
      compute_dir = DIR_LOCAL;
    end
  endfunction

  // -------------------------------------------------------------------
  // Step 1: own_route (route_self) -- the ONLY place IS_LOCAL_PORT
  // changes the hardware. Everything below this point is identical
  // regardless of port type.
  // -------------------------------------------------------------------
  logic [3:0] route_self_c;

  always_comb begin
    if (IS_LOCAL_PORT) begin
      // Freshly-injected packet: no incoming header to read from,
      // must compute this router's own exit port fresh.
      route_self_c = compute_dir(CUR_X, CUR_Y, dest_x, dest_y);
    end else begin
      // N/E/S/W: own_route was already computed FOR this router by the
      // sender's RC on the previous hop -- zero-latency field read,
      // no compute_dir call needed.
      route_self_c = route_in;
    end
  end

  assign route_self = route_self_c;

  // -------------------------------------------------------------------
  // Step 2: derive the downstream router's coordinates from route_self.
  // Only meaningful when route_self != LOCAL -- gated in step 3 below.
  // Boundary case (no neighbor in the computed direction) is assumed
  // impossible here -- guaranteed by the mesh topology + valid dest
  // coordinates, not something RC defensively checks.
  // -------------------------------------------------------------------
  logic [2:0] next_x, next_y;

  always_comb begin
    next_x = CUR_X;
    next_y = CUR_Y;
    unique case (route_self_c)
      DIR_EAST:  next_x = CUR_X + 3'd1;
      DIR_WEST:  next_x = CUR_X - 3'd1;
      DIR_SOUTH: next_y = CUR_Y + 3'd1;  // Y increases downward
      DIR_NORTH: next_y = CUR_Y - 3'd1;
      default:   ;  // DIR_LOCAL -- next_x/next_y unused, route_next forced below
    endcase
  end

  // -------------------------------------------------------------------
  // Step 3: route_next -- lookahead compute_dir call using the
  // DOWNSTREAM router's coordinates (next_x, next_y) and the packet's
  // (still statically-carried) destination.
  //
  // Explicit LOCAL edge case: if this packet terminates HERE, route_next
  // has no meaning for a next hop that doesn't exist. Driven to LOCAL
  // explicitly rather than left as compute_dir's output on garbage
  // next_x/next_y, to avoid X-propagation masking bugs in simulation.
  // -------------------------------------------------------------------
  always_comb begin
    if (route_self_c == DIR_LOCAL) begin
      route_next = DIR_LOCAL;
    end else begin
      route_next = compute_dir(next_x, next_y, dest_x, dest_y);
    end
  end

endmodule
