# `tb_route_compute` - `tb/tb_route_compute.sv`

Directed-plus-exhaustive bench for the purely combinational `route_compute`
block. Because the DUT has no clock and no state, the bench is a set of
stimulus vectors with settling delays, scored against a reference model that
is an *independent reimplementation* of XY-DOR rather than a call into the
DUT's own `compute_dir` - so the comparison checks the RTL against the spec,
not against itself. It runs 26 named directed checks and then sweeps the
whole 3-bit coordinate space (8 × 8 positions × both port types × every legal
`route_in` code) for **49,178 checks in total**, all against the same
reference functions.

---

## 1. Ports and state

### 1.1 Port declaration

The bench top has no ports; the table is the interface its DUT instances
present. Direction is from a `route_compute` instance's point of view:
`input` means the bench drives it into the DUT, `output` means the DUT drives
it out. Two named instances (`dut_relay`, `dut_local`, both at `CUR=(3,3)`)
serve the readable directed cases; 128 generate-scope instances (64 positions
× 2 port types, `CUR_X`/`CUR_Y` taken from the genvars) serve the sweep and
share three plain stimulus scalars.

| Signal | Width | Direction | Source → Destination | Working / description |
|---|---|---|---|---|
| `relay_dest_x`, `relay_dest_y` | 3 (`[2:0]`) | input | directed `initial` block → `dut_relay.dest_x/dest_y` | Destination coordinates of the directed cases; rewritten before each `#1`. |
| `relay_route_in` | 4 (`[3:0]`) | input | directed `initial` block → `dut_relay.route_in` | Incoming HEAD's ROUTE field; one of the five `DIR_*` codes. |
| `relay_route_self` | 4 (`[3:0]`) | output | `dut_relay` → `check()` | Expected to be an exact pass-through of `relay_route_in` (`IS_LOCAL_PORT=0`). |
| `relay_route_next` | 4 (`[3:0]`) | output | `dut_relay` → `check()` | Lookahead; compared to `ref_dir()` on the one-hop-shifted coordinates or to `DIR_LOCAL`. |
| `local_dest_x`, `local_dest_y` | 3 (`[2:0]`) | input | directed `initial` block → `dut_local.dest_x/dest_y` | Destination for the Local-port directed cases. |
| `local_route_in` | 4 (`[3:0]`) | input | directed `initial` block → `dut_local.route_in` | Held at `4'bxxxx`; structurally unused when `IS_LOCAL_PORT=1`, and the bench says so explicitly (see §3.4). |
| `local_route_self` | 4 (`[3:0]`) | output | `dut_local` → `check()` | Must be *computed* from `(CUR, dest)`, never read from `route_in`. |
| `local_route_next` | 4 (`[3:0]`) | output | `dut_local` → `check()` | Lookahead from the downstream coordinates, or forced `DIR_LOCAL`. |
| `sw_dest_x`, `sw_dest_y` | 3 (`[2:0]`) | input | sweep loops → all 128 sweep instances | Shared stimulus: `CUR_X`/`CUR_Y` are elaboration parameters, so every sweep instance wants the same inputs - one write per vector, not 64. |
| `sw_route_in` | 4 (`[3:0]`) | input | sweep loops → all 128 sweep instances | `4'bxxxx` for the LOCAL phase, one of the five `DIR_*` codes for the RELAY phase. |
| `sw_r_self`, `sw_r_next` | `[SWEEP_INST-1:0][3:0]` (64 × 4) | output | 64 relay instances → `cmp_sweep()` | Folded by continuous assigns with a constant genvar index out of each instance's plain scalar `r_self_i`/`r_next_i`; indexed `[cx*SWEEP_N + cy]`. |
| `sw_l_self`, `sw_l_next` | `[SWEEP_INST-1:0][3:0]` (64 × 4) | output | 64 local instances → `cmp_sweep()` | Same folding for the LOCAL instances (`l_self_i`/`l_next_i`). |

### 1.2 Parameters, functions and state

| Name | Width | Kind | Reset | Working / description |
|---|---|---|---|---|
| `DIR_LOCAL`, `DIR_NORTH`, `DIR_EAST`, `DIR_WEST`, `DIR_SOUTH` | 4 | `localparam logic [3:0]` | - | One-hot direction codes (`0000`, `0001`, `0010`, `0100`, `1000`), mirroring the DUT's own encoding so expectations read as directions. |
| `SWEEP_N` | 8 | `localparam int` | - | Side of the coordinate space: 3-bit coordinates give 0..7. |
| `SWEEP_INST` | 64 | `localparam int` | - | `SWEEP_N * SWEEP_N` - one sweep instance per `CUR` point, hence the response-bus width. |
| `errors` | 32-bit `int` | counter | 0 | Incremented by `check()` and `cmp_sweep()` on any mismatch. |
| `checks` | 32-bit `int` | counter | 0 | Incremented by both check tasks; the reported total (26 directed + 49,152 sweep). |
| `ref_dir` | 3-bit in / 4-bit out | `function` | - | Independent XY-DOR: X first (`tx > cx` → EAST else WEST), then Y with **Y growing downward** (`ty > cy` → SOUTH else NORTH), else LOCAL. |
| `step_x`, `step_y` | 3-bit in / 3-bit out | `function` | - | Walk one hop along a direction; mirrors the DUT's step 2 (downstream coordinates). |
| `ref_next` | 4-bit out | `function` | - | Expected lookahead: forced `DIR_LOCAL` when `self == DIR_LOCAL`, otherwise `ref_dir()` evaluated one hop along `self`. |
| `dir_of` | int in / 4-bit out | `function` | - | Sweep index 0..4 → `LOCAL/NORTH/EAST/WEST/SOUTH`; enumerates the five legal `route_in` values. |
| `relay_dest_x/y`, `relay_route_in` | 3 / 4 | `logic` (bench-driven) | - | Directed-case stimulus for `dut_relay`. |
| `relay_route_self`, `relay_route_next` | 4 | `logic` (DUT-driven) | - | Read only by `check()`. |
| `local_dest_x/y`, `local_route_in` | 3 / 4 | `logic` (bench-driven) | - | Directed-case stimulus for `dut_local`; `local_route_in = 4'bxxxx` is set once at the top of the `initial` block. |
| `local_route_self`, `local_route_next` | 4 | `logic` (DUT-driven) | - | Read only by `check()`. |
| `sw_dest_x/y`, `sw_route_in` | 3 / 4 | `logic` (bench-driven) | - | Shared sweep stimulus. |
| `sw_r_self/r_next`, `sw_l_self/l_next` | `[63:0][3:0]` | packed vector (`logic`) | - | Response buses, filled by the four continuous assigns inside the generate loop. |
| `gx`, `gy` | - | `genvar` | - | Elaboration constants for the 8 × 8 instance grid; only ever used as constant indices. |
| `r_self_i`, `r_next_i`, `l_self_i`, `l_next_i` | 4 | `logic` (per generate scope) | - | The plain scalars that sit directly on each sweep instance's ports - required by the wiring rule in §2.3. |
| `ri`, `es`, `en` | 4 | task local (`run_sweep`) | - | Current `route_in` code and the two expected values for one comparison. |
| relay/local directed scalars | - | task/initial locals (`H`-style one-shot vectors) | - | Each directed case rewrites its instance's inputs in place; nothing persists between cases except `local_route_in`. |

There is **no clock and no reset** anywhere in this bench - the DUT is pure
combinational logic, so "time" here is only the `#1` settling delay between a
stimulus write and the reads that follow it.

---

## 2. RTL explanation

### 2.1 No clock, drive-then-settle

`route_compute` never latches anything, so the bench has no clock generator
and no reset task. Every case follows the same shape: write the stimulus
signals, advance `#1` (1 ns, one time unit in the `1ns / 1ps` timescale), then
read the outputs. The delay exists purely so the `always_comb` chain in the
DUT - `route_self_c`, the `next_x/next_y` step, the `route_next` mux - has
settled before the comparison; without it the reads would race the updates in
the same time slot.

### 2.2 Instance topology: two readable + 128 exhaustive

The instance declarations build the two instances the directed cases use, both parameterized
`CUR_X(3'd3), CUR_Y(3'd3)` - one with `IS_LOCAL_PORT(0)` (relay) and one with
`IS_LOCAL_PORT(1)` (local) - so a fixed, human-checkable coordinate. Lines
147–188 build the sweep grid: a nested `generate for` over `gx`/`gy` (0..7)
instantiating **both** port types per position with `.CUR_X(3'(gx))`,
`.CUR_Y(3'(gy))`, giving 128 instances that between them cover every
`(CUR, dest, route_in)` triple the hardware can ever see.

### 2.3 Sweep connections

Shared scalar destination and route signals drive the sweep instances. Each
instance drives generate-local response signals, which constant-index
assignments collect into the response buses. The checker reads those buses
using the current coordinate index.

### 2.4 The reference model: an independent XY-DOR

`ref_dir` is a from-scratch reimplementation of the routing
spec - X corrected before Y, Y increasing downward so a larger target Y is
SOUTH, LOCAL when both coordinates already match. `ref_next`
adds the two rules that make the lookahead interesting: if the packet
terminates here the next hop does not exist, so the expected value is *forced*
`DIR_LOCAL` instead of a `compute_dir` result on meaningless coordinates;
otherwise it steps one hop with `step_x`/`step_y` and calls `ref_dir` from the
downstream router's position. None of these functions ever call into the DUT
- the file header calls this out as the point of the bench.

### 2.5 The two check tasks

```systemverilog
task automatic check(input string what, input logic [3:0] actual, input logic [3:0] expected);
  checks++;
  if (actual !== expected) begin
    errors++;
    $display("FAIL: %-24s got=%b  exp=%b", what, actual, expected);
  end else begin
    $display("PASS: %-24s got=%b", what, actual);
  end
endtask
```

Used by the directed cases (26 calls): every result is printed, so the log
shows exactly which named case produced which value, and the comparison is
`!==` so a 4-state mismatch is caught even where the engine is 2-state.
`cmp_sweep` is the quiet sibling for the sweep: identical
bookkeeping (`checks++`, `errors++` on mismatch) but it prints **only
failures**, annotated with `CUR`, `dest` and `route_in` - ~49k passing lines
would be a log nobody reads, while a single failing line carries everything
needed to reproduce it. Both feed the same two counters, so the one summary at
the end covers directed and sweep alike.

### 2.6 The sweep itself

`run_sweep()` runs two phases, each written as *write stimulus → `#1` → read
all 64 positions* so there is one delay per vector, not per comparison:

- **LOCAL phase** - for each of the 64 destinations, `sw_route_in` is driven
  to `4'bxxxx` (must be ignored entirely) and, after the settle, all 64 `CUR`
  points are compared against `ref_dir` (route_self) and `ref_next`
  (route_next): 64 × 64 × 2 = **8,192** checks. An instance that wrongly read
  `route_in` would return LOCAL for a destination that is not `CUR` and fail -
  with the caveat that under Verilator's 2-state engine `4'bxxxx` folds to
  `4'b0000`, so this particular poison is a forward-looking check.
- **RELAY phase** - for each of the five `route_in` codes (`dir_of(0..4)`,
  including `DIR_LOCAL`, the "arrives already terminating" edge case), the same
  64 × 64 sweep, this time expecting `route_self == route_in` (pure
  pass-through) and `route_next == ref_next(...)`: 5 × 64 × 64 × 2 =
  **40,960** checks.

Total sweep **49,152**; plus the 26 directed checks already counted, the
final total is 49,178. The `--- Exhaustive sweep over a 8 x 8 coordinate
space ---` banner and the trailing `sweep complete: 49178 comparisons` line
(printing the cumulative counter, directed checks included) frame the phase.

### 2.7 Report and waveform

The summary prints `ALL %0d CHECKS PASSED` when `errors == 0`, otherwise
`%0d / %0d CHECKS FAILED`, between separators, then `$finish`. A separate
`initial` dumps `sim/route_compute.vcd` for the whole hierarchy so
`make TOP=route_compute wave` works. There is no timeout - nothing in the
bench blocks on an event that could fail to arrive.

---

## 3. Testing explanation

**Bench:** `tb/tb_route_compute.sv`, top module `tb_route_compute`.
**Run:** `make TOP=route_compute sim` - final report:

```
----------------------------------------
ALL 49178 CHECKS PASSED
----------------------------------------
```

### 3.1 The directed cases, in source order

Each case writes its stimulus, settles `#1`, and checks both outputs - 2
checks per case, **26** in total.

| Case | Property it targets | Checks |
|---|---|---|
| `relay1` | EAST relay with the destination 2 hops east: `route_self` passes `DIR_EAST` through, `route_next` recomputed from the downstream router. | 2 |
| `relay2` | Destination exactly one hop east: the downstream router *is* the destination, so `route_next` must be `DIR_LOCAL`. | 2 |
| `relay3` | X corrects the next hop, Y still outstanding: `route_next == DIR_SOUTH` after an EAST hop toward `(4,5)`. | 2 |
| `relay4` | WEST relay. | 2 |
| `relay5` | NORTH relay. | 2 |
| `relay6` | SOUTH relay. | 2 |
| `relay7` | **Edge case:** `route_in == DIR_LOCAL` - the packet is already terminating on arrival, so `route_next` must be forced `LOCAL`, not derived from `compute_dir` on meaningless next-hop coordinates. | 2 |
| `local1` | Injection with the destination 2 hops east: `route_self` and `route_next` both computed. | 2 |
| `local2` | Injection one hop east: `route_self == DIR_EAST`, `route_next == DIR_LOCAL`. | 2 |
| `local3` | X already correct at injection: `route_self == DIR_SOUTH`, lookahead from `(3,4)`. | 2 |
| `local4` | **Edge case:** inject-to-self (a HEAD_TAIL doorbell to the local PE): `route_self` resolves LOCAL on the first call, `route_next` forced LOCAL *without* a second call. | 2 |
| `local5` | Injection WEST. | 2 |
| `local6` | Injection NORTH. | 2 |
| | **Directed subtotal** | **26** |

Several expectations are written as `ref_dir(3'd4, 3'd3, …)`-style calls
rather than literals, so the *same* reference model that the sweep uses also
annotates the directed cases - there is no second, subtly different
expectation to drift.

### 3.2 The exhaustive sweep

`run_sweep()` contributes the remaining **49,152** checks (8,192 LOCAL +
40,960 RELAY, broken down in §2.6), covering every `(CUR, dest)` pair in the
3-bit coordinate space for both port types, and all five `route_in` codes for
the relay type. Its results are silent unless they fail, so a zero-failure log
shows the 26 directed `PASS:` lines, the `--- Exhaustive sweep ...` banner, the
`sweep complete: 49178 comparisons` line, and then the summary - no line per
comparison.

### 3.3 Assertion coverage

`rtl/route_compute.sv` contains **no assertions at all** - no `assert
property`, no immediate `assert`, no `cover`. Every one of the 49,178 checks
is bench-side, which is the reason this bench is exhaustive: with no SVA to
backstop the module, the sweep *is* the verification. The build still passes
`--assert` (the Makefile flag is global), but for this file it has nothing to
enable.

The one mutation case naming this file - `route_compute: XY direction
inverted` in `tools/mutate_all.sh` - is evaluated by that script against
`tb_router_top` (built without `--assert`), not against this bench; this
bench's own evidence is the 49,178 comparisons above, and the reference model
being independent of `compute_dir` is precisely what makes an inverted
comparison fail here.

### 3.4 Two-state caveat

The engine is Verilator (2-state), so `4'bxxxx` driven on `local_route_in`
and `sw_route_in` folds to `4'b0000`. The bench keeps those assignments
anyway - they document the intent (`IS_LOCAL_PORT=1` must never read
`route_in`) and become real checks the moment the design moves to a 4-state
simulator, exactly as the source comment at The implementation says.
