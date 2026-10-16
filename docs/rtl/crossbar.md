# `crossbar` — `rtl/crossbar.sv`

Five independent 5:1 muxes for the flit payload, plus a second, narrower
set for the 4-bit lookahead route. No state, no credit knowledge, no clocked
process: the arbiter decides *who* switches, this decides *what they carry*.

Splitting that decision into its own module is a verification boundary as
much as an RTL one — it is what lets `rtl/arbiter.md` be verified without
modelling full-width payloads (spec §5, seam 6).

---

## 1. Ports and state

### 1.1 Parameters

| Name | Type | Default | Meaning |
|---|---|---|---|
| `NUM_PORTS` | `int` | 5 | Number of simultaneous inputs and outputs. Fixed at 5 for a single router (LOCAL, NORTH, EAST, WEST, SOUTH); the parameter exists so the port count is stated once, not so the block is reconfigurable. |
| `FLIT_W` | `int` | 40 | Width of one flit, and therefore of the payload path. Everything the router reads from a flit is in the low 14 bits, so this only widens the muxed data — no slice in this module depends on the absolute width. |

### 1.2 Port declaration

Direction is from the DUT's point of view: `input` = driven by
`noc_input_port` (datapath) or `arbiter` (control), `output` = consumed by
`noc_output_port`.

| Signal | Width | Direction | Source → Destination | Working / description |
|---|---|---|---|---|
| `clk` | 1 | input | clock generator → the three `assert property` blocks | **Not used by any datapath logic.** It exists only so the assertions at the bottom have an event to sample on, and so this module's port list has the same shape as every other router block. |
| `rst_n` | 1 | input | reset generator → `disable iff` on the assertions | Synchronous, active low, matching `fifo.sv`. Also assertion-only here. |
| `xbar_in_data` | `NUM_PORTS × FLIT_W` (40) | input | each `noc_input_port`'s post-VC-mux datapath → the 5:1 payload mux | One flit per input port, already resolved by that port's own VC mux (driven by `sa_pick`). The crossbar never looks at a VC index. |
| `xbar_in_route_next` | `NUM_PORTS × 4` | input | each `noc_input_port`'s captured lookahead → the 5:1 route mux | The 4-bit `route_next` travelling alongside each candidate flit, to be merged into the header by `noc_output_port`. |
| `xbar_sel` | `NUM_PORTS × 3` | input | `arbiter` (SA stage 2 output, one-hot over `s1_valid`) → mux select and the tracking assertion | `xbar_sel[o]` is the **input port index** whose flit leaves through output `o`. 3 bits wide because it counts input ports `0..4`; only values `< NUM_PORTS` are reachable, and the guard in §2.2 keeps a larger value defined. |
| `st_valid` | `NUM_PORTS` | input | `arbiter` → mux gating, `noc_output_port` (link register enable), the idle-output assertion | `st_valid[o]` says whether *any* flit leaves through output `o` this cycle. Also drives the arbiter's credit decrement, so it is the single "a flit is moving" indication for output `o`. |
| `xbar_out_data` | `NUM_PORTS × FLIT_W` (40) | output | `crossbar` → `noc_output_port` (registered onto the link) | Payload leaving through each output port, or `FLIT_W'(0)` when that output is idle. |
| `xbar_out_route_next` | `NUM_PORTS × 4` | output | `crossbar` → `noc_output_port`'s header merge | Lookahead route for each output, or `4'b0` when idle. Merged into bits `[13:10]` of a HEAD only. |

The two output arrays are deliberately **not** packed into one field: they
have different widths (`FLIT_W` and 4) and different consumers (link register vs.
header merge), and a single packed value would have to be sliced apart again
at every use.

### 1.3 Registers and state

| Name | Width | Kind | Reset | Working / description |
|---|---|---|---|---|
| `d` | `FLIT_W` (40) | `logic` (block-local scratch) | n/a | Selected input port's payload, assigned on **both** arms of the guard so no path can infer a latch. |
| `r` | 4 | `logic` (block-local scratch) | n/a | Same port's lookahead route, same discipline. |

That is the entire state. There is no flop, no memory, no register, and no
reset value — `clk` and `rst_n` are carried for the assertions and for port
list uniformity only.

---

## 2. RTL explanation

### 2.1 One `always_comb`, not two (lines 109–133)

Both muxes live in a single `mux5` block. They are two views of one
selection, so gating them in one place is the only way they cannot drift
apart — the failure mode the tracking assertion in §2.3 exists to catch.

Inside the loop:

```systemverilog
d = '0;
r = '0;
if (st_valid[o] && (xbar_sel[o] < 3'(NUM_PORTS))) begin
  d = xbar_in_data[xbar_sel[o]];
  r = xbar_in_route_next[xbar_sel[o]];
end
xbar_out_data[o]       = d;
xbar_out_route_next[o] = r;
```

The loop index is a plain `int` used as an array index rather than a
generate block, because `xbar_sel` is a *runtime* value from SA stage 2 and
a generate can only express compile-time choices.

### 2.2 The zero-when-idle rule (spec §4.4)

The defaults `xbar_out_data = '0; xbar_out_route_next = '0;` are assigned
**first, unconditionally**, before the loop, and the per-output result is
written from the scratch variables rather than by reading back the previous
value. Two reasons:

- **Functionally**, an idle output must read zero, not hold its last
  selection. A held value three modules downstream is indistinguishable from
  a real flit that happened to repeat: `noc_output_port` would load a stale
  payload into the link register on a cycle where `flit_valid` is low, and
  the only thing keeping the link quiet would be that one bit. Zeroing makes
  "no grant" and "grant of an all-zero payload" observably different at the
  port boundary. Because the mux is combinational, the cost is zero.
- **Structurally**, assigning the default before the loop (rather than after
  reading the old value) is the difference between a clean combinational
  block and an inferred latch.

The `xbar_sel[o] < 3'(NUM_PORTS)` term in the guard is the second half of
the range check: `xbar_sel` is 3 bits and can represent 0..7, but only
0..4 index a real entry. The guard keeps simulation defined; the assertion
below says the guard should never have to fire.

### 2.3 Assertions — this module's half of seam 6 (lines 147–188)

The arbiter promises that `xbar_sel` names an input port SA stage 1 already
picked. That promise has to be checked *here*, where it is consumed — a
broken grant reaching the link with a plausible payload only shows up as a
protocol error in the **next** router, far from its cause.

Three properties, one per `o` in a generate over `NUM_PORTS`:

1. **Range** — `st_valid[o] |-> xbar_sel[o] < NUM_PORTS`. Makes the guard in
   §2.2 provably dead rather than silently absorbing a bug.
2. **Idle outputs are silent** — `!st_valid[o] |-> data == 0 && route == 0`.
   This is the assertion form of §2.2's zero-when-idle rule; it is checked on
   the *output*, so it also catches a future edit that removes the default
   assignment.
3. **Both muxes name the same input** —
   `(st_valid && in-range) |-> out_data == in_data[sel] && out_route == in_route[sel]`.
   Two independent equalities against the *same* `xbar_sel`, so that re-gating
   one mux with something subtly different from the other, or pointing one at
   a different register, is caught here instead of as a wrong route field in
   the following router.

All three are `|=>`-free, single-cycle implications sampled on
`posedge clk` with `disable iff (!rst_n)`.

---

## 3. Testing explanation

**Bench:** `tb/tb_crossbar.sv`, top module `tb_crossbar` (**286** checks).
**Run:** `make TOP=crossbar sim` → `ALL 286 CHECKS PASSED`.

### 3.1 An exhaustive (output, selected input) sweep

Because the block is a pure function of `(xbar_in_*, xbar_sel, st_valid)`,
the bench enumerates it rather than sampling: for every output port `o` and
every input port `i`, it drives `xbar_sel[o] = i`, `st_valid[o] = 1`, puts a
recognisable pattern on `xbar_in_data[i]` and a legal direction on
`xbar_in_route_next[i]`, and requires `xbar_out_data[o]` and
`xbar_out_route_next[o]` to equal exactly those. With `NUM_PORTS = 5` that
is 25 directed points per signal pair, plus per-port idle cases.

The patterns are chosen so that reading the *adjacent* input, or the *same*
input of a different output, produces a different value — that is what makes
the "mux reads the port next to the winner" mutation detectable rather than
merely wrong.

### 3.2 What the bench proves specifically

- **Selection correctness** — `xbar_out_data[o]` equals
  `xbar_in_data[xbar_sel[o]]` and nothing else, for all 25 pairs.
- **Route co-selection** — `xbar_out_route_next[o]` follows the *same* index.
  Checked independently of the payload so that a payload-correct but
  route-stale output is a failure.
- **Zero when idle** — with `st_valid[o] = 0` and arbitrary `xbar_sel[o]`
  (including out-of-range values), both outputs read zero. This is the check
  that would catch removal of the unconditional default assignment.
- **Out-of-range select stays defined** — `xbar_sel[o]` driven to values
  `>= NUM_PORTS` must not read past the end of the array and must not emit a
  payload.
- **No X, no latch** — outputs are checked after settling on every point; an
  inferred latch on `d`/`r` shows up as a stale value on the next point.

### 3.3 Bench mechanics

Pure combinational block, so the bench drives inputs, settles with a
`#delay`, and samples — no clocked stimulus is needed. The endpoint rule in
`README.md` applies: every DUT port endpoint must be a plain scalar or the
whole array, never an element select, or the connection freezes after time 0.

### 3.4 Assertion coverage

The three seam properties in §2.3 are exercised on every check because they
are sampled continuously while the sweep runs — the idle-output property in
particular is checked on every one of the idle cases from §3.2.

`tools/assert_neg.sh` case *"crossbar: data mux reads the port next to the
winner"* rebuilds the bench with `--assert` **on** and mutates the payload
mux to select `(xbar_sel[o] + 1) % NUM_PORTS`:

```
%Error: crossbar.sv:184: Assertion failed ... crossbar: output 0 does not track its selection (0)
%Error: rtl/crossbar.sv:184: Verilog $stop
```

That is the proof the assertion side works: with `--assert` the property
fires and the run aborts at the first violation. The same mutation run
*without* `--assert` (as `tools/mutate_all.sh` does) is caught instead by
the bench — **30/103 CHECKS FAILED** — which is why both suites exist: one
proves the benches, the other proves the assertions.

### 3.5 Mutation sanity

`tools/mutate_all.sh` targets this file once — *"crossbar: data mux reads the
port next to the winner"*, which selects `(xbar_sel[o] + 1) % NUM_PORTS`
instead of `xbar_sel[o]`. It is killed by `tb_router_top` at **30/103 CHECKS
FAILED**, the largest kill count in the suite: every routed packet takes the
wrong payload, so essentially the whole run fails. (103 rather than the clean
bench's 104 because one of its checks sits behind an `rx_n()` guard and is
never reached — see `tb_router_top.md` §3.4 for why the denominators vary.)

The header merge and link register that consume these outputs are covered by
the two mutations in `tools/mutate_out.sh`, documented in
`docs/rtl/noc_output_port.md`.
