# NoC

> A reusable, synthesizable Network-on-Chip IP written in SystemVerilog for FPGA prototyping and future multicore SoC integration.

## Overview

This project implements a modular Network-on-Chip (NoC) intended to serve as a reusable communication fabric for FPGA and ASIC-oriented designs.

The primary design goals are:

- Clean and readable RTL
- Synthesizable SystemVerilog
- Modular architecture
- Reusable IP design
- Thorough verification
- Straightforward integration into larger SoCs

Although this NoC is being developed as the communication backbone for the **Linnea** multicore processor, it is designed to be completely usable as a standalone IP block.

---

## Current Features

- Synthesizable SystemVerilog RTL
- Verilator simulation and lint (single tool for both)
- GTKWave waveform generation
- VS Code + slang-server development environment
- Configurable router: `NUM_PORTS`, `NUM_VC`, `FIFO_DEPTH` are parameters
- Packet-based communication (HEAD / BODY / TAIL / HEAD_TAIL flits)
- Two virtual channels per port with per-VC credit tracking
- Dimension-order (XY) routing with a lookahead route field merged into the
  header on the way out
- Verilator-executed SVA on every RTL module, enabled by `--assert`
- Per-module benches plus a single-router bench and a three-router chain bench
- Mutation testing for bench non-vacuity

---

## Planned Features

- [x] Configurable router architecture
- [x] Packet-based communication
- [ ] AXI4-Stream interface
- [ ] Multiple routing algorithms
- [x] Extensive verification environment (bench + assertion + mutation side;
      a UVM environment is the next step, and everything here is written to
      compile under VCS unchanged)
- [ ] FPGA implementation
- [ ] Performance evaluation
- [ ] Synthesis pass at `NUM_VC` 2 and 4 (spec section 10, step 9)

---

## Project Structure

```
.
├── rtl/                        # RTL source files
├── tb/                         # Testbenches + bench support modules
├── docs/                       # One Markdown per source file (see below)
├── sim/                        # Simulation outputs (VCD)
├── tools/                      # Mutation / assertion test scripts
├── PROGRESS.md                 # state of the work, gotchas, next steps
├── files.f                     # compile list (slang-server, and VCS later)
└── Makefile
```

### Documentation

`docs/` mirrors the source tree with one Markdown file per source file:

```
docs/rtl/fifo.md          docs/tb/tb_fifo.md
docs/rtl/route_compute.md docs/tb/tb_route_compute.md
docs/rtl/noc_input_port.md docs/tb/tb_noc_input_port.md
docs/rtl/arbiter.md       docs/tb/tb_arbiter.md
docs/rtl/crossbar.md      docs/tb/tb_crossbar.md
docs/rtl/noc_output_port.md docs/tb/tb_noc_output_port.md
docs/rtl/router_top.md    docs/tb/tb_router_top.md
docs/Makefile.md          docs/tb/tb_router_chain.md
                          docs/tb/mock_arbiter.md
```

Each document has the same three sections, in this order:

1. **Ports and state** — a port table with columns
   `| Signal | Width | Direction | Source → Destination | Working / description |`,
   and, separately, a register/state table with columns
   `| Name | Width | Kind | Reset | Working / description |`.
   For a testbench, whose top has no ports of its own, the port table
   documents the interface presented to and extracted from the DUT.
2. **RTL explanation** — what the file implements and why it is written that
   way. For a bench this section explains how the bench works.
3. **Testing explanation** — what the file's bench covers, how to run it, the
   observed result, and which assertions are exercised.

`docs/rtl/fifo.md` is the exemplar; every other document follows it.

---

## Toolchain

- SystemVerilog
- Verilator (simulation, assertions and lint)
- GTKWave
- Make
- Visual Studio Code
- slang-server
- Verible

---

## Building

```bash
make TOP=<module> sim
```

Example:

```bash
make TOP=router_top sim
```

Run everything:

```bash
for t in fifo route_compute noc_input_port arbiter crossbar noc_output_port \
         router_top router_chain; do make TOP=$t sim; done
```

`tb_router_top` and `tb_router_chain` take a few seconds; the rest are
effectively instant. A run reports `ALL <n> CHECKS PASSED` or lists `[FAIL]`
lines and returns non-zero on failure.

The bench for a top `X` is `tb/tb_X.sv` and its top module is `tb_X`. Any
file in `tb/` that is *not* named `tb_*.sv` is a support module and is
compiled with whichever bench is selected.

---

## Linting

```bash
make TOP=<module> lint
```

---

## Waveforms

```bash
make TOP=<module> wave
```

---

## Testbench Wiring Rules

These are hard requirements of the flow, not style preferences. Breaking one
produces silent wrong results with no warning from the tool.

**Every module port endpoint must be a plain scalar, or the whole array.**
An element select used as the connection endpoint — `dut.out(sig[i])` — does
not reliably see writes made after time 0. The connection freezes at its
initial value, the stimulus never reaches the DUT, and the bench then compares
against a permanently stale response while reporting ordinary assertion
failures. The first version of the `route_compute` coordinate sweep produced
~37k failures that were entirely an artifact of this wiring.

Three patterns are safe:

```systemverilog
// 1. Plain scalar at the endpoint (one DUT instance)
logic [3:0] out_i;
dut u (.route_self(out_i));

// 2. Whole array at the endpoint (port declared unpacked)
logic [3:0] out_arr [NUM_VC];
dut u (.sa_req_out_port(out_arr));

// 3. Generate of instances: plain scalar in the generate scope, then fold
//    into a response bus with a continuous assign using a constant index.
generate
  for (genvar i = 0; i < N; i++) begin : g
    logic [3:0] out_i;
    dut u (.route_self(out_i));
    assign resp_bus[i] = out_i;   // constant genvar index
  end
endgenerate
```

Also worth knowing:

- A `#delay` in straight-line testbench code settles combinational logic
  normally. Delays inside loops are fine too, *provided the endpoints follow
  the rule above*.
- A comment line that begins with the tool's own name is parsed by the
  compiler as a metacomment directive and kills the build with
  "Unknown verilator comment". Never start a comment line that way.

---

## Verilator Language Limits Hit Here

These are not style choices. Each one cost a debugging session, and each is
the reason the RTL or the benches are written the way they are. All of them
are within the SystemVerilog standard, so the same code is valid under VCS.

**`|-> ##1 X` is not supported; write `|=> X`.** Sequences of the form
`[ante] |-> ##1 [consequent]` fail to parse. `|=>` is the equivalent
overlapping-implication form — it already means "one cycle later" — so every
temporal property in the RTL uses `|=>` and nothing needs `##1`.

**`##[n:m]` range delays fail to parse.** Bounded ranges such as
`|=> ##[1:3] ack` are rejected. The properties here are all single-cycle, so
nothing needed one; if a multi-cycle window is ever required, spell it out
as a named sequence of `##` steps.

**No `inside { ... }` inside an assertion.** `expr inside {a, b, c}` is
rejected in that context. Use an explicit OR of equality comparisons —
`rtl/noc_output_port.sv` does exactly that for its route-value legality
check.

**No `'{...}` assignment patterns as arguments.** Passing `'{a, b, c}` into
a task or function call fails. Build the value field by field into a local
first; `tb_router_chain.sv`'s receive log does this.

**Never declare an array of queues** — `type q[N][$]`. Verilator 5.020
corrupts `push_back` on a queue whose index is computed at runtime: entries
silently land in the wrong element. Use a single queue of structs and carry
the index as a field. Every queue of packets in the benches
(`exp_q`, `tx_q`, `rx`) is a queue of structs for exactly this reason.

**A `for` loop with a `return`/`break` in its body can be miscompiled when
the function is inlined into a coroutine.** Verilator hoisted the loop's
`i++` out of the loop body, so `i` was computed once from an uninitialised
value and never advanced — the loop spun forever on `i == 1` with no warning
and no diagnostic. Loops in ordinary tasks and in `always` blocks were fine;
the failure needed an `automatic function` containing a loop with an early
exit, called from the `initial`-block coroutine. `work_pending()` in
`tb_router_chain.sv` was rewritten to use a running counter instead, and the
end-of-test aggregates moved with it. If you add a helper that both loops
over a queue and returns early, check the generated
`obj_dir/<top>/*.cpp` for a `__Vtemp = ((IData)(1U) + i)` sitting *above*
the `while` — that is the bug.

---

## Vision

The goal of this project is to build a reusable Network-on-Chip IP that can be integrated into a wide range of FPGA and ASIC designs.

Long term, this repository will become the communication subsystem of the Linnea multicore SoC while remaining fully usable as an independent project.

---

## License

Released under the MIT License.
