// Computes the current output direction and next-hop XY lookahead.

module route_compute #(
    parameter logic [2:0] CUR_X         = '0,
    parameter logic [2:0] CUR_Y         = '0,
    parameter bit         IS_LOCAL_PORT = 0

) (
    input logic [2:0] dest_x,
    input logic [2:0] dest_y,
    input logic [3:0] route_in,

    output logic [3:0] route_self,

    output logic [3:0] route_next

);

  localparam logic [3:0] DIR_LOCAL = 4'b0000;
  localparam logic [3:0] DIR_NORTH = 4'b0001;
  localparam logic [3:0] DIR_EAST  = 4'b0010;
  localparam logic [3:0] DIR_WEST  = 4'b0100;
  localparam logic [3:0] DIR_SOUTH = 4'b1000;

  function automatic logic [3:0] compute_dir(input logic [2:0] cur_x, input logic [2:0] cur_y,
                                             input logic [2:0] tgt_x, input logic [2:0] tgt_y);
    if (cur_x != tgt_x) begin

      compute_dir = (tgt_x > cur_x) ? DIR_EAST : DIR_WEST;
    end else if (cur_y != tgt_y) begin

      compute_dir = (tgt_y > cur_y) ? DIR_SOUTH : DIR_NORTH;
    end else begin

      compute_dir = DIR_LOCAL;
    end
  endfunction

  logic [3:0] route_self_c;

  always_comb begin
    // Directional inputs use the previous router's lookahead.
    if (IS_LOCAL_PORT) begin

      route_self_c = compute_dir(CUR_X, CUR_Y, dest_x, dest_y);
    end else begin

      route_self_c = route_in;
    end
  end

  assign route_self = route_self_c;

  logic [2:0] next_x, next_y;

  always_comb begin
    next_x = CUR_X;
    next_y = CUR_Y;
    unique case (route_self_c)
      DIR_EAST:  next_x = CUR_X + 3'd1;
      DIR_WEST:  next_x = CUR_X - 3'd1;
      DIR_SOUTH: next_y = CUR_Y + 3'd1;
      DIR_NORTH: next_y = CUR_Y - 3'd1;
      default:   ;
    endcase
  end

  always_comb begin
    if (route_self_c == DIR_LOCAL) begin
      route_next = DIR_LOCAL;
    end else begin
      route_next = compute_dir(next_x, next_y, dest_x, dest_y);
    end
  end

endmodule
