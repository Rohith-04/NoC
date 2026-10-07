// Compile list for the whole project, in dependency order.
//
// Read by slang-server through .slang/server.json (`-f files.f`), and the
// same order is what a VCS `vcs -f files.f` run should use later. Verilator
// does not need it -- the Makefile globs rtl/*.sv and selects exactly one
// bench -- but keeping this list complete means the language server and any
// future simulator see the same file set.
//
// RTL, in the order section 10 of the spec builds them.
rtl/fifo.sv
rtl/route_compute.sv
rtl/noc_input_port.sv
rtl/arbiter.sv
rtl/crossbar.sv
rtl/noc_output_port.sv
rtl/router_top.sv

// Bench support: not a testbench top, compiled alongside whichever bench is
// selected. mock_arbiter replaces the real SA/VA allocator when a single
// module is under test.
tb/mock_arbiter.sv

// Testbench tops. Every one is a self-contained module with its own clock
// and its own `$finish`; they do not run at the same time and none of them
// is instantiated by another.
tb/tb_fifo.sv
tb/tb_route_compute.sv
tb/tb_noc_input_port.sv
tb/tb_arbiter.sv
tb/tb_crossbar.sv
tb/tb_noc_output_port.sv
tb/tb_router_top.sv
tb/tb_router_chain.sv
