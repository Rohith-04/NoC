# `tb_arbiter` — `tb/tb_arbiter.sv`

Directed bench for `rtl/arbiter.sv` — the VA allocator, the two-stage SA and the
credit bookkeeping — with nothing else instantiated: the arbiter is a leaf, so
every request, every credit return and every observation is driven or read
directly by the bench rather than through a mock or a neighbour. It is the only
place the arbiter's *internal* state (`credit_count`, `alloc_busy`) is inspected
hierarchically, because the contract those two implement — "a row stays
reserved until its packet drains", "a credit is spent exactly once" — is not
visible on the port list except by inference.

Eighty-three procedural checks, in five directed tests taken from spec section 8
(R0, T4, T5, T6, T7), plus three families of continuous SVA that run for the
whole simulation regardless of which test is active.

---

## 1. Ports and state

### 1.1 Port declaration

Direction is from the DUT's point of view: `input` = the bench drives it,
`output` = the DUT drives it and the bench samples it. The bench top has no
ports of its own, so this table is the full interface presented to the single
`u_arb` instance — every signal wired in or out.

| Signal | Width | Direction | Source → Destination | Working / description |
|---|---|---|---|---|
| `clk` | 1 | input | bench clock generator → DUT sequential block and every `assert property` | The only sequential event in the design; the arbiter's state (pointers, counters, `alloc_busy`) commits on its rising edge. |
| `rst_n` | 1 | input | bench reset sequencer → `always_ff` | Active-low synchronous reset. Held low for three negedges at the start of `main`; clears all five credit counters to their init values, `alloc_busy` and all round-robin pointers. |
| `va_req` | `[NUM_PORTS-1:0][NUM_VC-1:0]` (5×2) | input | bench VA stimulus → VA row stage | One bit per (input port, input VC) asking for a downstream VC. Driven directly by the test, never by a real input port. |
| `va_req_out_port` | `[NUM_PORTS-1:0][NUM_VC-1:0][3:0]` (5×2×4) | input | bench VA stimulus → `dir_to_idx` inside the row stage | The one-hot direction each requester wants (`DIR_LOCAL`…`DIR_SOUTH`), which decides which row's candidate mask it lands in. |
| `va_req_single` | `[NUM_PORTS-1:0][NUM_VC-1:0]` (5×2) | input | bench VA stimulus → the HEAD_TAIL tier | `1` marks a one-flit packet, which is promoted into the single-flit tier before round-robin runs. |
| `va_gnt` | `[NUM_PORTS-1:0][NUM_VC-1:0]` (5×2) | output | VA final-grant block → bench | Combinational grant in the request cycle. Read `SETTLE` after driving. |
| `va_gnt_out_vc` | `[NUM_PORTS-1:0][NUM_VC-1:0][1:0]` (5×2×2) | output | VA final-grant block → bench | Which downstream VC (row `k`) the winner was handed. Pinned per cycle in T6. |
| `sa_req` | `[NUM_PORTS-1:0][NUM_VC-1:0]` (5×2) | input | bench SA stimulus → SA stage 1 eligibility mask | One bit per (input port, input VC) with a flit ready to switch. |
| `sa_req_out_port` | `[NUM_PORTS-1:0][NUM_VC-1:0][3:0]` (5×2×4) | input | bench SA stimulus → `dir_to_idx` in stage 1 → `s1_oport` | Target direction of the flit; converted once to an index so stage 2 can compare it against its output loop variable. |
| `sa_req_out_vc` | `[NUM_PORTS-1:0][NUM_VC-1:0][1:0]` (5×2×2) | input | bench SA stimulus → stage 1 `s1_vc` and the credit index | Downstream VC the flit will occupy; also selects which `credit_count[o][k]` gates the request. |
| `sa_req_last` | `[NUM_PORTS-1:0][NUM_VC-1:0]` (5×2) | input | bench SA stimulus → `s1_last` → `cr_release` | "This is the packet's tail", the event that releases a VA reservation. **The bench never asserts it** (see §3.3), so `cr_release` stays low throughout. |
| `sa_gnt` | `[NUM_PORTS-1:0][NUM_VC-1:0]` (5×2) | output | SA results → bench | The real grant: at most one bit set per input port, only when stage 2 picked that port. |
| `sa_pick` | `[NUM_PORTS-1:0][NUM_VC-1:0]` (5×2) | output | SA stage 1 → bench | Stage-1 pick, one-hot per port *regardless* of whether stage 2 later grants it. T4 checks pick and grant separately for exactly that reason. |
| `xbar_sel` | `[NUM_PORTS-1:0][2:0]` (5×3) | output | SA stage 2 `s2_sel` → bench | Winning input-port index for each output, `0..4`. Checked against the expected port in T4 and T5. |
| `st_valid` | `[NUM_PORTS-1:0]` (5) | output | SA stage 2 `s2_any` → bench | "Output `o` carries a flit this cycle". Read as the one-hot switching vector (`5'b00001`, `5'b00100`, …) in every test. |
| `st_out_vc` | `[NUM_PORTS-1:0][1:0]` (5×2) | output | SA results → bench | Downstream-VC sideband for each output; cleared to `0` whenever `st_valid` is low. |
| `ds_credit_valid` | `[NUM_PORTS-1:0][NUM_VC-1:0]` (5×2) | input | bench stimulus (downstream credit return) → `cr_inc` | Pulses a returned credit. Only T7 uses it: one cycle for the recovery, then held for the same-cycle +1/−1 case. |

Two DUT-internal signals are read **hierarchically** rather than wired — they are
not ports, which is why they are not in the table: `u_arb.credit_count[o][k]`
(four bits wide, `CRED_W = $clog2(max(DIR_CREDITS, LOCAL_CREDITS)+1)`) and
`u_arb.alloc_busy[o][k]`. They appear in R0, T6 and T7.

### 1.2 State, parameters and helpers

| Name | Width | Kind | Reset | Working / description |
|---|---|---|---|---|
| `NUM_PORTS` | int | `localparam` | n/a | `5` — the fixed 5×5 configuration; sizes every packed dimension above. |
| `NUM_VC` | int | `localparam` | n/a | `2` — two VCs per port, as locked by spec section 1.1. |
| `LOCAL_IDX` | int | `localparam` | n/a | `0` — the LOCAL port's index, passed to the DUT so it knows which output uses `LOCAL_CREDITS`. |
| `DIR_CREDITS` | int | `localparam` | n/a | `8` — init for every directional credit counter; deliberately equal to `noc_input_port`'s FIFO depth so the number means the same thing as in the real system. |
| `LOCAL_CREDITS` | int | `localparam` | n/a | `4` — init for `credit_count[LOCAL][*]`; the NI receive-buffer depth. |
| `P_LOCAL`…`P_SOUTH` | int | `localparam` | n/a | `0..4` — port *indices* used for every internal peek and for `xbar_sel`/`st_valid` expectations. |
| `DIR_LOCAL`…`DIR_SOUTH` | 4 each | `localparam` | n/a | The one-hot *direction codes* the bench puts on `*_req_out_port`. Kept as separate constants from `P_*` because the two encodings must never be confused. |
| `CLK_HALF` | time | `localparam` | n/a | `5` ns, so the clock period is 10 ns under `timescale 1ns/1ps`. |
| `SETTLE` | time | `localparam` | n/a | `2` ns — "long enough for the combinational path, short enough to land before the posedge". Applied after every drive (§2.2). |
| `clk` | 1 | `variable` | initial `0` | Toggled by `always #(CLK_HALF) clk = ~clk`. |
| `rst_n` | 1 | `variable` | initial `0` | Released by `main` after three negedges. |
| `checks` | 32 (int) | `variable` | `0` at declaration | Incremented by every `check` call; the numerator of the final report. |
| `errors` | 32 (int) | `variable` | `0` at declaration | Incremented only on a mismatch; `0` is what makes the summary print `ALL … PASSED`. |
| `va_req`, `va_req_out_port`, `va_req_single` | 5×2, 5×2×4, 5×2 | array (packed) | none — parked by `idle_inputs()` | VA stimulus. Cleared wholesale between tests (`va_req = '0;` etc.). |
| `sa_req`, `sa_req_out_port`, `sa_req_out_vc`, `sa_req_last` | 5×2, 5×2×4, 5×2×2, 5×2 | array (packed) | none — parked by `idle_inputs()` | SA stimulus, cleared between tests the same way. |
| `ds_credit_valid` | 5×2 | array (packed) | none — parked by `idle_inputs()` | Credit-return stimulus; only `ds_credit_valid[P_SOUTH][0]` is ever set. |
| `va_gnt`, `va_gnt_out_vc`, `sa_gnt`, `sa_pick` | 5×2, 5×2×2, 5×2, 5×2 | array (packed) | driven by DUT | Response wires the checks read after `settle()`. |
| `xbar_sel`, `st_valid`, `st_out_vc` | 5×3, 5, 5×2 | array (packed) | driven by DUT | Switch-result wires; also feed the bench's own continuous assertions. |
| `gnt_to_out` | 5 × (5×2) | array (unpacked of packed) | combinational (`always_comb`) | `gnt_to_out[o][p][v] = sa_gnt[p][v] && pidx(sa_req_out_port[p][v]) == o`. Flattens "which output does this grant target" so the per-output exclusivity property is one `$countones`, and so T5 can count grants into LOCAL directly. |
| `expect_port`, `expect_mask`, `expect_svc` | 4 each | array (locals of the `t5_seq` block) | set before the T5 loop | The four-cycle expectation table for T5 (§3.1): expected port index, expected `sa_gnt` one-hot value, expected `st_out_vc`. `got_port`, an `int` beside them, is filled from `gnt_port()` each cycle. |
| `check(what, actual, expected)` | — | `task automatic` | n/a | The single pass/fail recorder (§2.3). |
| `idle_inputs()`, `next_cycle()`, `settle()` | — | `task automatic` | n/a | The three primitives of the cycle protocol (§2.2). |
| `gnt_port()` | int | `function automatic` | n/a | Returns the index of the (first) input port holding a `sa_gnt` bit this cycle, or `-1`. Used by T5 to name the winner. |
| `pidx(dir)` | 3 | `function automatic` | n/a | Bench-local copy of the DUT's `dir_to_idx`: one-hot direction → port index, `LOCAL→0 … SOUTH→4`. Feeds `gnt_to_out`. |

---

## 2. RTL explanation

### 2.1 Clock and reset (lines 70–74, 250–257)

`clk` starts at `0` and is toggled every `CLK_HALF = 5` ns, giving a 10 ns
period; `rst_n` starts at `0`. The `main` block parks all inputs with
`idle_inputs()`, waits `repeat (3) @(negedge clk)`, releases reset, waits one
more negedge and then calls `settle()` — so the first stimulus of the first test
lands in the low phase of the first post-reset cycle, with the DUT's
combinational outputs already reflecting a fully initialised state. Everything
sequential in the arbiter is synchronous to `posedge clk` behind that reset, so
there is no async-reset release race to worry about: the release itself happens
on a negedge, half a period away from any sampling edge.

### 2.2 The cycle protocol: drive on negedge, sample before the posedge

The header comment states the rule the whole bench is built on:

> Inputs change on the falling edge and are sampled on the rising one, so a full
> cycle is: settle inputs, observe the combinational result, then let the posedge
> commit state before the next call.

Three tasks implement it:

```systemverilog
task automatic next_cycle();  @(negedge clk);  endtask   // call BEFORE driving
task automatic settle();      #SETTLE;          endtask   // call AFTER driving
```

`next_cycle()` waits for the negedge, which is *after* the posedge that committed
the previous cycle's state — so reading `credit_count` immediately after it shows
the committed value. Driving then happens in the low phase, and `settle()` waits
`SETTLE = 2` ns, which is the comment's "long enough for the combinational path,
short enough to land before the posedge": every combinational observation
(`va_gnt`, `sa_gnt`, `sa_pick`, `st_valid`, `xbar_sel`, `st_out_vc`) is taken 2 ns
after the drive and therefore 3 ns before the next rising edge, where the DUT's
and the bench's own SVA sample.

T7 makes this two-read-per-cycle discipline explicit and explains why it exists:

> Credit reads are taken immediately after `next_cycle()`, i.e. after the posedge
> that commits the previous cycle's decrement and before this cycle's own. Grant
> reads are taken after `settle()`. Keeping the two apart is the whole trick
> here: reading a counter after `settle()` shows it one decrement behind the grant
> next to it, which is an off-by-one in the bench, not in the RTL.

So the drain loop reads the counter *first* (post-commit) and the grant *second*
(post-settle), in that order, every iteration.

### 2.3 The `check` task (lines 136–146)

There is exactly one checker in this bench:

```systemverilog
task automatic check(input string what, input logic [31:0] actual,
                     input logic [31:0] expected);
  checks++;
  if (actual !== expected) begin
    errors++;
    $display("FAIL: %-46s got=%0d (0x%0h)  exp=%0d (0x%0h)",
             what, actual, actual, expected, expected);
  end else begin
    $display("PASS: %-46s %0d", what, actual);
  end
endtask
```

Every call increments `checks` unconditionally and increments `errors` only on a
mismatch, comparing with `!==` (a 4-state comparison, so an X would fail rather
than silently pass). Actuals are passed as `logic [31:0]` — the Makefile waives
`WIDTHEXPAND` for bench compiles precisely so that 1-, 2-, 4-, 5- and 10-bit
values can all be funnelled into this one task with an implicit zero-extension
that the caller means. Two consequences matter: the pass/fail decision lives in
exactly one place, and the printed name is the *entire* expected-value
documentation — `PASS: T5 c3 granted VC 2` is the record that cycle 3 of T5 had
to grant NORTH's VC1.

At the end of `main` (lines 534–540) the bench prints a dashed rule, then
`ALL %0d CHECKS PASSED` when `errors == 0`, otherwise
`%0d / %0d CHECKS FAILED`, then `$finish`.

### 2.4 How the expected values are produced

There is no executable reference model in this bench — the arbiter's answer
depends on a round-robin history that would be tedious and self-defeating to
re-implement (a copy of the RTL's own pointer logic would catch nothing).
Instead the expectations are **hand-derived and written literally into each
`check` call**, cycle by cycle, with the reasoning sitting in the comment block
above each test. Three sources feed them:

- **The DUT's own state, read hierarchically** — `u_arb.credit_count` and
  `u_arb.alloc_busy`. These are the reference for R0's init values and for T7's
  arithmetic; the bench asserts the *number* rather than inferring it from grant
  behaviour.
- **A hand-derived sequence table** — T5's four-row expectation
  (`NORTH VC0 → EAST VC0 → NORTH VC1 → EAST VC1`) is spelled out in a comment as
  `cycle / port / vc / why` before the loop that checks it, so a failure names
  the exact step of the fairness contract that broke.
- **Structural invariants expressed as SVA** — the three continuous assertion
  families below hold in *every* cycle of every test, including the idle gaps
  between tests.

### 2.5 Continuous assertions in the bench (lines 202–242)

Three `assert property` forms are generated over the port × VC space and run for
the whole simulation, `disable iff (!rst_n)`:

1. `sa_gnt[gp][gv] |-> sa_req[gp][gv]` — a grant with no request would tell an
   input port to fetch a flit it never offered.
2. `$countones(sa_gnt[gp]) <= 1` — one datapath per input port, so at most one
   VC may switch per port per cycle.
3. `$countones(gnt_to_out[go]) <= 1` — two grants into one output would be two
   flits arriving on a link that carries one per cycle. The signal it counts is
   built by the `always_comb` at lines 226–231, which flattens each grant onto
   the output named by `pidx(sa_req_out_port[p][v])` so the whole per-output
   count is a single `$countones`.

These are separate from the 83 procedural checks: they are not counted in
`checks`, and a violation shows up as a Verilator `$error` line (and a non-zero
exit) rather than as a `FAIL:` line. They exist because the directed tests only
sample selected cycles — the assertions cover the cycles in between, including
the settling cycles after stimulus is dropped.

### 2.6 Observation points and the wiring rule

Every DUT port endpoint is a whole signal declared at bench scope — never an
element select — per the README's *Testbench Wiring Rules*, because an element
select at a port endpoint freezes after time 0 and would leave the bench
comparing against a permanently stale response. That is why a simple "drive bit
`va_req[2][0]`" is written as a whole-vector assignment to `va_req` and why
`gnt_to_out` is an unpacked array of whole packed vectors rather than one flat
signal.

Responses are observed in two ways: **procedurally**, after `settle()`, for
everything combinational; and **hierarchically**, immediately after
`next_cycle()`, for the two registers (`credit_count`, `alloc_busy`) whose whole
point is that they changed at the edge just passed.

### 2.7 Watchdog and waveforms

A second `initial` block (lines 544–548) fires at `#50000` (50 µs) and prints
`ERROR: tb_arbiter timed out` before `$finish` — a hung stimulus would otherwise
run forever. A third dumps `sim/arbiter.vcd` unconditionally with
`$dumpvars(0, tb_arbiter)`, so `make TOP=arbiter wave` always has a waveform.

---

## 3. Testing explanation

**Bench:** `tb/tb_arbiter.sv`, top module `tb_arbiter` (**83** checks).
**Run:** `make TOP=arbiter sim` — reports `ALL 83 CHECKS PASSED` between two
dashed rules. Individual results print as `PASS: <name> <value>` /
`FAIL: <name> got=… exp=…`; an SVA violation in the DUT prints as a separate
`%Error`-prefixed `$error` line and fails the run even if `checks` stays clean.

Tests run in source order, each introduced by a `---- Tn … ----` banner:

| Phase | Checks | Property it targets |
|---|---|---|
| `R0 reset state` | 7 | Counters at their init values, no reservations, no spurious grants |
| `T6 VA contention` | 10 | Three requesters, two output VCs, tier priority, column drop, pointer discipline |
| `T4 two VCs, one input port` | 13 | Stage-1 collapse and rotation |
| `T5 two inputs, one output` | 24 | Stage-2 fairness as a four-cycle alternating sequence |
| `T7 credits` | 29 | Exhaustion, recovery, same-cycle +1/−1 |
| **Total** | **83** | |

### 3.1 What each test asserts

- **R0 — reset state (7 checks).** Straight out of reset:
  `credit_count[EAST][0] == DIR_CREDITS` (8), `credit_count[LOCAL][0] ==
  LOCAL_CREDITS` (4, the LOCAL/directional split is a real distinction, not one
  constant), `credit_count[SOUTH][1] == DIR_CREDITS`, `alloc_busy[LOCAL][0]`
  clear, and `va_gnt`, `sa_gnt`, `st_valid` all zero. This is the "no spurious
  grant" baseline every later test's expectations are measured against — if
  reset left a pointer or a counter wrong, T5's alternation and T7's arithmetic
  would both be off by an unknown amount.

- **T6 — VA contention (10 checks).** Three requesters (NORTH, EAST, WEST) all
  asking for LOCAL, two LOCAL output VCs available, with EAST's packet marked
  `va_req_single` (HEAD_TAIL). It asserts, cycle by cycle:
  the single tier wins (`va_gnt == 32'd16`, i.e. requester id 4 = port 2, VC 0,
  and no other requester is granted), `va_gnt_out_vc` is row 0 then row 1, the
  row the winner took becomes `alloc_busy[LOCAL][0]` and then
  `alloc_busy[LOCAL][1]` after the posedge, the *dropped* row stays
  `alloc_busy[LOCAL][1] == 0` in the first cycle, both rows reserved ⇒ no grant
  at all even though all three are still asking, and — four cycles in — that a
  dropped row did **not** advance its `rr_va` pointer (row 1 re-picks the same
  requester rather than rotating to a HEAD). That last check is the one that
  distinguishes "pointer advances on grant" from "pointer advances on
  *kept* grant".

- **T4 — two VCs on one input port (13 checks).** LOCAL VC0 → EAST and LOCAL
  VC1 → WEST, then LOCAL VC1 → EAST as well. It asserts the stage-1 pick and the
  grant agree and are one-hot (`sa_pick[P_LOCAL] == 2'b01`, then `2'b10`), that
  only the picked VC's output switches (`st_valid == 5'b00100`, then
  `5'b01000`), that `xbar_sel` of the presenting output names LOCAL (`0`), and
  that `st_out_vc` carries the downstream VC. The third cycle makes the
  "at most one grant per input port" property observable in the middle of a
  test: both VCs want EAST, yet `$countones(sa_gnt) == 1` and the pick stays
  `2'b01`. Stage 1's rotation is checked as behaviour — the pick moves to VC1
  only because VC0 *won* stage 2 in the previous cycle.

- **T5 — two inputs competing for one output (24 checks).** NORTH and EAST each
  offer both VCs into LOCAL. Fairness cannot be checked as a pointer value
  without duplicating the RTL, so it is checked as a **sequence**: four cycles
  with a pre-declared expectation table (§1.2), each cycle asserting six things —
  exactly one grant into LOCAL (`$countones(gnt_to_out[P_LOCAL]) == 1`), which
  port won (`gnt_port()`), which VC (`sa_gnt[expect_port]` against the expected
  one-hot), that LOCAL is the only switching output (`st_valid == 5'b00001`),
  that `xbar_sel[P_LOCAL]` names the winner, and that `st_out_vc[P_LOCAL]` names
  the VC actually granted. The expected alternation is
  `NORTH VC0 → EAST VC0 → NORTH VC1 → EAST VC1`: `rr2` walking forward forces
  the port alternation, and each port's own `rr1` walking forward (because it
  won) forces the VC alternation. The sideband check carries a specific warning:
  *"a mismatch here would make the downstream router buffer the flit in the
  wrong slot while the credit is decremented in the right one."*

- **T7 — credit exhaustion, recovery, same-cycle ±1 (29 checks).** Uses SOUTH,
  which no earlier test touched, so it starts from a known full `DIR_CREDITS`.
  It drains all eight credits with a persistent NORTH→SOUTH request, checking
  the counter *before* each grant and the grant *after* (16 checks, 8×2), then
  asserts the exhausted state: credit `0`, `sa_gnt == 0`, `st_valid == 0` and
  `st_out_vc[SOUTH] == 0` (the sideband must be cleared too, not merely
  masked). One credit returns (`ds_credit_valid[P_SOUTH][0]`) while the request
  is still live: the counter must still read 0 in that cycle and the grant must
  stay off — a return alone does not grant. Next cycle the counter reads 1 and
  the grant fires; the following counter read must still be 1, because the
  simultaneous +1/−1 nets to zero. The "discriminator" then drops the return and
  requires *exactly one* further grant and then a refusal: a counter that had
  applied the net as two decrements would read −1 and refuse early, one that had
  applied it twice in favour of the return would read 2 and grant a second time.

### 3.2 Coverage of the DUT's SVA families

`rtl/arbiter.sv` carries 15 `assert property` statements, expanded by its
generate loops to 150 concurrent instances: the five credit/reservation forms
each instance 5 outputs × 2 VCs = 10 times, the two `gen_sa` one-hot forms
instance once per port = 5 times, the five grant-implies forms and the two VA
forms instance 5 ports × 2 VCs = 10 times, and the kept-row form instances
5 × 2 × 2 = 20 times (5×10 + 2×5 + 7×10 + 1×20 = 150). This bench is the run
that gives all but two of them a live antecedent:

- **Credit bounds** — `credit_count <= credit_max` is checked every cycle;
  `cr_dec |-> credit_count != 0` has its antecedent true on every T4/T5/T7
  grant; the return-overflow property sees its antecedent during T7's return
  cycles.
- **SA** — one-hot `sa_pick`, at most one `sa_gnt` per port, `sa_gnt |-> sa_pick`,
  `sa_gnt |-> credit != 0` (T7 is the test that makes the zero-credit case
  meaningful), `sa_gnt |-> xy_legal` (every pair the bench drives — N/E/W→LOCAL,
  LOCAL→EAST/WEST, N→SOUTH — is one of the 16 legal pairs), and the `$onehot0`
  direction-code checks on both `sa_req_out_port` and `va_req_out_port`.
- **VA** — `va_kept <= 1` (one requester never keeps two rows), `va_gnt |->
  va_req`, and `(va_gnt && va_gnt_out_vc == k) |-> keep[target][k]`, all live
  during T6.
- **Reservation release** — `cr_release |-> alloc_busy` and
  `!(cr_release && keep)` are compiled in but **vacuous here**: see §3.3.
- The bench's own three families (§2.5) run alongside, with `sa_gnt` and
  `gnt_to_out` antecedents true throughout T4, T5 and T7.

### 3.3 What this bench deliberately does not cover

- **Reservation release.** `sa_req_last` is only ever written `1'b0`, so
  `s1_last`/`cr_release` never assert and `alloc_busy` is only ever *set* (by
  `keep`) and cleared by reset. The tail-driven release path — and with it two
  of the DUT's five credit/reservation assertions — is left to the
  port-level and top-level benches, where a real packet has a tail.
- **Illegal inputs.** No out-of-range `xbar_sel`, no non-one-hot direction code
  and no illegal XY pair is ever driven; those assertions are exercised with
  legal antecedents only. Driving an illegal pair on purpose would be testing
  `xy_legal`'s *lookup table*, which the bench's own comments treat as spec
  given.
- **Random traffic.** Everything is directed; there is no soak. The fairness
  claim rests on the four observed cycles of T5, not on a statistical sample.

### 3.4 Negative and mutation testing

`tools/assert_neg.sh` case *"arbiter: stage-1 ignores the credit pool"* drops the
credit term from the stage-1 mask (`if (sa_req[p][v] && …)` → `if (sa_req[p][v])`),
rebuilds **with** `--assert`, runs `tb_arbiter` and greps for the literal string
`arbiter:` — deliberately loose, because with the mask dropped several
properties acquire a live antecedent in the same T7 cycle: `sa_gnt … with zero
credit` (the grant stage 1 no longer refuses), `switched out … with no credit`
and then `credit_count … out of range` once the wrapped decrement commits. The
Makefile's `--assert` flag is what makes this possible at all:
without it Verilator parses the properties and silently drops them.

`tools/mutate_all.sh` judges its two arbiter mutations (*"stage-2 round-robin
ignores its pointer"*, *"stage-1 ignores the credit pool"*) with `tb_router_top`,
not with this bench, and builds those runs without `--assert`. The fairness
mutation — `rr_pick_port` searching from 0 instead of from `start` — is the one
this bench is built to kill on its own: stage 2 would still pick NORTH on the
second cycle of T5 instead of advancing to EAST, so `T5 c2 granted port` and
`T5 c2 crossbar points at the granted port` fail immediately.
