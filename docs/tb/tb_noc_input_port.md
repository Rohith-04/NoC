# `tb_noc_input_port` — `tb/tb_noc_input_port.sv`

Cycle-accurate, self-checking bench for the NoC input port, run against a
**mock arbiter** rather than the real one: a port-level test needs a grant
source it can control to the cycle, and the mock models exactly the two
behaviours the port depends on (combinational VA accept, immediate round-robin
SA pick) and nothing else. Two DUT instances run in parallel — one directional
(relay) port and one LOCAL port, both at `CUR=(3,3)` with `NUM_VC=2` — each
with its own mock, so route-from-header and route-from-destination are both
covered in one pass. The expected values are the spec's section 3 timeline
transcribed cycle for cycle, plus the mock's own grant counters as totals;
**139 checks** all pass.

---

## 1. Ports and state

### 1.1 Port declaration (the DUT interface)

The bench top has no ports; the table is what it wires to the two
`noc_input_port` instances (`u_relay` with `IS_LOCAL_PORT=0`, `u_local` with
`IS_LOCAL_PORT=1`). Direction is from the DUT's point of view: `input` means
the bench (or the mock, for the grant side) drives it into the DUT, `output`
means the DUT drives it out. Every row exists twice in the bench, under the
`r_` (relay) and `l_` (local) prefixes.

| Signal | Width | Direction | Source → Destination | Working / description |
|---|---|---|---|---|
| `clk` | 1 | input | bench clock generator → `u_relay`, `u_local` (and both mocks) | Free-running 10 ns clock; everything in the DUT updates on `posedge clk`. |
| `rst_n` | 1 | input | `do_reset()` → both DUTs and both mocks | Active-low synchronous; held low across 4 negedges, released, then one negedge + `SETTLE` before stimulus starts. |
| `flit_data` | 32 | input | `r_step()` / `l_step()` → `flit_data` | The flit on the incoming link, built by `mk_head`/`mk_payload`. Driven at the negedge and held for exactly one cycle. |
| `flit_valid` | 1 | input | `r_step()` / `l_step()` → `flit_valid` | Link-level qualifier; `r_idle()`/`l_idle()` drive it 0 for an empty cycle. |
| `vc_id` | 2 | input | `r_step()` / `l_step()` → `vc_id` | Sideband VC selector — decides which per-VC FIFO receives the flit. Driven as `2'd0`/`2'd1`; the VC_ID field *inside* the flit is ignored by the DUT (assumption D3). |
| `credit_return_valid` | `NUM_VC-1:0` (2) | output | DUT → `r_credit` / `l_credit` → checks | Registered from `fetch`: one bit per VC, asserted the cycle after that VC's fetch freed a slot. Sampled every cycle; accumulated in C1. |
| `req_va` | `NUM_VC-1:0` (2) | output | DUT → mock + checks | "HEAD active, needs a downstream VC". Checked per VC per cycle against the timeline. |
| `va_req_out_port` | `[3:0]` × `NUM_VC` (unpacked) | output | DUT → checks | Output port requested at VA: **live** `route_compute` value in the arrival cycle, the latched `out_port` afterwards. The heart of R1. |
| `va_req_single` | `NUM_VC-1:0` (2) | output | DUT → checks | Single-flit (HEAD_TAIL) tier bit for the allocator. |
| `va_gnt` | `NUM_VC-1:0` (2) | input | mock → `always_comb` copy → DUT | Mock accepts VA combinationally in the request cycle. |
| `va_gnt_out_vc` | `[1:0]` × `NUM_VC` (unpacked) | input | mock → `always_comb` copy → DUT | Downstream VC assigned; the mock's per-input-VC round-robin pointer, so `out_vc` capture sees more than one value. |
| `req_sa` | `NUM_VC-1:0` (2) | output | DUT → mock + checks | "Active flit and owns a downstream VC". |
| `sa_req_out_port` | `[3:0]` × `NUM_VC` (unpacked) | output | DUT → checks | Latched `out_port`, stable for the packet. |
| `sa_req_out_vc` | `[1:0]` × `NUM_VC` (unpacked) | output | DUT → checks | Target downstream VC (credit-mask index); checked against the mock's round-robin sequence. |
| `sa_req_last` | `NUM_VC-1:0` (2) | output | DUT → checks | Level, high while the packet's last flit sits at the head. |
| `sa_gnt` | `NUM_VC-1:0` (2) | input | mock → `always_comb` copy → DUT | Immediate round-robin grant across this port's requesting VCs. |
| `sa_pick` | `NUM_VC-1:0` (2) | input | mock → `always_comb` copy → DUT | Stage-1 pick; selects the pre-crossbar mux. `sa_gnt` always implies `sa_pick`. |
| `st_flit_data` | 32 | output | DUT → checks | The single post-mux datapath output — must equal the exact flit the test offered. |
| `st_route_next` | 4 | output | DUT → checks | Lookahead route presented during the grant cycle only (it is muxed by `sa_pick`). |

### 1.2 The mock-arbiter seam (bench support, not the DUT)

| Signal | Width | Direction | Source → Destination | Working / description |
|---|---|---|---|---|
| `va_req` | `NUM_VC-1:0` (2) | input | DUT `req_va` → mock | The port's VA requests, one bit per VC. |
| `va_gnt` | `NUM_VC-1:0` (2) | output | mock → bench copy loop | `va_gnt = va_req` combinationally. |
| `va_gnt_out_vc` | `[1:0]` × `NUM_VC` | output | mock → bench copy loop | Per-input-VC round-robin over output VCs, wrapping at `NUM_VC`. |
| `sa_req` | `NUM_VC-1:0` (2) | input | DUT `req_sa` → mock | The port's SA requests, one bit per VC. |
| `sa_gnt`, `sa_pick` | `NUM_VC-1:0` (2) each | output | mock → bench copy loop | One round-robin pick, granted immediately. |
| `n_va_grants`, `n_sa_grants` | `int unsigned` | output | mock → `r_n_va`/`r_n_sa`, `l_n_va`/`l_n_sa` → checks | Running totals used as the "nothing granted twice or dropped" reference in T2, T8, R1, L1, V1 and C1. |

### 1.3 Parameters, variables and state

| Name | Width | Kind | Reset | Working / description |
|---|---|---|---|---|
| `NUM_VC` | 2 | `localparam int` | — | VCs per port; also the width of every request/grant vector and the size of the unpacked per-VC arrays. Passed to both DUTs and both mocks. |
| `FLIT_BODY`, `FLIT_HEAD`, `FLIT_TAIL`, `FLIT_HEAD_TAIL` | 2 | `localparam logic [1:0]` | — | `00/01/10/11` — the flit-type encoding, restated so tests read as packets; must match the DUT's own constants (the DUT asserts this at time 0). |
| `DIR_LOCAL`, `DIR_NORTH`, `DIR_EAST`, `DIR_WEST`, `DIR_SOUTH` | 4 | `localparam logic [3:0]` | — | `0000/0001/0010/0100/1000`, matching `route_compute`'s one-hot codes. |
| `CUR_X`, `CUR_Y` | 3 | `localparam logic [2:0]` | — | `3'd3` — this router's coordinates, passed to both DUT instances; also used as the "inject to self" destination in L1. |
| `CLK_PERIOD` | 10 ns | `localparam realtime` | — | Clock period (half period = toggle delay; timeout = `CLK_PERIOD * 2000`). |
| `SETTLE` | 1 ns | `localparam realtime` | — | Delay applied after every negedge before checking, so combinational DUT outputs have settled. |
| `errors` | 32-bit `int` | counter | 0 | Incremented by `report()` on any mismatch. |
| `checks` | 32-bit `int` | counter | 0 | Incremented by `report()`; the 139 of the final report. |
| `clk`, `rst_n` | 1 | `logic` (bench-driven) | `clk` 0 at time 0, `rst_n` 0 in `do_reset()` | `initial clk = 1'b0;` + `always #(CLK_PERIOD/2) clk = ~clk;`. |
| `r_flt_data`, `r_flt_valid`, `r_vc_id` | 32 / 1 / 2 | `logic` (bench-driven) | parked `'0`/0 by the top-level `initial` | Relay link stimulus, written only by `r_step()`. |
| `l_flt_data`, `l_flt_valid`, `l_vc_id` | 32 / 1 / 2 | `logic` (bench-driven) | parked `'0`/0 | Local link stimulus, written only by `l_step()`. |
| `r_credit`, `l_credit` | `NUM_VC-1:0` (2) | `logic` (DUT-driven) | — | `credit_return_valid` observation; sampled per cycle and summed in C1. |
| `r_req_va`, `r_va_req_out_port[]`, `r_va_req_single`, `r_va_gnt`, `r_va_gnt_out_vc[]` | 2 / `[3:0]`×2 / 2 / 2 / `[1:0]`×2 | `logic` (mixed DUT- and mock-driven) | DUT- and mock-defined | VA-side bundle (mirrored `l_*`); the `*_gnt` members are driven by the copy loop below. |
| `r_req_sa`, `r_sa_req_out_port[]`, `r_sa_req_out_vc[]`, `r_sa_req_last`, `r_sa_gnt`, `r_sa_pick` | 2 / `[3:0]`×2 / `[1:0]`×2 / 2 / 2 / 2 | `logic` (mixed DUT- and mock-driven) | — | SA-side bundle (mirrored `l_*`). |
| `r_st_flit_data`, `r_st_route_next` | 32 / 4 | `logic` (DUT-driven) | — | Datapath outputs (mirrored `l_*`). |
| `r_m_va_gnt`, `r_m_sa_gnt`, `r_m_sa_pick`, `r_m_va_out_vc[]` | 2 / 2 / 2 / `[1:0]`×2 | `logic` (mock-driven) | mock-defined | Raw mock outputs before the copy loop (mirrored `l_*`). |
| `r_n_va`, `r_n_sa`, `l_n_va`, `l_n_sa` | `int unsigned` | variable (mock-driven) | 0 | Grant totals; the bench snapshots them (`n_before`) and compares deltas/absolute values. |
| `pkts[6]` | 32 each | array (task local, C1) | — | The six single-flit packets of the credit test, alternating VCs `k % 2` and directions EAST/SOUTH. |
| `credits` | `int unsigned` | counter (task local, C1) | 0 at test start | Accumulates `r_credit[0] + r_credit[1]` every cycle of the run and the drain; must end at 6. |
| `n_before` | `logic [31:0]` | variable (task local, C1) | — | `r_n_sa` snapshot so the "flits switched" delta is scoped to this test. |

Other task locals (`H`, `B`, `T`, `pkt`, `p1`/`p2`, `f0`/`f1`,
`exp_route_next`, …) live for one test at a time and hold flits built by the
constructors in §2.4; they carry no state between tests. Note that
`mock_arbiter`'s own registers (`va_rr`, `rr_sa`, `va_cnt`, `sa_cnt`) belong to
the support module, not the bench — they are cleared by `rst_n`, which the
bench re-asserts before every test.

---

## 2. RTL explanation

### 2.1 Clock and reset (lines 158–170)

The clock is `initial clk = 1'b0;` plus `always #(CLK_PERIOD/2) clk = ~clk;`
— a 10 ns period. `do_reset()` asserts `rst_n = 1'b0`, waits `repeat (4)
@(negedge clk)`, releases it, then waits one more negedge and `#SETTLE` so
that when a test starts the DUT is out of reset *and* combinational logic has
settled. Every test begins with its own `do_reset()`, which clears the DUT's
per-VC state and both mocks' round-robin pointers and grant counters, so no
test inherits a pointer position from the previous one. Before the first test
the top-level `initial` parks both links idle (`flit_valid = 0`).

### 2.2 The cycle-accounting convention (header, lines 21–28)

This is the rule every expected value in the file depends on:

> Inputs are driven at the **negedge** of cycle N and checked at the same
> negedge after a settling delay. The **posedge** that *ends* cycle N commits
> them, so a signal driven "during c0" is consumed by the c0→c1 edge and its
> effect is visible on outputs during c1.

That matches the spec's section 3 timeline word for word ("H on link in c0" →
"H on data_out, head_valid, arrive, va_req in c1"). Mechanically:

- `r_step(d, v, vc)` / `l_step(...)` do `@(negedge clk);` then assign the
  three link signals, then `#SETTLE` (1 ns) — so the DUT sees stable inputs a
  half cycle before the committing edge, and the *same* time slot can then
  read combinational outputs (`req_va`, `va_req_out_port`, `st_route_next`)
  after the settle without racing the assignment.
- `r_idle()` / `l_idle()` are `r_step(32'h0, 1'b0, 2'd0)` — one idle cycle
  that also advances time, which is why a test can write `r_idle();` and then
  check "cycle c3" without hand-managing the clock.
- Because each `r_step`/`r_idle` consumes exactly one cycle, back-to-back
  calls give back-to-back cycles, and a test's comments (`// ---- c2 ----`)
  line up with real simulated cycles.

Expected values are therefore hand-computed per cycle from the pipeline
timing rule (fetch in *t* → flit on `data_out` in *t+1* → `arrive` → VA
request against the **live** `route_compute` output → `out_port` latched at
the end of that edge → SA request in *t+2*), plus the registered credit
(assumption D4: credit appears one cycle after the fetch).

### 2.3 Two DUTs, two mock arbiters, and the grant copy loop (lines 197–352)

`u_relay` (`IS_LOCAL_PORT=0`) and `u_local` (`IS_LOCAL_PORT=1`) are identical
except for how route is obtained, so the same test vocabulary applies to both.
Each is paired with a `mock_arbiter` (`u_relay_mock`, `u_local_mock`). The
mock (documented in `tb/mock_arbiter.sv`) models only what the port depends
on:

- **VA** — combinational accept in the request cycle (`va_gnt = va_req`), as
  the spec locks it, with the output VC chosen round-robin *per input VC* so
  `out_vc` capture is exercised with more than one value.
- **SA** — one round-robin pick across this port's requesting VCs, granted
  immediately. Stage 2 is collapsed (there is only one client here), but the
  property the port cares about is preserved: at most one VC switched per
  port per cycle, and `sa_gnt` always implies `sa_pick`.

The mock's outputs are wired back into the DUT by an `always_comb` that copies
element by element (`for (int v = 0; v < NUM_VC; v++) r_va_gnt_out_vc[v] =
r_m_va_out_vc[v];`) — deliberately not a whole-array assignment, so the
per-VC correspondence is explicit rather than hidden. The mock also exports
`n_va_grants`/`n_sa_grants`, which the tests use as free-running totals: a
packet granted twice, or never, shows up immediately in a total that was
expected to be exactly 1, 2 or 3.

### 2.4 Flit constructors (lines 131–153)

One place knows the bit layout, so tests read as packets instead of
concatenations:

```systemverilog
mk_head(ftype, route, dest_y, dest_x)  // [13:10]=ROUTE, [9:7]=DEST_Y, [6:4]=DEST_X,
                                       // [3:2]=VC_ID=2'b00, [1:0]=ftype
mk_payload(ftype, payload)             // [31:2]=payload, [1:0]=ftype
```

`mk_head` is used for HEAD and HEAD_TAIL (the only types that carry routing
metadata); `mk_payload` for BODY and TAIL. L1 deliberately passes `4'bxxxx`
as `route` to prove a LOCAL port never reads the header's ROUTE field.

### 2.5 The check family (lines 92–123)

`report(name, actual[31:0], expected[31:0])` owns all bookkeeping: it
increments `checks`, and on `actual !== expected` increments `errors` and
prints `[FAIL] name : got=… exp=… (t=…)`; otherwise it prints `[PASS] name :
…`. Four thin wrappers exist purely for width hygiene — a 4-bit direction
passed to a 32-bit formal would be a silent zero-extension that linters flag
(WIDTHEXPAND) and that hides genuine width mistakes:

| Task | Accepts | Used for |
|---|---|---|
| `chk(n, a, e)` | 32-bit | flits, grant totals |
| `chk4(n, a, e)` | 4-bit | route directions (explicitly widened `{28'd0, a}`) |
| `chk2(n, a, e)` | 2-bit | VC indices, packed per-VC vectors (`req_va`, `credit`, …) |
| `chk_bit(n, a, e)` | 1-bit | single flags |

All four funnel into `report`, so there is exactly one pass/fail rule in the
bench. Like the other benches, a failure does not abort the test — the log
keeps going and the final banner is decided by `errors` alone.

### 2.6 Where the expected values come from

There is no reference-model *function* here — the DUT's behaviour is a
cycle-by-cycle pipeline, so the model is the transcribed cycle table: each
test's comment block states the c0/c1/c2… expectation, and each `chk*` call
below it scores one cell of that table. Two independent cross-checks back it
up: the mock's grant totals (absolute counts per test) and the credit
accumulator in C1 (credits returned over a run must equal flits fetched).
Expected route values are computed once per test from the geometry (e.g. T2's
`exp_route_next = DIR_WEST` because from `(3,3)` the next hop `(2,3)` is still
two hops short of `dest_x = 1`).

### 2.7 Report, timeout and waveform (lines 874–918)

The main `initial` parks the links, runs the eight tests in source order, then
prints `Checks : N`, `Errors : N`, and either `ALL TESTS PASSED` or `TEST
FAILED`, and `$finish`s. A second `initial` fires at `CLK_PERIOD * 2000` and
prints `ERROR: tb_noc_input_port timed out` — a hung fetch/grant loop must
fail loudly rather than spin until someone kills the sim (this is the only
bench of the three with a watchdog). A third dumps `sim/noc_input_port.vcd`
for `make TOP=noc_input_port wave`.

---

## 3. Testing explanation

**Bench:** `tb/tb_noc_input_port.sv`, top module `tb_noc_input_port`.
**Run:** `make TOP=noc_input_port sim` — final report:

```
========================================
Checks : 139
Errors : 0
ALL TESTS PASSED
========================================
```

### 3.1 The tests, in source order

| # | Test (banner) | Property it targets | Checks |
|---|---|---|---|
| 1 | `T0: idle after reset` | With nothing offered nothing may be requested, granted, switched or credited: `req_va`, `req_sa`, `credit_return`, `st_flit_data`, `st_route_next`, `va_req_single`, `sa_req_last` all zero on the relay port, `req_va` zero on the local port. Catches anything asserted combinationally off stale `data_out`. | 8 |
| 2 | `T9: empty-FIFO bypass` | A single HEAD_TAIL on an empty FIFO takes the bypass path: c0 fetch → c1 on `data_out` with `req_va` + **live** `va_req_out_port == DIR_WEST` + the registered credit → c2 SA request/grant and `st_flit_data == pkt` → c3 released. Also that the c0 fetch's credit appears in c1 (D4) and *not* in c0 or c2. | 16 |
| 3 | `T2: 3-flit packet, spec section 3 timeline` | The section 3 reference table transcribed cycle for cycle: H/B/T arriving back-to-back on VC0 to WEST, with `va_req_single==0` for a multi-flit HEAD, `sa_req_last` rising only on the TAIL, `st_route_next == DIR_WEST` at the grant, three **consecutive** grants (c2, c3, c4) as the one-flit-per-cycle throughput claim, and exact totals `SA grants == 3`, `VA grants == 1`. | 29 |
| 4 | `T8: fetch and grant in the same cycle` | The collision the old `!head_valid && …` fetch rule got wrong: in c2 the head is granted *and* a TAIL bypasses into the still-empty FIFO. c3 must show `req_sa` still high with the TAIL on `st_flit_data` — i.e. the second clause of the fetch rule (the `fifo_wr_enable` disjunct, not the `fifo_empty` one), exercised by leaving the FIFO empty in c1. Totals `SA == 2`, `VA == 1`. | 16 |
| 5 | `R1: route capture + live VA output-port mux` | Two packets on the same VC routed to *different* ports. Packet 2 arrives while `out_port` still holds NORTH; `va_req_out_port` must read the **live** EAST (`arrive ? rc_route_self : out_port`) while `sa_req_out_port` must read the **latched** EAST from c5 on. Pins the regression where driving VA from the latch alone would have allocated packet 2 down NORTH. Totals `VA == 2`, `SA == 2`. | 13 |
| 6 | `L1: LOCAL port route compute` | The only instance where `route_self` is computed. Three HEAD_TAIL packets with a **poisoned** ROUTE field (`4'bxxxx`, which a local port must ignore): dest east (`DIR_EAST`), dest south (`DIR_SOUTH` — Y grows downward), and dest == CUR (`DIR_LOCAL`, forced without a second compute on junk next-hop coordinates). Per packet: live VA port, credit (`2'b01`), `va_req_single`, latched SA port, `sa_gnt`, `sa_req_last`, `sa_req_out_vc` (round-robin `0 → 1 → 0`), `st_flit_data`, `st_route_next`, release. Totals `VA == 3`, `SA == 3`. | 32 |
| 7 | `V1: two VCs concurrently` | Two single-flit packets on VC0/VC1 one cycle apart to different ports: the VCs do not interfere, `sa_gnt` is one-hot at any instant (one datapath per port), `sa_pick` selects the right VC's flit for `st_flit_data`, each packet's route survives to its own `sa_req_out_port`, and a VC whose flit is still on the link asks for nothing yet. Totals `VA == 2`, `SA == 2`. | 23 |
| 8 | `C1: credit return accounting` | Six single-flit packets, alternating VCs (`k % 2`) two cycles apart, each cycle's `r_credit[0] + r_credit[1]` accumulated over the run **and** a 6-cycle drain: credits returned == 6 (no flit lost, none double-counted) and `SA grants == 6`. | 2 |
| | | **Total** | **139** |

### 3.2 What the bench deliberately does not check

X-propagation: the engine is Verilator (2-state), so the poisoned-ROUTE
(`4'bxxxx`) cases are forward-looking — they document intent and become real
checks under VCS. It also does not model the real arbiter's stage-2 timing or
a second router: this is a *port* test, so multi-port arbitration, credit
*accounting on the output side*, and crossbar behaviour belong to `tb_arbiter`,
`tb_crossbar` and `tb_router_top`. Only one directional and one LOCAL port are
instantiated, both at `CUR=(3,3)`.

### 3.3 Assertion coverage

`rtl/noc_input_port.sv` carries the heaviest SVA of the leaf modules, and this
bench is what exercises it (every build runs with `--assert`; without the
flag Verilator parses `assert property` and silently drops it):

- **1 immediate `assert`** at time 0 — the flit-type constants must equal
  `00/01/10/11`, a static cross-check against every other module and bench
  that hard-codes the same encoding.
- **12 `assert property` statements inside the per-VC generate loop**, ×
  `NUM_VC = 2` → **24 instances**: `va_gnt |-> req_va`, `sa_gnt |-> req_sa`,
  `sa_gnt |-> sa_pick`, `fetch |-> (!head_valid || sa_gnt)`, `fetch |->
  (!fifo_empty || fifo_wr_enable)`, `!(fifo_wr_enable && fifo_full)`,
  `!fifo_err`, `va_gnt |-> !assignment_valid`, `assignment_valid |->
  !$isunknown(out_vc)`, `head_valid |->` flit-type shortcuts match
  `flit_type`, `head_valid |-> out_port` is one of the five legal directions,
  and `arrive |-> (in_pkt ? !is_head : is_head)` (the HEAD, BODY*, TAIL
  sequence rule of spec section 8).
- **2 port-level `assert property`**: `$countones(sa_pick) <= 1` and
  `$countones(sa_gnt) <= 1` — at most one VC picked and one switched per port
  per cycle, which V1 checks from the outside as well.
- **4 immediate parameter assertions inherited from the two embedded `fifo`
  instances** (2 per instance), which also pass at time 0.

That is 31 assertion instances live during the run; a failure would print as a
tool `%Error` line alongside the bench's own `[FAIL]` lines. Notably
`assignment_valid |-> !$isunknown(out_vc)` is trivially true in a 2-state
engine — it has teeth only under VCS, as the RTL comment says.
`tools/assert_neg.sh` proves the sequence family really fires: case 2
(`noc_input_port: in_pkt never opens`) closes `in_pkt` on a HEAD instead of a
TAIL, rebuilds with `--assert`, and requires the message
`flit sequence broken` to appear — otherwise it reports MISSED.

### 3.4 Mutation sanity

`tools/mutate_all.sh` contains `route_compute: XY direction inverted` and
`noc_input_port: grant wins over fetch (section 9)` (the fetch/grant
priority swap), but both are evaluated against `tb_router_top`, built **without**
`--assert`. T8 and T2 above are this bench's equivalent of the second one:
if `sa_gnt` were allowed to win over `fetch`, c3 of T8 would show `req_sa`
dropping for a cycle and the `T8 c3 req_sa (head held across collision)`
check would fail.
