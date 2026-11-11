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

## Router Microarchitecture

A five-port, input-buffered, virtual-channel router. Each input port owns one
FIFO per virtual channel, and a flit through the main pipeline walks

```
BW → VA → SA → ST → LT
```

Route computation is deliberately *not* in that pipeline. `route_compute` is a
look-ahead: it computes the direction for the **next** router from the header
the flit arrived with, so the answer is in hand before the flit is allocated
rather than after it. The result is spliced into the header at the very end, on
the way out.

![Router microarchitecture: five-port input-buffered VC router](docs/images/router_microarchitecture.svg)

*The VC column reads `VC0 … VC(N-1)` on purpose — `NUM_VC` is 2, 4 or 8 and 4
is the default every bench runs at, so the figure holds for any of them.*

The RTL maps onto that figure roughly one module per stage, with two
exceptions worth knowing up front: the FIFOs and the route computer live
*inside* the input port rather than sitting at router level, and VA and SA are
two halves of one arbiter rather than two modules.

| Stage | RTL | Notes |
|---|---|---|
| **BW** — buffer write | `fifo.sv`, one instance per VC inside `noc_input_port.sv` | Credit-tracked, `FIFO_DEPTH` deep, with one slot of slack so a credit returning in the same cycle a flit is consumed is absorbed |
| **RC** — look-ahead route compute | `route_compute.sv`, inside `noc_input_port.sv` | Off the main pipeline. An `IS_LOCAL_PORT` parameter is the *only* difference between the LOCAL instance and the four cardinal ones |
| **VA** — virtual channel allocation | `arbiter.sv`, the row stage | Reserves a free downstream VC; a grant on input VC *v* reserves output VC exactly *v* (v2 §4.5) |
| **SA** — switch allocation | `arbiter.sv`, stages 1 and 2 | Stage 1 picks a VC within an input port, masked by that VC's credit count; stage 2 picks the output |
| **ST** — switch traversal | `crossbar.sv` | 5x5 payload mux |
| **LT** — link traversal | `noc_output_port.sv` | Link register, and the one place a header is rewritten on the way out |
| — | `noc_input_port.sv` | Bundles BW + RC for one input port and drives that port's half of the arbiter |
| — | `router_top.sv` | Instantiates the above, ties off absent ports through `HAS_*`, and carries the cross-module seam assertions |

---

## Current Features

- Synthesizable SystemVerilog RTL
- Verilator simulation and lint (single tool for both)
- GTKWave waveform generation
- VS Code + slang-server development environment
- Configurable router: `FLIT_W`, `NUM_VC`, `FIFO_DEPTH` and the `HAS_*`
  boundary flags are parameters (`NUM_PORTS` is one too, but it is fixed at
  5 by the 5x5 crossbar, so it states the port count rather than making the
  block reconfigurable)
- Packet-based communication (HEAD / BODY / TAIL / HEAD_TAIL flits). `FLIT_W`
  stays a parameter in the RTL but is only ever run at **40**, and no bench
  redeclares it — see `tb/noc_tb_pkg.sv` below
- Configurable virtual-channel count: `NUM_VC` 2, 4 or 8 (default 4), with
  per-VC credit tracking on every link
- Dimension-order (XY) routing with a lookahead route field merged into the
  header on the way out
- A mesh generator, `rtl/noc_mesh.sv`: `ROWS` x `COLS` routers wired by that
  module and nothing else, pure SystemVerilog with no scripting step. The
  boundary outward links are deliberately left live and *watched* rather
  than gated, because gating them would hide a routing bug
- Verilator-executed SVA on every RTL module. `--assert` is **mandatory** in
  both `sim` and `lint`: without it Verilator parses `assert property` and
  silently drops it — no warning, no error, the assertions simply never run
- Nine benches: one for each of the eight RTL modules — `tb_router_top` on a
  single router, `tb_noc_mesh` on a generated array — plus `tb_router_chain`,
  which runs three of them in a line
- `tb/noc_tb_pkg.sv` owns the flit field map, so a bench names *fields*
  (`flit_route()`, `flit_kind()`, `ROUTE_MASK`) and never a bit position —
  moving a field moves the bench or breaks its build instead of silently
  keeping the old slice
- Mutation testing and assertion-negative testing, both for bench
  non-vacuity

---

## Planned Features

- [x] Configurable router architecture
- [x] Packet-based communication
- [x] Parameterized mesh integration — `rtl/noc_mesh.sv` wires any
      `ROWS` x `COLS` array (1..8 each) with one `EDIT ME` point in the bench
      and `make TOP=noc_mesh sim ROWS=n COLS=n`
- [ ] AXI4-Stream interface
- [ ] Multiple routing algorithms
- [x] Extensive verification environment (bench + assertion + mutation +
      assertion-negative side; a UVM environment is the next step, and
      everything here is written to compile under VCS unchanged)
- [ ] FPGA implementation
- [ ] Performance evaluation
- [ ] Synthesis pass at `NUM_VC` 2 and 4 (spec section 10, step 9)

---

## Project Structure

```
.
├── rtl/                        # RTL source files
├── tb/                         # Testbenches + bench support modules
├── docs/                       # One Markdown per source file, plus images/
├── sim/                        # Simulation outputs (VCD)
├── tools/                      # Mutation / assertion test scripts
├── PROGRESS.md                 # state of the work, gotchas, next steps
├── linnea_v2_format_and_rtl_changes.md
│                               # v2 spec -- 40-bit flit, NUM_VC, VC-matched
│                               # VA, helper tasks, the mesh. Authoritative
│                               # wherever it disagrees with v1
├── linnea_router_implementation_spec.md
│                               # v1 spec -- build order, test list, done
│                               # criteria
├── files.f                     # compile list (slang-server, and VCS later)
└── Makefile
```

### Documentation

`docs/` mirrors the source tree with one Markdown file per source file:

```
docs/rtl/fifo.md            docs/tb/tb_fifo.md
docs/rtl/route_compute.md   docs/tb/tb_route_compute.md
docs/rtl/noc_input_port.md  docs/tb/tb_noc_input_port.md
docs/rtl/arbiter.md         docs/tb/tb_arbiter.md
docs/rtl/crossbar.md        docs/tb/tb_crossbar.md
docs/rtl/noc_output_port.md docs/tb/tb_noc_output_port.md
docs/rtl/router_top.md      docs/tb/tb_router_top.md
docs/rtl/noc_mesh.md        docs/tb/tb_noc_mesh.md
docs/Makefile.md            docs/tb/tb_router_chain.md
                            docs/tb/mock_arbiter.md
                            docs/tb/noc_tb_pkg.md
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

`docs/images/` holds figures. The router block diagram under
[Router Microarchitecture](#router-microarchitecture) is hand-written SVG
rather than a bitmap, so it stays crisp at any zoom and can be edited in the
same commit as the RTL it describes.

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

Run one mesh geometry:

```bash
make TOP=noc_mesh sim ROWS=3 COLS=3
```

Run everything:

```bash
make regress
```

`regress` has four phases and exits non-zero if any run fails:

1. every bench at default parameters (9 runs)
2. lint, one RTL module per top, full `-Wall` (8 runs)
3. the `NUM_VC` 2/8 and `FIFO_DEPTH` 4/8 parameter matrix (24 runs)
4. four mesh geometries — 1x2, 2x1, 3x3, 2x3 (4 runs)

45 runs in total, about twelve minutes here. `1x1` is deliberately not among
them: a single tile has no legal neighbour pair to send to, so `tb_noc_mesh`
rejects it at time 0 with the XY-table message instead.

A single parameter is overridden with `GFLAGS`, for example
`make TOP=router_top sim GFLAGS='-GNUM_VC=2'`.

The same nine benches run individually:

```bash
for t in fifo route_compute noc_input_port arbiter crossbar noc_output_port \
         router_top router_chain noc_mesh; do make TOP=$t sim; done
```

`tb_router_top` and `tb_router_chain` take a few seconds; the rest are
effectively instant. A run reports `ALL <n> CHECKS PASSED` (or
`ALL TESTS PASSED`, which is what `tb_fifo` and `tb_noc_input_port` print)
or lists `[FAIL]` lines and returns non-zero on failure.

The bench for a top `X` is `tb/tb_X.sv` and its top module is `tb_X`. Any
file in `tb/` that is *not* named `tb_*.sv` is a support module and is
compiled with whichever bench is selected. The one thing the Makefile does
by hand rather than by `wildcard` is ordering: `tb/noc_tb_pkg.sv` is forced
to the head of the list, because a package has to exist before anything can
import it and `wildcard` returns names in whatever order the filesystem
happens to use.

---

## Linting

```bash
make TOP=<module> lint
```

Lint runs the whole RTL set against one module as top, with `--lint-only`,
full `-Wall`, and **no waivers** — `-Wno-BLKSEQ` and `-Wno-WIDTHEXPAND`, which
`sim` applies because benches trip them on correct code, are absent here.
`--assert` is passed for the same reason it is in `sim`: without it Verilator
parses `assert property` and drops it silently. `make regress` lints all
eight RTL modules this way.

---

## Deeper verification

Deliberately **not** folded into `make regress`: each of these rewrites RTL
source in place to prove a check can genuinely fail, then restores it. They
are slow and they touch the tree, so they stay separate invocations.

```bash
bash tools/assert_neg.sh    # 7 cases -- the assertion must FIRE
bash tools/mutate_all.sh    # 6 mutants -- the bench must catch them
bash tools/mutate_out.sh    # 2 mutants -- the output-port merge, in isolation
```

`assert_neg.sh` builds **with** `--assert` and greps for the exact `$error`
text of the property under test, one case per family of assertion in the RTL
(static parameter checks, leaf-module clocking SVA, top-level seam SVA). It
answers a different question from mutation: not "does the bench catch a bad
design" but "does this property actually fire when it is violated", which is
what stops an assertion from being decorative.

The two mutation suites build `tb_router_top` **without** `--assert`, so a
kill belongs to the bench rather than to the SVA, and print a lowercase
`killed` line with the failure tally.

Every script backs up and restores its file. After a run,
`git status --porcelain rtl/` must show only your own real edits — if it does
not, a script was interrupted mid-mutation.

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

**A bench reads a flit's fields through the package, never as a bit slice.**
`tb/noc_tb_pkg.sv` is the only file that knows where the header fields are:
it owns `FLIT_W`, `ROUTE_MASK`, the flit-type and KIND codes, and the
accessors (`flit_route()`, `flit_kind()`, `flit_tag()`, ...). Seven of the
nine benches import it and build, drive and compare flits entirely in those
terms. The failure this prevents is the quiet kind — move a field and a
bench that hard-coded `[13:10]` still compiles and still checks the wrong
bits. `tb_fifo` and `tb_route_compute` deliberately do *not* import it:
neither ever looks inside a flit (a FIFO is width-agnostic, `route_compute`
works on coordinates), so a second, unused view of the format would only be
something to keep in sync.

Related, and the other direction of the same idea: a *module* bench may read
its own DUT's internals — `tb_arbiter` reads `u_arb.credit_count` directly,
because that state has no port — but a *system* bench does not.
`tb_noc_mesh` drives and observes nothing but injection, ejection and the
two halves of the LOCAL credit loop, and reaches into no tile at all; every
inter-router wire in the mesh is `noc_mesh`'s business, which is the whole
point of testing it.

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
exit, called from the `initial`-block coroutine. Both `work_pending()`
helpers — `tb_router_chain.sv`'s and `tb_noc_mesh.sv`'s — are written to
avoid it: a `$size()` read and two counters, with no loop and no early exit
anywhere in them, and the end-of-test aggregates are counted as things
happen rather than by walking a queue at the end. If you add a helper that
both loops over a queue and returns early, check the generated
`obj_dir/<top>/*.cpp` for a `__Vtemp = ((IData)(1U) + i)` sitting *above*
the `while` — that is the bug.

---

## Vision

The goal of this project is to build a reusable Network-on-Chip IP that can be integrated into a wide range of FPGA and ASIC designs.

Long term, this repository will become the communication subsystem of the Linnea multicore SoC while remaining fully usable as an independent project.

---

## License

Released under the MIT License.
