// Self-checking tests for noc_output_port.

`timescale 1ns / 1ps

module tb_noc_output_port;

  import noc_tb_pkg::*;

  localparam realtime CLK_PERIOD = 10ns;

  parameter int NUM_VC = 4;

  localparam int VC_W   = (NUM_VC > 1) ? $clog2(NUM_VC) : 1;

  localparam logic [3:0] DIR_LOCAL = 4'b0000;
  localparam logic [3:0] DIR_NORTH = 4'b0001;
  localparam logic [3:0] DIR_EAST  = 4'b0010;
  localparam logic [3:0] DIR_WEST  = 4'b0100;
  localparam logic [3:0] DIR_SOUTH = 4'b1000;

  localparam logic [3:0] DIR [5] = '{DIR_LOCAL, DIR_NORTH, DIR_EAST, DIR_WEST, DIR_SOUTH};

  logic        clk;
  logic        rst_n;

  logic [FLIT_W-1:0] xbar_out_data;
  logic [3:0]  xbar_out_route_next;
  logic        st_valid;
  logic [VC_W-1:0]  st_out_vc;

  logic [FLIT_W-1:0] flit_data;
  logic        flit_valid;
  logic [VC_W-1:0]  vc_id;

  initial clk = 0;
  always #(CLK_PERIOD / 2) clk = ~clk;

  noc_output_port #(

      .FLIT_W(FLIT_W),
      .NUM_VC(NUM_VC)
  ) dut (
      .clk                (clk),
      .rst_n              (rst_n),
      .xbar_out_data      (xbar_out_data),
      .xbar_out_route_next(xbar_out_route_next),
      .st_valid           (st_valid),
      .st_out_vc          (st_out_vc),
      .flit_data          (flit_data),
      .flit_valid         (flit_valid),
      .vc_id              (vc_id)
  );

  task automatic reset_dut();
    xbar_out_data       = '0;
    xbar_out_route_next = '0;
    st_valid            = 1'b0;
    st_out_vc           = '0;
    rst_n               = 0;
    repeat (4) @(posedge clk);
    @(negedge clk);
    rst_n = 1;
    #1;
  endtask

  function automatic logic [FLIT_W-1:0] make_flit(input logic [1:0] typ, input logic [1:0] kind,
                                            input logic [3:0] route_field, input int tag);
    return mk_hdr(typ, kind, route_field, 3'd0, 3'd0, TAG_W'((tag * 37) + 1));
  endfunction

  task automatic cycle(input string tag, input logic [FLIT_W-1:0] d, input logic [3:0] r,
                       input logic v, input logic [VC_W-1:0] svc);
    logic [FLIT_W-1:0] exp_m;

    @(negedge clk);
    xbar_out_data       = d;
    xbar_out_route_next = r;
    st_valid            = v;
    st_out_vc           = svc;
    #1;

    exp_m = ref_merge(d, r);

    check($sformatf("%s merge result", tag), dut.merged, exp_m);

    @(posedge clk);
    #1;

    check($sformatf("%s flit_valid", tag), {31'b0, flit_valid}, {31'b0, v});
    check($sformatf("%s flit_data", tag), flit_data, v ? exp_m : 32'h0);
    check($sformatf("%s vc_id sideband", tag), {30'b0, vc_id}, v ? {30'b0, svc} : 32'h0);
  endtask

  task automatic t1_reset();
    check("T1 flit_valid low after reset", {31'b0, flit_valid}, 32'h0);
    check("T1 flit_data cleared by reset", flit_data, 32'h0);
    check("T1 vc_id cleared by reset", {30'b0, vc_id}, 32'h0);
  endtask

  task automatic t2_all_types();
    logic [1:0] typ;
    logic [3:0] stale;
    logic [3:0] look;
    int         tag;

    typ   = FLIT_BODY;
    stale = DIR_SOUTH;
    look  = DIR_EAST;

    for (int i = 0; i < 4; i++) begin
      case (i)
        0: typ = FLIT_BODY;
        1: typ = FLIT_HEAD;
        2: typ = FLIT_TAIL;
        default: typ = FLIT_HEAD_TAIL;
      endcase
      tag = i + 1;
      cycle($sformatf("T2 type %02b", typ),
            make_flit(typ, KIND_WR_RESP, stale, tag), look, 1'b1, VC_W'(3 % NUM_VC));
    end
  endtask

  task automatic t3_only_route_field_changes();
    logic [FLIT_W-1:0] d;
    logic [FLIT_W-1:0] got;
    logic [3:0]  look;

    look = DIR_NORTH;
    d    = make_flit(FLIT_HEAD, KIND_RD_REQ, DIR_SOUTH, 7);
    cycle("T3 HEAD", d, look, 1'b1, VC_W'(1 % NUM_VC));
    got = dut.merged;
    check("T3 HEAD: bits above the route field untouched", got & ~ROUTE_MASK, d & ~ROUTE_MASK);
    check("T3 HEAD: KIND untouched (D3)", flit_kind(got), flit_kind(d));
    check("T3 HEAD: type field untouched", flit_type(got), flit_type(d));
    check("T3 HEAD: route field replaced", flit_route(got), look);

    d = make_flit(FLIT_TAIL, KIND_RD_RESP, DIR_WEST, 9);
    cycle("T3 TAIL", d, look, 1'b1, VC_W'(2 % NUM_VC));
    got = dut.merged;
    check("T3 TAIL: whole word identical to the input", got, d);
    check("T3 TAIL: route field still payload", flit_route(got), flit_route(d));
  endtask

  task automatic t4_idle();
    cycle("T4 active", make_flit(FLIT_HEAD_TAIL, KIND_WR_REQ, DIR_WEST, 11), DIR_LOCAL, 1'b1, VC_W'(2 % NUM_VC));
    check("T4 flit_present after the active cycle", {31'b0, flit_valid}, 32'h1);

    cycle("T4 idle with stale data", 32'hDEAD_BEEF, 4'b1111, 1'b0, VC_W'(3 % NUM_VC));
    check("T4 flit_valid low after idle", {31'b0, flit_valid}, 32'h0);
    check("T4 flit_data zero after idle", flit_data, 32'h0);
    check("T4 vc_id zero after idle", {30'b0, vc_id}, 32'h0);
  endtask

  task automatic t5_back_to_back();
    logic [FLIT_W-1:0] d;
    logic [FLIT_W-1:0] exp_prev;
    logic [3:0]  look;
    logic [VC_W-1:0]  svc;
    bit          have_prev;

    exp_prev  = '0;
    have_prev = 1'b0;

    for (int i = 0; i < 8; i++) begin

      if (i % 2 == 0) d = make_flit(FLIT_HEAD, 2'(i % 4), DIR_SOUTH, i + 20);
      else d = make_flit(FLIT_BODY, 2'(i % 4), 4'((i * 3) % 16), i + 20);
      look = DIR[(i + 1) % 5];
      svc  = VC_W'(i % NUM_VC);
      cycle($sformatf("T5 beat %0d", i), d, look, 1'b1, svc);

      if (have_prev) check($sformatf("T5 beat %0d is not a repeat", i),
                           flit_data == exp_prev, 1'b0);
      exp_prev  = dut.merged;
      have_prev = 1'b1;
    end
  endtask

  task automatic t6_kind_field_never_rewritten();
    logic [FLIT_W-1:0] d;

    d = make_flit(FLIT_HEAD, KIND_RD_RESP, DIR_SOUTH, 31);
    cycle("T6 head with a KIND the sideband does not share", d, DIR_WEST, 1'b1, VC_W'(0 % NUM_VC));
    check("T6 in-flit KIND kept its own value", flit_kind(dut.merged), KIND_RD_RESP);
    check("T6 sideband carries the authoritative VC", vc_id, VC_W'(0));

    check("T6 KIND did not become the sideband VC", flit_kind(dut.merged) == vc_id, 1'b0);

    d = make_flit(FLIT_TAIL, KIND_WR_RESP, 4'h5, 33);
    cycle("T6 tail whose payload overlaps the KIND slot", d, DIR_EAST, 1'b1, VC_W'(1 % NUM_VC));
    check("T6 tail payload in the KIND slot preserved", flit_kind(dut.merged), flit_kind(d));
  endtask

  task automatic t7_valid_pairs();
    logic     v;
    logic [VC_W-1:0] svc;

    for (int i = 0; i < 10; i++) begin : t7_beat
      v   = (i % 3) != 1;
      svc = VC_W'((i + 1) % NUM_VC);

      cycle($sformatf("T7 beat %0d", i), make_flit(FLIT_HEAD, KIND_WR_REQ, DIR_EAST, 40 + i),
            DIR_NORTH, v, svc);

      if (!v) check($sformatf("T7 beat %0d: sideband does not leak into an idle cycle", i),
                    {30'b0, vc_id}, 32'h0);
    end
  endtask

  initial begin : main
    if ($test$plusargs("vcd")) begin
      $dumpfile("sim/noc_output_port.vcd");
      $dumpvars(0, tb_noc_output_port);
    end

    reset_dut();

    $display("---- T1  reset clears the link register ----");
    t1_reset();

    $display("---- T2  every flit type, stale route vs lookahead ----");
    t2_all_types();

    $display("---- T3  only [13:10] changes ----");
    t3_only_route_field_changes();

    $display("---- T4  idle cycles leave the wire silent ----");
    t4_idle();

    $display("---- T5  back-to-back, one flit per cycle ----");
    t5_back_to_back();

    $display("---- T6  D3: the in-flit KIND field is never rewritten ----");
    t6_kind_field_never_rewritten();

    $display("---- T7  flit_valid and vc_id paired with their grant ----");
    t7_valid_pairs();

    $display("");
    if (errors == 0) $display("ALL %0d CHECKS PASSED", checks);
    else $display("%0d/%0d CHECKS FAILED", errors, checks);

    $finish;
  end

endmodule
