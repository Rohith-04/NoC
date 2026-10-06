`timescale 1ns / 1ps

//------------------------------------------------------------------------------
// NoC Input Port
//
// Terminates one incoming router link and manages the virtual channels
// associated with that link.
//
// Each virtual channel contains:
//
//   - A FIFO holding incoming flits.
//   - Head-flit state indicating whether a flit is currently available to
//     the arbitration stages.
//   - The output port selected for the packet.
//   - The output VC assigned during virtual-channel allocation.
//
// Packet flow:
//
//   incoming link
//        |
//        v
//   VC demultiplex
//        |
//        v
//   per-VC FIFO
//        |
//        v
//   active head
//        |
//        +----> route computation
//        |
//        +----> Virtual-channel allocation
//                       |
//                       v
//                 Switch allocation
//                       |
//                       v
//                 Switch traversal
//
// Routing
// -------
// The routing information carried in a HEAD flit is used differently
// depending on the input port.
//
// For a LOCAL input port, route_compute determines this router's output
// direction directly from the packet destination.
//
// For a directional input port, the ROUTE field in the incoming HEAD was
// computed by the upstream router and already represents the route for this
// router. route_compute therefore treats that field as route_self.
//
// route_compute also produces route_next, which is the lookahead route for
// the router one hop downstream. route_next is exposed directly from this
// module and may be inserted into the outgoing header by the final pipeline
// stage.
//
// Flit format
// -----------
//
// HEAD / HEAD_TAIL:
//
//   [31:14] RESERVED
//   [13:10] ROUTE
//   [9:7]   DEST_Y
//   [6:4]   DEST_X
//   [3:2]   RESERVED
//   [1:0]   FLIT_TYPE
//
// BODY / TAIL:
//
//   [31:2]  PAYLOAD
//   [1:0]   FLIT_TYPE
//
// VC ID is link-level information and is not stored in the flit.
//
// FIFO timing
// -----------
// The FIFO has a registered data_out. A read issued in one cycle therefore
// makes the corresponding flit available at data_out in the following cycle.
//
// The input port keeps a delayed copy of the FIFO read enable so that
// head_valid is asserted in the same cycle that the newly fetched flit is
// available at fifo_data_out.
//
// The FIFO also supports an empty-FIFO write/read bypass. When a flit arrives
// at an empty VC while that VC is being fetched, the FIFO forwards the flit
// directly to data_out. The same one-cycle timing relationship applies.
//
// Dependencies
// ------------
//   fifo
//       Synchronous per-VC FIFO.
//
//   route_compute
//       Combinational routing and lookahead computation.
//------------------------------------------------------------------------------

module noc_input_port #(
    parameter int         NUM_VC        = 2,
    parameter logic [2:0] CUR_X         = '0,
    parameter logic [2:0] CUR_Y         = '0,
    parameter bit         IS_LOCAL_PORT = 0
) (
    input logic clk,
    input logic rst_n,

    //--------------------------------------------------------------------------
    // Incoming link
    //--------------------------------------------------------------------------

    input logic [31:0] flit_data,
    input logic        flit_valid,
    input logic [1:0]  vc_id,

    //--------------------------------------------------------------------------
    // Credit return to the upstream router
    //
    // A credit is returned whenever a flit is removed from one of the
    // per-VC input FIFOs.
    //--------------------------------------------------------------------------

    output logic [NUM_VC-1:0] credit_return_valid,
    output logic [1:0]        credit_return_vc_id [NUM_VC],

    //--------------------------------------------------------------------------
    // Requests to the router arbitration logic
    //
    // req_va:
    //     Requests output-VC allocation for a new packet.
    //
    // req_sa:
    //     Requests switch access for a packet which already owns an output VC.
    //
    // req_out_port:
    //     Current router output required by the packet.
    //
    // req_flit_type:
    //     Type of the currently active flit.
    //--------------------------------------------------------------------------

    output logic [NUM_VC-1:0] req_va,
    output logic [NUM_VC-1:0] req_sa,
    output logic [3:0]        req_out_port  [NUM_VC],
    output logic [1:0]        req_flit_type [NUM_VC],

    //--------------------------------------------------------------------------
    // Arbitration grants
    //
    // va_grant_out_vc identifies the output-side VC assigned to each input VC.
    //--------------------------------------------------------------------------

    input logic [NUM_VC-1:0] va_grant,
    input logic [1:0]        va_grant_out_vc [NUM_VC],
    input logic [NUM_VC-1:0] sa_grant,

    //--------------------------------------------------------------------------
    // Switch traversal interface
    //--------------------------------------------------------------------------

    output logic [31:0] st_flit_data [NUM_VC],
    output logic [1:0]  st_flit_type [NUM_VC],

    //--------------------------------------------------------------------------
    // Lookahead route
    //
    // route_next is generated combinationally by route_compute. It describes
    // the route to be taken at the next router and is intended to be consumed
    // by the outgoing pipeline/header-merge stage.
    //--------------------------------------------------------------------------

    output logic [3:0] route_next [NUM_VC]
);


  //===========================================================================
  // Protocol constants
  //===========================================================================

  localparam logic [1:0] FLIT_BODY      = 2'b00;
  localparam logic [1:0] FLIT_HEAD      = 2'b01;
  localparam logic [1:0] FLIT_TAIL      = 2'b10;
  localparam logic [1:0] FLIT_HEAD_TAIL = 2'b11;

  localparam logic [3:0] DIR_LOCAL = 4'b0000;
  localparam logic [3:0] DIR_NORTH = 4'b0001;
  localparam logic [3:0] DIR_EAST  = 4'b0010;
  localparam logic [3:0] DIR_WEST  = 4'b0100;
  localparam logic [3:0] DIR_SOUTH = 4'b1000;


  //===========================================================================
  // Per-VC control state
  //===========================================================================

  // Indicates that fifo_data_out contains the currently active flit for
  // this VC.
  logic [NUM_VC-1:0] head_valid;

  // Previous-cycle value of head_valid. Used to identify the arrival of a
  // newly fetched head flit.
  logic [NUM_VC-1:0] head_valid_d1;

  // Delayed FIFO read indication. The FIFO produces registered output data,
  // so this signal aligns the read request with the fetched flit.
  logic [NUM_VC-1:0] fifo_rd_enable_d1;

  // Output port selected for the current packet.
  //
  // This is captured when the packet's HEAD becomes active and remains
  // associated with the VC for the lifetime of the packet.
  logic [3:0] own_route [NUM_VC];

  // Output-side VC assigned to this input VC during virtual-channel
  // allocation.
  logic [1:0] out_vc [NUM_VC];

  // Indicates that this VC currently owns a valid output VC assignment.
  logic [NUM_VC-1:0] assignment_valid;


  //===========================================================================
  // Per-VC FIFO signals
  //===========================================================================

  logic [NUM_VC-1:0] fifo_wr_enable;
  logic [NUM_VC-1:0] fifo_rd_enable;

  logic [31:0] fifo_data_out [NUM_VC];

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
  // For directional input ports this represents the current router's route,
  // as calculated by the upstream router.
  //
  // For the LOCAL input port route_compute calculates route_self directly,
  // so this field is ignored by route_compute.
  logic [3:0] rc_route_in [NUM_VC];

  // Current router's route for each VC.
  logic [3:0] rc_route_self [NUM_VC];

  // Decoded type of the active flit.
  logic [1:0] flit_type [NUM_VC];


  //===========================================================================
  // Per-VC datapath and combinational control
  //===========================================================================

  genvar i;

  generate

    for (i = 0; i < NUM_VC; i++) begin : gen_vc

      //=======================================================================
      // Incoming flit demultiplex
      //
      // Each incoming flit is written only into the FIFO selected by the
      // link-level VC identifier.
      //=======================================================================

      always_comb begin
        fifo_wr_enable[i] = flit_valid && (vc_id == i);
      end


      //=======================================================================
      // FIFO fetch
      //
      // A new flit is fetched when this VC has no currently active flit and
      // data is available either in the FIFO or directly on the incoming link.
      //
      // The second case makes use of the FIFO's empty-FIFO bypass.
      //=======================================================================

      always_comb begin
        fifo_rd_enable[i] =
            !head_valid[i] &&
            (!fifo_empty[i] || fifo_wr_enable[i]);
      end


      //=======================================================================
      // Per-VC FIFO
      //=======================================================================

      fifo #(
          .WIDTH(32),
          .DEPTH(8)
      ) u_fifo (
          .clk       (clk),
          .rst_n     (rst_n),

          .wr_enable (fifo_wr_enable[i]),
          .rd_enable (fifo_rd_enable[i]),

          .data_in   (flit_data),
          .data_out  (fifo_data_out[i]),

          .empty     (fifo_empty[i]),
          .full      (fifo_full[i]),
          .err       (fifo_err[i])
      );


      //=======================================================================
      // Flit field extraction
      //
      // Routing metadata is meaningful for HEAD and HEAD_TAIL flits.
      // BODY and TAIL flits use the remaining packet context stored in the
      // per-VC control state.
      //=======================================================================

      always_comb begin
        flit_type[i]   = fifo_data_out[i][1:0];

        rc_route_in[i] = fifo_data_out[i][13:10];
        rc_dest_y[i]   = fifo_data_out[i][9:7];
        rc_dest_x[i]   = fifo_data_out[i][6:4];
      end


      //=======================================================================
      // Route computation
      //
      // route_self identifies the output port required at this router.
      // route_next identifies the route required at the downstream router.
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
          .route_next (route_next[i])
      );


      //=======================================================================
      // Virtual-channel allocation request
      //
      // Only a packet's first flit requests VA. Once an output VC has been
      // assigned, subsequent BODY and TAIL flits retain that assignment.
      //=======================================================================

      always_comb begin
        req_va[i] =
            head_valid[i] &&
            ((flit_type[i] == FLIT_HEAD) ||
             (flit_type[i] == FLIT_HEAD_TAIL)) &&
            !assignment_valid[i];
      end


      //=======================================================================
      // Switch allocation request
      //
      // A VC requests the switch once it owns an output VC.
      //=======================================================================

      always_comb begin
        req_sa[i] =
            head_valid[i] &&
            assignment_valid[i];
      end


      //=======================================================================
      // Credit return
      //
      // Reading one entry from the input FIFO frees one buffer slot, allowing
      // the upstream router to send another flit into this VC.
      //=======================================================================

      always_comb begin
        credit_return_valid[i] = fifo_rd_enable[i];
        credit_return_vc_id[i] = i[1:0];
      end


      //=======================================================================
      // Arbiter and switch-facing outputs
      //=======================================================================

      always_comb begin
        req_out_port[i]  = own_route[i];
        req_flit_type[i] = flit_type[i];

        st_flit_data[i]  = fifo_data_out[i];
        st_flit_type[i]  = flit_type[i];
      end

    end

  endgenerate


  //===========================================================================
  // Head tracking and route capture
  //===========================================================================

  integer v;

  always_ff @(posedge clk or negedge rst_n) begin

    if (!rst_n) begin

      head_valid        <= '0;
      head_valid_d1     <= '0;
      fifo_rd_enable_d1 <= '0;

      for (v = 0; v < NUM_VC; v = v + 1) begin
        own_route[v] <= DIR_LOCAL;
      end

    end

    else begin

      // The FIFO output becomes valid one cycle after the read request.
      fifo_rd_enable_d1 <= fifo_rd_enable;

      // Preserve the previous head state for transition detection.
      head_valid_d1 <= head_valid;

      for (v = 0; v < NUM_VC; v = v + 1) begin

        // A fetched FIFO entry becomes the active flit for this VC.
        if (fifo_rd_enable_d1[v]) begin
          head_valid[v] <= 1'b1;
        end

        // A successful switch traversal consumes the active flit.
        //
        // This assignment follows the fetch condition so that retirement
        // takes priority if both events are presented in the same cycle.
        if (sa_grant[v]) begin
          head_valid[v] <= 1'b0;
        end

        // Capture the route when a newly fetched packet head becomes active.
        //
        // route_compute supplies the appropriate route for both local
        // injection and directional input ports.
        if (head_valid[v] &&
            !head_valid_d1[v] &&
            ((flit_type[v] == FLIT_HEAD) ||
             (flit_type[v] == FLIT_HEAD_TAIL))) begin

          own_route[v] <= rc_route_self[v];

        end

      end

    end
  end


  //===========================================================================
  // Output VC assignment state
  //===========================================================================

  always_ff @(posedge clk or negedge rst_n) begin

    if (!rst_n) begin

      assignment_valid <= '0;

      for (v = 0; v < NUM_VC; v = v + 1) begin
        out_vc[v] <= '0;
      end

    end

    else begin

      for (v = 0; v < NUM_VC; v = v + 1) begin

        // Capture the output VC selected by virtual-channel allocation.
        if (va_grant[v]) begin
          assignment_valid[v] <= 1'b1;
          out_vc[v]            <= va_grant_out_vc[v];
        end

        // The output VC remains reserved until the packet's final flit
        // traverses the switch.
        if (sa_grant[v] &&
            ((flit_type[v] == FLIT_TAIL) ||
             (flit_type[v] == FLIT_HEAD_TAIL))) begin

          assignment_valid[v] <= 1'b0;
        end

      end

    end

  end

endmodule
