# `tb_crossbar` — `tb/tb_crossbar.sv`

Bench for `rtl/crossbar.sv`: the five 5:1 payload muxes, the matching
lookahead-route muxes, and the "an idle output drives zero" rule from spec
section 4.4. The crossbar is pure combinational logic with no clocked state, so
the whole bench is a stimulus → settle → check loop; the clock exists only
because the DUT's assertions sample on it.

286 checks in five directed tests. What "correct" means at this seam is
deliberately narrower than "the arbiter is right" — the bench's header says so
and the tests are shaped by it:

1. `xbar_out_data[o]` and `xbar_out_route_next[o]` both come from the port named
   by `xbar_sel[o]`, and from the *same* port (seam 6).
2. An output with `st_valid[o]` low drives zero for both fields, even when
   `xbar_sel[o]` still points at something carrying a plausible payload.
3. Outputs are independent: one output's selection must not disturb another's.

---

## 1. Ports and state

### 1.1 Port declaration

Direction is from the DUT's point of view: `input` = the bench drives it,
`output` = the crossbar drives it and the bench samples it. The bench top has no
ports of its own, so this table is the whole interface presented to the single
`dut` instance.

| Signal | Width | Direction | Source → Destination | Working / description |
|---|---|---|---|---|
| `clk` | 1 | input | bench clock generator → DUT assertions only | No datapath logic in `crossbar` reads it; it exists so the three `assert property` families have an event to sample on, and it costs nothing on an unused combinational block. |
| `rst_n` | 1 | input | `reset_dut()` → `disable iff (!rst_n)` on every assertion | Active-low synchronous reset, held low for four posedges and released on a negedge. It gates the assertions; the mux has no state to reset. |
| `xbar_in_data` | `[NUM_PORTS-1:0][31:0]` (5×32) | input | bench stimulus → payload mux | One 32-bit flit per input port, post-VC-mux. Each port is driven with its own `pat(p)` word, different in every field of the word (§2.4). |
| `xbar_in_route_next` | `[NUM_PORTS-1:0][3:0]` (5×4) | input | bench stimulus → route mux | The per-port lookahead direction, driven as `DIR[p]` so every port carries a *different* legal direction code. |
| `xbar_sel` | `[NUM_PORTS-1:0][2:0]` (5×3) | input | bench stimulus (standing in for SA stage 2) → both muxes | Which input port each output reads. 3 bits wide because it counts ports `0..4`; the bench only ever drives in-range values `0..4`. |
| `st_valid` | `[NUM_PORTS-1:0]` (5) | input | bench stimulus (standing in for SA stage 2) → the zero-when-idle gate | Per-output "carries a flit this cycle". Everything the zero rule does is a function of this bit alone. |
| `xbar_out_data` | `[NUM_PORTS-1:0][31:0]` (5×32) | output | crossbar payload mux → bench (in the router: `noc_output_port`'s link register) | Combinational; zero whenever `st_valid[o]` is low, otherwise `xbar_in_data[xbar_sel[o]]`. |
| `xbar_out_route_next` | `[NUM_PORTS-1:0][3:0]` (5×4) | output | crossbar route mux → bench (in the router: the header merge) | The same selection as the payload, gated identically — the "same input port" property under test. |

No signal is read hierarchically: the bench compares only against values it
drove itself.

### 1.2 State, parameters and helpers

| Name | Width | Kind | Reset | Working / description |
|---|---|---|---|---|
| `NUM_PORTS` | int | `localparam` | n/a | `5` — the fixed 5×5 configuration, also passed to the DUT as a parameter. |
| `CLK_PERIOD` | realtime | `localparam` | n/a | `10ns`, halved to get the 5 ns clock phase. |
| `DIR` | 5 × 4 | `localparam` (unpacked array of `logic [3:0]`) | n/a | `'{4'b0000, 4'b0001, 4'b0010, 4'b0100, 4'b1000}` — the five legal direction codes indexed by input port. Used both to drive `xbar_in_route_next[p]` and, in the design, to name ports; keeping it here means a route expectation is a `DIR[...]` read rather than a magic literal. |
| `clk` | 1 | `variable` | initial `0` (`initial clk = 0`) | Toggled every `CLK_PERIOD/2`. |
| `rst_n` | 1 | `variable` | set `0` by `reset_dut()` before the first edge | Released on a negedge after four posedges. |
| `checks` | 32 (int) | `variable` | `0` at declaration | Incremented by every `check`; the number in the final report. |
| `errors` | 32 (int) | `variable` | `0` at declaration | Incremented on a mismatch; `0` ⇒ `ALL 286 CHECKS PASSED`. |
| `xbar_in_data` | 5×32 | array (packed) | cleared by `reset_dut()` | Stimulus state: rewritten by `drive_inputs()` in every test (and patched per-port in T5). |
| `xbar_in_route_next` | 5×4 | array (packed) | cleared by `reset_dut()` | Stimulus state: `DIR[p]` per port, patched in T5. |
| `xbar_sel` | 5×3 | array (packed) | cleared by `reset_dut()` | Stimulus state: the selection under test. |
| `st_valid` | 5 | array (packed) | cleared by `reset_dut()` | Stimulus state: the validity mask under test. |
| `xbar_out_data` | 5×32 | array (packed) | driven by DUT | Response wire, compared after every `tick()`. |
| `xbar_out_route_next` | 5×4 | array (packed) | driven by DUT | Response wire. |
| `check(what, actual, expected)` | — | `task automatic` | n/a | The single pass/fail recorder (§2.3). |
| `tick()` | — | `task automatic` | n/a | `@(negedge clk); #1;` — the timing primitive: advances one cycle and lands stimulus a half-period clear of the sampling posedge (§2.2). |
| `reset_dut()` | — | `task automatic` | n/a | Parks every input at zero, holds `rst_n` low four posedges, releases on a negedge, `#1` (§2.1). |
| `pat(p)` | 32 | `function automatic` | n/a | The stimulus generator: a payload that differs in *every* region of the word between ports (§2.4). |
| `drive_inputs()` | — | `task automatic` | n/a | Loads `pat(p)` and `DIR[p]` into all five inputs at once. |
| `other` | 32 (int) | `variable` (local to `t1_idle_zero`) | n/a | Folds "was any input word non-zero?" so T1's zero checks cannot be vacuously true. |
| `sel_of` | 5 × int | array (local to `t3_all_active`) | set to the derangement `(o+2)%5` | Remembers which input each output was pointed at so the checks read `xbar_in_data[sel_of[o]]` instead of re-deriving it. |

---

## 2. RTL explanation

### 2.1 Clock and reset (lines 74–75, 113–123)

`clk` is initialised to `0` and toggled every `CLK_PERIOD/2 = 5 ns`.
`reset_dut()` then runs the standard sequence used by both leaf benches in this
family: zero every input, `rst_n = 0`, `repeat (4) @(posedge clk)`, `@(negedge
clk)`, `rst_n = 1`, `#1`. Releasing on the negedge with a settle delay after it
means the first stimulus of the first test also lands in the low phase, a full
half-period away from any edge the assertions look at.

The reset is needed only for the assertions: `disable iff (!rst_n)` would
otherwise sample undefined pre-reset values, and the crossbar itself has nothing
to reset — its outputs are a pure function of `xbar_in_*`, `xbar_sel` and
`st_valid` in the same delta.

### 2.2 Timing convention: apply just after a negedge

The header comment states the reason:

> stimulus is applied just after a negedge so that every value is stable a full
> half-period before the posedge that the assertions look at.

`tick()` is the one primitive that implements it:

```systemverilog
task automatic tick();
  @(negedge clk);
  #1;
endtask
```

Every test is a loop of *drive → `tick()` → check*. Because the DUT is
combinational, the checks after `tick()` read the settled result of the values
driven in the same low phase — there is no "wait for the register" step, and no
`settle()` delay beyond the `#1`, since the tool evaluates the `always_comb`
before the test resumes. The `#1` also guarantees the driven values are stable
when the DUT's three assertion families sample at the following posedge, so an
assertion failure and a `FAIL:` line can never disagree about which cycle they
were looking at.

### 2.3 The `check` task (lines 96–104)

```systemverilog
task automatic check(input string what, input logic [31:0] actual,
                     input logic [31:0] expected);
  checks++;
  if (actual === expected) $display("[PASS] %-58s %h", what, actual);
  else begin
    $display("[FAIL] %-58s got %h exp %h", what, actual, expected);
    errors++;
  end
endtask
```

One recorder for the whole bench: `checks` counts every comparison, `errors`
counts mismatches, and both 4-bit `xbar_out_route_next` and 32-bit
`xbar_out_data` reach it through the same zero-extension (the Makefile waives
`WIDTHEXPAND` for bench compiles for exactly this reason). Comparison is `===`,
so the *expected* side of the comparison is the whole specification of each
check: `check("T2 out 3 sel 4 data", xbar_out_data[3], xbar_in_data[4])` says in
one line what the mux must do.

At the end of `main` the bench prints a blank line and then
`ALL %0d CHECKS PASSED` when `errors == 0`, or `%0d/%0d CHECKS FAILED`
otherwise, before `$finish`.

### 2.4 The stimulus generator, and why it looks like that (lines 129–148)

```systemverilog
function automatic logic [31:0] pat(input int p);
  logic [31:0] v;
  v          = '0;
  v[31:24]   = 8'(p + 1);        // per-port signature
  v[21:14]   = 8'(7 * p + 3);    // unrelated function of p, breaks runs
  v[13:10]   = 4'(p);            // the header's ROUTE field
  v[9:7]     = 3'(p);            // DEST_Y
  v[6:4]     = 3'((p + 1) % 8);  // DEST_X
  v[3:2]     = 2'(p % 4);        // VC_ID
  v[1:0]     = 2'b11;            // HEAD_TAIL
  return v;
endfunction
```

Every field that could be confused carries the port index, because a selection
that picks the wrong input port must not be able to match by accident: a payload
that differed only in its top byte would let a wrong-port read pass as long as
the top byte matched. `drive_inputs()` loads `pat(p)` and `DIR[p]` into all five
inputs, and T5 then deliberately *breaks* that per-port correlation between the
two fields so a cross-field mix-up stops being invisible (§3.1, T5).

Expected values are simply the driven inputs: the bench never reads a DUT
internal, so a wrong selection can only ever be caught by comparing
`xbar_out_*[o]` against `xbar_in_*[p]` for the `p` the *bench* chose.

### 2.5 What the DUT does with all this (for orientation)

The mux block in `rtl/crossbar.sv` (lines 105–129) zeroes both output arrays
unconditionally first — the classic latch-avoiding default — then, for each
output, loads `d`/`r` from `xbar_sel[o]` only when `st_valid[o] && (xbar_sel[o] <
NUM_PORTS)`. Both muxes live in one `always_comb` and are gated by the same
condition so they cannot drift apart. The assertions at the bottom of that file
are the RTL's own half of the same three rules; the bench's checks are the other
half, and they are independent: the assertions re-read the DUT's signals, the
bench compares against what it drove.

### 2.6 Waveforms

`$dumpfile`/`$dumpvars` are guarded by `if ($test$plusargs("vcd"))`, so a plain
`make TOP=crossbar sim` writes no VCD; run the built binary with the plusarg —
`./obj_dir/v_crossbar/run +vcd` — to get `sim/crossbar.vcd` for `gtkwave`.
There is no watchdog — the loop structure cannot hang, since every test is a
bounded `for`.

---

## 3. Testing explanation

**Bench:** `tb/tb_crossbar.sv`, top module `tb_crossbar` (**286** checks).
**Run:** `make TOP=crossbar sim` — reports `ALL 286 CHECKS PASSED`. Individual
results print as `[PASS] <name> <hex>` / `[FAIL] <name> got <hex> exp <hex>`;
a DUT assertion failure prints separately as a Verilator `$error` line and fails
the run without being counted in the 286.

| Test | Checks | Property it targets |
|---|---|---|
| `T1 idle output drives zero` | 11 | The zero-when-idle rule, with a non-zero payload sitting behind the selection |
| `T2 exhaustive (output, selected input) sweep` | 250 | Every (output, selected input) pair, plus the four idle outputs beside it |
| `T3 all five outputs active at once` | 10 | Output independence — no shared mux or selection register |
| `T4 one output re-selecting over time` | 7 | Re-evaluation across cycles and the drop-to-zero edge case |
| `T5 data and route_next come from the same port` | 8 | Seam 6, with the two fields deliberately de-correlated |
| **Total** | **286** | |

### 3.1 What each test asserts

- **T1 — idle output drives zero (11 checks).** All five `st_valid` bits are
  dropped *while every `xbar_sel` is deliberately pointed at a different,
  non-zero port* (`xbar_sel[o] = (o+2)%5`). Ten checks (data and route for each
  of the five outputs) require zero, and this is the check that distinguishes
  "zero because idle" from "zero because the payload happened to be zero" — the
  point of the crossbar's zero rule is that a held mux output would be
  indistinguishable three modules downstream from a real repeated flit. The
  eleventh check (`T1 stimulus really was nonzero`) ORs the input words together
  and requires a non-zero result, so the ten zero-checks cannot be satisfied by
  a bench that forgot to drive anything.

- **T2 — exhaustive sweep (250 checks).** All 5 × 5 `(output, selected input)`
  pairs, one at a time: with only `st_valid[o]` high and `xbar_sel[o] = p`, the
  bench checks `xbar_out_data[o] == xbar_in_data[p]` and
  `xbar_out_route_next[o] == {28'h0, xbar_in_route_next[p]}` (2 checks), then checks the
  other four outputs for zero, data and route (8 checks) — 10 checks per
  iteration, 25 iterations. Each iteration therefore also re-proves the gating
  rule of T1 from the opposite direction: while one output is genuinely
  carrying, the four that are not must stay silent. This is the test that would
  catch an output reading a neighbouring index.

- **T3 — all five outputs active at once (10 checks).** Every output valid,
  each pointed at a different input by the derangement `sel_of[o] = (o+2)%5`, so
  no output selects the index that matches its own (which would hide an input/
  output mix-up). Two checks per output against `xbar_in_data[sel_of[o]]` and
  `xbar_in_route_next[sel_of[o]]`. This is the only test where more than one
  output changes at a time, which is what makes it the only one that can catch
  outputs sharing a mux or a selection register — in T2 at most one output ever
  moves.

- **T4 — one output re-selecting over time (7 checks).** A four-step sequence on
  output 0 alone: select input 1 (1 check), move to input 3 (2 checks), drop
  `st_valid` while the selection still points at non-zero data and require both
  fields to go to zero (2 checks), then re-enable with a third selection, input
  4 (2 checks). The idle step is the interesting one: it is where a mux output
  that holds its previous value instead of re-evaluating shows up — which is
  exactly what the zero-when-idle rule is guarding against.

- **T5 — data and route_next come from the same port (8 checks).** T2 only
  works because `pat()` makes both fields correlate with the port index — the
  header's own words: *"The default stimulus makes both fields unique per port,
  so a mismatch in either direction is caught by T2 -- but that only holds
  because the two happen to correlate."* This test de-correlates them on
  purpose, in two pairs of selections on output 0:

  - *Ports 1 and 2* (line 279): port 2's payload is overwritten with port 1's,
    so the two carry **identical data** (`0x20284a7` for both, as the run
    prints) but naturally **different** `route_next` (`DIR[1] = 1` vs
    `DIR[2] = 2`). Selecting 1 then 2 (4 checks) therefore forces the route to
    change while the data legitimately does not — here the payload check is
    blind and the route check is the discriminator.
  - *Ports 3 and 4* (lines 295–296): the mirror image. Only the `route_next`
    of port 4 is overwritten with port 3's; the payloads are left **different**,
    so the run prints `0x4060dcf` (port 3) and `0x507d253` (port 4) while both
    routes read `4`. Selecting 3 then 4 (4 checks) forces the payload to change
    while the route legitimately does not — the route check is blind and the
    payload check is the discriminator.

  Between them the two pairs pin *both* muxes: in each half one field's check
  is deliberately unable to tell the two ports apart, so only the other field
  can catch a mux pointed at the wrong index, and the two halves cover
  opposite fields. Neither value can be read from the other mux's index and
  still pass.

  > This was not always true. Line 280 used to copy port 3's payload onto port
  > 4 as well, so the pair carried the **same** value in both fields and the
  > four checks could not distinguish a selection of 3 from a selection of 4 —
  > contradicting both T5's own header comment and the `T5 data now differs
  > (port 4)` check name. Deleting that one copy is what makes the stated
  > intent hold; the check count and every check name are unchanged.

  A mismatch in either field against the *selected* port is caught here in the
  de-correlated case, and by T2's exhaustive sweep in the default correlated
  one.

### 3.2 Assertion coverage in the DUT

`rtl/crossbar.sv` contains three `assert property` forms, generated once per
output (`genvar o`, 5 instances each = 15 concurrent properties), all
`@(posedge clk) disable iff (!rst_n)`:

- **`st_valid[o] |-> (xbar_sel[o] < NUM_PORTS)`** — the selection must be in
  range. Its antecedent is true throughout T2–T5 with in-range values, so the
  property is exercised but never threatened: the bench never drives
  `xbar_sel` ≥ 5, because SA stage 2 never produces such a value. The
  `xbar_sel[o] < 3'(NUM_PORTS)` guard inside the `always_comb` therefore never
  takes its false branch either — that half of the RTL is covered by lint and by
  the assertion's presence, not by this bench.
- **`!st_valid[o] |-> (data == 0 && route == 0)`** — the idle-silence rule,
  with live antecedents in T1, in every T2 iteration (four idle outputs each),
  and in T4's idle step.
- **`(st_valid && in-range) |-> (data == xbar_in_data[xbar_sel] && route ==
  xbar_in_route_next[xbar_sel])`** — the tracking property, with live antecedents
  in T2, T3, T4 and T5.

Note that the bench's checks and these properties are deliberately not the same
assertion: the checks compare against driven stimulus *procedurally* one half
period away from the edge, the properties re-sample the DUT's own wires at the
edge. A failure in either is a failure; agreement between them is what makes a
`PASS` run meaningful.

### 3.3 What this bench deliberately does not check

- **Arbitration.** Who wins is the arbiter's contract; the bench's header says
  so explicitly ("The arbiter is trusted for *which* input port wins — that is
  its own bench's job, `tb_arbiter`"). `xbar_sel` is driven as if the arbiter had
  already answered.
- **Out-of-range selections.** See §3.2 — `xbar_sel` values 5, 6, 7 are never
  driven, so the out-of-range read the guard prevents is not observed.
- **Anything about timing beyond the cycle.** The DUT is combinational, so
  "latency" is a delta; there is no pipeline state to check, and no clocked
  behaviour to soak for.

### 3.4 Negative and mutation testing

`tools/assert_neg.sh` case *"crossbar: data mux reads the port next to the
winner"* rewires the payload mux to `xbar_in_data[(xbar_sel[o]+1) % NUM_PORTS]`,
rebuilds **with** `--assert`, runs `tb_crossbar` and requires the exact text
`does not track its selection` — the tracking property above — to appear.
`tools/mutate_all.sh` applies the same mutation and judges it with
`tb_router_top` instead, built without `--assert`, so the mutation's fate there
rests on the benches alone. Either way T2 and T3 are the checks that fail first:
a payload read from the neighbouring port cannot match `xbar_in_data[p]` for any
of the 25 pairs.
