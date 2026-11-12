# `tb_noc_output_port` - `tb/tb_noc_output_port.sv`

Bench for `rtl/noc_output_port.sv`: the header merge, the link register, and
the two rules that make them correct together. One instance, plain scalar ports
throughout, 139 checks in seven directed tests.

Three things are being tested, and the header comment is explicit that two
halves of each must be checked or the test proves nothing:

1. **The merge (spec section 4.5, seam 10).** A flit arriving from the crossbar
   carries a *stale* route field - it names the exit port of the previous hop.
   This router's own lookahead route is a separate 4-bit signal that must be
   spliced into `[13:10]`, but **only** when the flit is a HEAD or a
   HEAD_TAIL, because for a BODY or a TAIL those same bits are payload. "Heads
   get the new route" alone would pass while a merge condition that had become
   "always" silently corrupts every payload flit, so the non-head case is
   checked as an explicit equality rather than left as an absence of checks.
2. **The register (the LT boundary).** `flit_valid`/`flit_data`/`vc_id` must be
   exactly one cycle behind `st_valid`/`st_out_vc` - section 3's "grant in c2,
   header on the output link in c3". A grant with no flit the next cycle, or a
   flit with no grant, are both protocol violations at the link.
3. **D3.** The in-flit KIND field `[3:2]` is never rewritten; the
   authoritative VC is the `vc_id` sideband. KIND is written once by the source
   NI and read by no router, so rewriting the in-flit field would look fine in a
   single-router test and corrupt every packet in a chain.

---

## 1. Ports and state

### 1.1 Port declaration

Direction is from the DUT's point of view: `input` = the bench drives it,
`output` = the DUT drives it and the bench samples it. The bench top has no
ports of its own, so this table is the whole interface presented to the single
`dut` instance.

| Signal | Width | Direction | Source → Destination | Working / description |
|---|---|---|---|---|
| `clk` | 1 | input | bench clock generator → link register and all eight DUT assertions | Two sampling events per `cycle()` call: the negedge the bench drives on, and the posedge that loads the register and samples the SVA (§2.2). |
| `rst_n` | 1 | input | `reset_dut()` → `link_reg` and `disable iff (!rst_n)` | Active-low synchronous reset, held low four posedges and released on a negedge. Clears `flit_data`, `flit_valid` and `vc_id` - an unreset link register would show the previous packet's value across a reset and look like a flit held forever. |
| `xbar_out_data` | `[FLIT_W-1:0]` (40) | input | bench stimulus (standing in for the crossbar) → header merge | The incoming flit. Built by `make_flit()`, or loaded with the deliberate stale value `32'hDEAD_BEEF` in T4. Valid only when `st_valid` is high - the crossbar forces zero otherwise - but the merge is applied unconditionally. |
| `xbar_out_route_next` | 4 | input | bench stimulus (the lookahead route) → header merge | This router's computed direction for the *next* hop, spliced into `[13:10]` of heads. Driven as a `DIR_*` constant in every test except T4's idle cycle, where `4'b1111` goes with the stale payload (§3.2). |
| `st_valid` | 1 | input | bench stimulus (standing in for the arbiter) → the register's gate and the assertion antecedents | "This output carries a flit this cycle." Gates the registered payload/sideband and half the assertions. |
| `st_out_vc` | `[VC_W-1:0]` (2) | input | bench stimulus → `vc_id` sideband path | Which downstream VC the flit belongs to; varied across beats in T5 and T7 so a sideband that registered once and held would be caught. |
| `flit_data` | `[FLIT_W-1:0]` (40) | output | link register → bench (in the router: the physical link) | Registered `st_valid ? merged : '0`. Exactly one cycle behind the grant. |
| `flit_valid` | 1 | output | link register → bench (downstream router's input port) | Registered `st_valid`. |
| `vc_id` | `[VC_W-1:0]` (2) | output | link register → bench (downstream FIFO demux / credit bookkeeping) | Registered `st_valid ? st_out_vc : '0`. The authoritative VC; the in-flit KIND copy is deliberately allowed to disagree. |

One DUT-internal signal is read **hierarchically**: `dut.merged`, the
combinational output of the header-merge block - always as a whole signal, never
indexed: `cycle()` compares it against the reference merge, T3 stores it in a
local and compares field by field through the package's accessors, T5 keeps the
previous beat's value of it, and T6 passes it to `flit_kind()`. That is what
lets the merge be checked *before* the register can hide a mistake inside a
one-cycle delay.

### 1.2 State, parameters and helpers

| Name | Width | Kind | Reset | Working / description |
|---|---|---|---|---|
| `CLK_PERIOD` | realtime | `localparam` | n/a | `10ns`, halved for the 5 ns clock phase. |
| `NUM_VC` | int | `parameter` | n/a | `4` - the only knob in this bench (`make regress` sweeps it to 2 and 8). Passed to the DUT as well: `noc_output_port` derives its own sideband width from it, so leaving the instance at its default would make the link-side signals a different width the moment the sweep moves. |
| `VC_W` | int | `localparam` | n/a | `(NUM_VC > 1) ? $clog2(NUM_VC) : 1` → `2` at the default. The width of `st_out_vc`/`vc_id`, derived rather than independent so the sideband can never be narrower than the index it carries. |
| `FLIT_W` | int | imported (`noc_tb_pkg`) | n/a | `40` - the one definition of the flit width. The bench does not redeclare it; it is passed to the DUT instance so bench-side signals and port are provably the same width. |
| `FLIT_BODY`, `FLIT_HEAD`, `FLIT_TAIL`, `FLIT_HEAD_TAIL` | 2 each | imported (`noc_tb_pkg`) | n/a | `00`, `01`, `10`, `11`. Bit 0 *is* `is_head`, which is the entire merge condition - these named constants are what makes that readable at the call sites. |
| `KIND_WR_REQ`, `KIND_RD_REQ`, `KIND_WR_RESP`, `KIND_RD_RESP` | 2 each | imported (`noc_tb_pkg`) | n/a | The four KIND codes the tests stamp into the in-flit field D3 protects. No test ever spells one as a literal. |
| `DIR_LOCAL`…`DIR_SOUTH` | 4 each | `localparam` (`logic [3:0]`) | n/a | `0000`, `0001`, `0010`, `0100`, `1000` - the five legal one-hot directions, Y growing downward. |
| `DIR` | 5 × 4 | `localparam` (unpacked array) | n/a | `'{DIR_LOCAL, DIR_NORTH, DIR_EAST, DIR_WEST, DIR_SOUTH}` - lets T5 walk directions as `DIR[(i+1)%5]` instead of repeating literals. |
| `ROUTE_MASK` | `[FLIT_W-1:0]` | imported (`noc_tb_pkg`) | n/a | `'h00003C00`, i.e. the route field `[13:10]`. The one field the merge is allowed to change; T3 uses its complement to assert nothing else moved. |
| `clk` | 1 | `variable` | initial `0` (`initial clk = 0`) | Toggled every `CLK_PERIOD/2`. |
| `rst_n` | 1 | `variable` | set `0` by `reset_dut()` before the first edge | Released on a negedge after four posedges, then `#1`. |
| `checks` | 32 (int) | imported (`noc_tb_pkg`) | `0` at declaration, in the package | Incremented by every `check`; the number in the final report. Not declared in this bench - the "Bookkeeping" section is only a comment saying so. |
| `errors` | 32 (int) | imported (`noc_tb_pkg`) | `0` at declaration, in the package | Incremented on a mismatch; `0` ⇒ `ALL 139 CHECKS PASSED`. |
| `xbar_out_data`, `flit_data` | `[FLIT_W-1:0]` each | `variable` | cleared by `reset_dut()` (inputs), driven by DUT (output) | The 40-bit datapath in and out of the link register. |
| `xbar_out_route_next` | 4 | `variable` | cleared by `reset_dut()` | Stimulus: the lookahead route, rewritten on every `cycle()` call. |
| `st_valid` | 1 | `variable` | cleared by `reset_dut()` | Stimulus: rewritten on every `cycle()` call. |
| `st_out_vc`, `vc_id` | `[VC_W-1:0]` each | `variable` | cleared by `reset_dut()` (input), driven by DUT (output) | The sideband in and out of the link register. |
| `flit_valid` | 1 | `variable` | driven by DUT | Response wire, read `#1` after the posedge. |
| `check(what, actual, expected)` | - | imported task (`noc_tb_pkg`) | n/a | The single pass/fail recorder (§2.3). |
| `reset_dut()` | - | `task automatic` | n/a | Zeroes all four stimulus inputs, holds `rst_n` low four posedges, releases on a negedge, `#1`. |
| `ref_merge(d, lookahead)` | `[FLIT_W-1:0]` | imported function (`noc_tb_pkg`) | n/a | **The reference model.** `if (flit_is_head(d)) return with_route(d, lookahead); return d;` - written from the spec's wording ("`is_head == type[0]`"), not from the DUT's code, so a bug in the DUT's merge condition cannot be mirrored by an identical bug in the checker (§2.4). |
| `flit_type()`, `flit_kind()`, `flit_route()`, `flit_is_head()` | 2, 2, 4, 1 | imported functions (`noc_tb_pkg`) | n/a | Field accessors: the bench reads a field back out of a word instead of indexing it, so no test names a bit position. |
| `make_flit(typ, kind, route_field, tag)` | `[FLIT_W-1:0]` | `function automatic` | n/a | **The stimulus generator.** A thin wrapper over the package's `mk_hdr`: type, KIND, route and `(tag*37)+1` go into the header the package lays out, both destination fields are left zero, and only the argument order the tests already use is fixed here. |
| `cycle(tag, d, r, v, svc)` | - | `task automatic` | n/a | One full cycle: drive, check the combinational merge, wait for the posedge, check the registered outputs. Four `check` calls per call (§2.2). |
| `typ`, `stale`, `look`, `tag` | 2, 4, 4, int | variables (locals of `t2_all_types`) | set before the loop | Per-iteration state for the four flit types; `stale = DIR_SOUTH` and `look = DIR_EAST` are deliberately different directions so a merge that did nothing would produce the stale value and fail. |
| `d`, `got`, `look` | `[FLIT_W-1:0]`, `[FLIT_W-1:0]`, 4 | variables (locals of `t3_only_route_field_changes`) | n/a | The incoming word and the read-back of `dut.merged` for the field-by-field comparison. |
| `d`, `exp_prev`, `look`, `svc`, `have_prev` | `[FLIT_W-1:0]`, `[FLIT_W-1:0]`, 4, `[VC_W-1:0]`, 1 | variables (locals of `t5_back_to_back`) | `exp_prev='0`, `have_prev=0` | The expected-value chain for the burst: `exp_prev` holds the previous beat's `dut.merged` so each beat can be required to *differ* from it. |
| `d` | `[FLIT_W-1:0]` | variable (local of `t6_kind_field_never_rewritten`) | n/a | The two disagreement flits (head whose KIND the sideband does not share; tail whose payload occupies the KIND slot). |
| `v`, `svc` | 1, `[VC_W-1:0]` | variables (locals of `t7_valid_pairs`) | n/a | The interleaved valid/sideband pattern: `v = (i%3) != 1`, `svc = VC_W'((i+1) % NUM_VC)`. |

---

## 2. RTL explanation

### 2.1 Clock and reset

`clk` starts at `0` and toggles every `CLK_PERIOD/2 = 5 ns`. `reset_dut()`
zeroes `xbar_out_data`, `xbar_out_route_next`, `st_valid` and `st_out_vc`, holds
`rst_n = 0` for `repeat (4) @(posedge clk)`, then `@(negedge clk); rst_n = 1;
#1`. Releasing in the low phase with a settle delay means the first `cycle()`
call - which itself starts at `@(negedge clk)` - begins cleanly in the following
low phase, and the register is guaranteed to have seen the reset for four full
edges before it is asked to load anything.

### 2.2 The cycle protocol: drive on negedge, check both halves

Everything in the bench funnels through one task, and the comment on it explains
why the two halves are done together:

```systemverilog
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

  // Combinational half: what the merge decided, before the register can
  // hide it behind a delay.
  check($sformatf("%s merge result", tag), dut.merged, exp_m);

  @(posedge clk);
  #1;

  // Registered half: exactly one cycle behind, exactly as selected.
  check($sformatf("%s flit_valid", tag), {31'b0, flit_valid}, {31'b0, v});
  check($sformatf("%s flit_data", tag), flit_data, v ? exp_m : 32'h0);
  check($sformatf("%s vc_id sideband", tag), {30'b0, vc_id}, v ? {30'b0, svc} : 32'h0);
endtask
```

- **Negedge, `#1`, then check the merge.** Stimulus lands in the low phase and
  is given 1 ns to propagate; `dut.merged` at that point is the *combinational*
  answer, before the register can hide a mistake behind a delay. That is why the
  only hierarchical reference in the bench is the merge net rather than the
  registered output alone.
- **Posedge, `#1`, then check the register.** The register loads at that edge,
  and the three registered checks are taken one nanosecond later - safely after
  the edge, and a full cycle before the next one. The DUT's own `|=>` assertions
  sample at this same edge, so a bench `FAIL:` and an assertion `$error` can
  never disagree about which cycle they describe.

Doing both halves in one task is deliberate: *"the merge and the register have
to agree, and a bench that checked only one of them would pass happily on a DUT
where the register captured a different word than the one the merge produced."*
The registered expectations are derived from the *reference* merge (`exp_m`),
not from `dut.merged`, so a merge bug fails both halves independently.

### 2.3 The `check` task (`tb/noc_tb_pkg.sv`)

Not declared in this bench: the `import noc_tb_pkg::*` at the top of the file
brings in `check()` together with the `checks`/`errors` counters it increments,
and the bench's "Bookkeeping" section is only a comment saying so.

```systemverilog
task automatic check(input string what, input logic [FLIT_W-1:0] actual,
                     input logic [FLIT_W-1:0] expected);
  checks++;
  if (actual !== expected) begin
    errors++;
    $display("[FAIL] %-62s got %h exp %h", what, actual, expected);
  end else begin
    $display("[PASS] %-62s %h", what, actual);
  end
endtask
```

One recorder for the whole bench - and for every other bench that imports the
package: `checks` counts every comparison, `errors` counts mismatches, and both
the 40-bit `flit_data` and the narrow arguments (`flit_valid`, `vc_id`, and the
2-/4-bit results of `flit_kind()`/`flit_route()`) reach the `FLIT_W`-wide
formals by explicit padding at the call site (`{31'b0, flit_valid}`,
`{30'b0, vc_id}`) or by zero-extension. The Makefile waives `WIDTHEXPAND` for
bench compiles because the benches deliberately pass signals of every width
into this one `FLIT_W`-wide task; the padding that is written out is what makes
a width mistake visible in the source rather than hidden inside an implicit
extension. Comparison is a 4-state
`!==`, so the *expected* side of the comparison is the whole specification of
each check: `check("T3 HEAD: route field replaced", flit_route(got), look)`
says in one line what the merge must have done.

At the end of `main` the bench prints a blank line and then
`ALL %0d CHECKS PASSED` when `errors == 0`, or `%0d/%0d CHECKS FAILED`
otherwise, before `$finish`.

### 2.4 The reference model, and why it is written twice (`tb/noc_tb_pkg.sv`)

Not in this bench either: the expected merge lives in the package, and the
bench's header quotes it in the vocabulary it is stated in.

```systemverilog
function automatic logic [FLIT_W-1:0] ref_merge(input logic [FLIT_W-1:0] d,
                                                input logic [3:0]        lookahead);
  if (flit_is_head(d)) return with_route(d, lookahead);
  return d;
endfunction
```

The DUT expresses the same rule as `if (xbar_out_data[0]) merged[13:10] =
xbar_out_route_next;` after defaulting `merged = xbar_out_data`. The reference
model is deliberately a *different* spelling of the same spec sentence - built
from the package's `flit_is_head()` predicate and `with_route()` setter rather
than from bit indices - so the two can only agree if both are right.
`flit_is_head` tests the type field's low bit - `01 HEAD` and `11 HEAD_TAIL`
set it, `00 BODY` and `10 TAIL` do not - and that single bit is the most
encoding-coupled line in the router: change the type encoding and the merge
silently starts rewriting payload.

Note that `ref_merge` is applied *unconditionally* to whatever the bench drove,
while the DUT's register additionally gates with `st_valid`. The `cycle()`
expectations reconcile the two explicitly (`v ? exp_m : 32'h0`), which is what
lets an idle cycle carry a non-zero `xbar_out_data` and still expect a zero
`flit_data`.

### 2.5 Observation of the DUT's response

Three levels, each used where it is the only thing that can see the behaviour:

- **`dut.merged` (combinational, hierarchical)** - the only way to check the
  splice itself; the register one cycle later cannot distinguish "merge was
  wrong" from "register captured the wrong word". T3 reads it back into a local
  (`got`) and compares field by field through `flit_kind()`/`flit_type()`/
  `flit_route()`; T6 passes the whole signal straight to `flit_kind()`.
- **The registered outputs (procedural, `#1` after the posedge)** - `flit_valid`
  against `st_valid`, `flit_data` against `ref_merge(...)`, `vc_id` against
  `st_out_vc`, all zero when `st_valid` was low.
- **The DUT's own eight `assert property` statements** - running at every posedge
  for the whole simulation and independent of the bench's bookkeeping (§3.2).

---

## 3. Testing explanation

**Bench:** `tb/tb_noc_output_port.sv`, top module `tb_noc_output_port`
(**139** checks).
**Run:** `make TOP=noc_output_port sim` - reports `ALL 139 CHECKS PASSED`.
Individual results print as `[PASS] <name> <hex>` / `[FAIL] <name> got <hex>
exp <hex>`; a DUT assertion failure prints separately as a Verilator `$error`
line and fails the run without being counted in the 139. There is no watchdog -
every test is a bounded loop - and the VCD is opt-in: run
`./obj_dir/v_noc_output_port/run +vcd` to get `sim/noc_output_port.vcd`.

Tests run in source order, each introduced by a `---- Tn … ----` banner. Every
`cycle()` call contributes four checks (merge result, `flit_valid`, `flit_data`,
`vc_id`), on top of which each test adds its own targeted ones:

| Test | Checks | Property it targets |
|---|---|---|
| `T1 reset clears the link register` | 3 | No stale flit across reset |
| `T2 every flit type, stale route vs lookahead` | 16 | Merge on heads, no merge on non-heads, all four types |
| `T3 only [13:10] changes` | 14 | Field-by-field preservation, incl. D3's KIND field |
| `T4 idle cycles leave the wire silent` | 12 | `st_valid` low ⇒ registered outputs zeroed |
| `T5 back-to-back, one flit per cycle` | 39 | Steady state: register updates every beat, both merge branches |
| `T6 D3: the in-flit KIND field is never rewritten` | 12 | Sideband is authoritative; the KIND slot untouched |
| `T7 flit_valid and vc_id paired with their grant` | 43 | Grant/flit pairing incl. idle cycles, sideband per beat |
| **Total** | **139** | |

### 3.1 What each test asserts

- **T1 - reset clears the link register (3 checks).** Directly out of
  `reset_dut()`: `flit_valid` low, `flit_data` zero, `vc_id` zero. An unreset
  `flit_valid` would look like a flit held across reset; an unreset `flit_data`
  would put the previous packet's payload on the wire the moment valid came
  back.

- **T2 - every flit type (16 checks).** Four `cycle()` calls, one per flit type,
  with `stale = DIR_SOUTH` in the flit and `look = DIR_EAST` as the lookahead -
  deliberately *different* directions, so a merge that did nothing would leave
  the stale value and fail. Each type is checked as a full cycle (4 × 4 checks):
  `01 HEAD` and `11 HEAD_TAIL` must show `merged[13:10] == DIR_EAST`, `00 BODY`
  and `10 TAIL` must show `[13:10]` unchanged as payload.

- **T3 - only `[13:10]` changes (14 checks).** Two cycles plus targeted checks.
  For a HEAD (`DIR_NORTH` lookahead, `DIR_SOUTH` stale): bits above the route
  field untouched (`got & ~ROUTE_MASK == d & ~ROUTE_MASK`), the KIND field
  untouched (D3, compared as `flit_kind(got)` against `flit_kind(d)`), the type
  field untouched (`flit_type`), and the route field itself replaced
  (`flit_route(got) == look`). For a TAIL: the *whole word* must be identical
  to the input and `flit_route(got)` still the payload's own value. Payloads
  are chosen so every other field is non-zero - an all-zero payload would make
  the preservation checks pass no matter what the merge did.

- **T4 - idle cycles leave the wire silent (12 checks).** An active HEAD_TAIL
  cycle (4 checks) to prove `flit_present` goes high, then an idle cycle with
  `32'hDEAD_BEEF` and `4'b1111` still sitting on the crossbar inputs: the next
  cycle's `flit_valid` must be low *and* `flit_data`/`vc_id` must be zero (3
  checks, plus the 4 from `cycle()`). Two independent things have to agree for
  the wire to be quiet - the crossbar drives zero when idle and the register
  re-zeroes it here.

- **T5 - back-to-back, one flit per cycle (39 checks).** Eight consecutive
  valid cycles: alternating HEAD and BODY, a different `look` direction every
  beat, `svc = VC_W'(i % NUM_VC)` changing every beat, and a payload that
  changes every beat (`tag*37+1`). 32 checks from the eight `cycle()` calls,
  plus seven *"beat n is not a repeat"* checks comparing `flit_data` against the
  previous beat's `dut.merged` and requiring them to differ - this is the
  steady state the credit loop is sized for (section 6), and it is where a
  register that only updated on the *rising edge* of `st_valid`, or a `vc_id`
  registered once and held, would show up as a repeat rather than as an
  inference.

- **T6 - D3 in isolation (12 checks).** A head whose header carries
  `KIND_RD_RESP` while `st_out_vc` says 0: `flit_kind(dut.merged)` must still
  read `KIND_RD_RESP`, `vc_id` must read 0, and the two are explicitly required
  to *differ* (`T6 KIND did not become the sideband VC`, expected `1'b0` for
  the equality) - that disagreement is the whole point of assumption D3. Then a
  TAIL whose payload occupies the KIND slot: `flit_kind(dut.merged)` must equal
  `flit_kind(d)`, so the slot survives as payload.

- **T7 - grant/flit pairing (43 checks).** Ten beats with `v = (i%3) != 1`
  (so idle cycles are interleaved) and `svc = VC_W'((i+1) % NUM_VC)`. The 40
  `cycle()` checks pair `flit_valid`/`flit_data`/`vc_id` with the *same* beat's
  grant; the three extra checks fire only on the idle beats (`i = 1, 4, 7`) and
  require `vc_id` to be zero - "a sideband that only updated while valid was
  high would hold its last value through an idle cycle and be compared against
  a stale expectation here".

### 3.2 Assertion coverage in the DUT

`rtl/noc_output_port.sv` contains eight `assert property` statements (no
generate - one instance each), all `@(posedge clk) disable iff (!rst_n)`. This
bench gives every one of them a live antecedent:

- **Merge family.** `route_next` must be one of the five legal one-hot
  directions while a head crosses (T2, T3, T4, T5, T6, T7 all drive legal
  `DIR_*` values with `st_valid && data[0]` true); a head's route field must be
  replaced (`merged[13:10] == xbar_out_route_next` - the assertion
  `tools/assert_neg.sh` targets); a non-head's route field must be preserved;
  the KIND field (`merged[3:2] == xbar_out_data[3:2]`) must never be touched
  (ungated, so true in every one of the 28 `cycle()` calls in the run,
  including T4's `DEAD_BEEF` cycle); everything outside `[13:10]` must survive
  (ungated, same coverage).
- **Register family.** `st_valid |=> flit_valid`, `!st_valid |=> !flit_valid`
  (live antecedents in T4 and on T7's three idle beats), and
  `st_valid |=> (flit_valid && (vc_id == $past(st_out_vc)))` - the sideband
  travels with its flit, which is T5's and T7's per-beat `svc` variation made
  into a property.

One detail worth noticing: T4's idle cycle drives `4'b1111` as
`xbar_out_route_next`, which is *not* a legal direction. It does not fire the
legality property because the antecedent requires `st_valid` - a deliberately
ungated-looking value in a cycle where the spec says outputs are don't-care,
which incidentally proves the property is correctly gated rather than merely
never threatened.

### 3.3 What this bench deliberately does not check

- **Whether the crossbar actually sends zero when idle.** T4 hands the DUT a
  non-zero stale payload precisely because that is *not* the crossbar's contract
  to keep - the register must be quiet on its own. The crossbar's own zero rule
  is `tb_crossbar`'s job (its T1).
- **Which flit *should* have been routed here.** Route computation, allocation
  and payload routing are upstream; `xbar_out_*` is taken on faith as the
  crossbar's output.
- **Anything downstream of the link.** No consumer is modelled; `vc_id` is
  checked as a value on a wire, not as a FIFO demux index in use.

### 3.4 Negative and mutation testing

`tools/assert_neg.sh` case *"noc_output_port: header merge never happens"*
replaces `if (xbar_out_data[0])` with `if (1'b0)`, rebuilds **with** `--assert`,
runs `tb_noc_output_port` and requires the exact text
`noc_output_port: HEAD route not updated` to appear. That is deterministic: T2's
HEAD cycle has `st_valid = 1` and `data[0] = 1`, so the antecedent is live and
the consequent (`merged[13:10] == route_next`) is false the moment the condition
is disabled.

`tools/mutate_all.sh` applies the sibling mutation - the merge writing a constant
`4'b0100` instead of `xbar_out_route_next` - and judges it with `tb_router_top`,
built without `--assert`, so there the bench alone must catch it; the comment in
that script says so explicitly ("Only headers may be touched and only `[13:10]`,
so this has to be caught by the bench"). Run against *this* bench, the first
failure would be T2's first HEAD `merge result` check: with the condition intact
but the splice replaced by `4'b0100` (`DIR_WEST`), that head reports `DIR_WEST`
where `ref_merge` - following the driven `DIR_EAST` lookahead - expects
`DIR_EAST`, and where the flit's own stale field said `DIR_SOUTH`: three
different values, so the check cannot be satisfied by coincidence.
