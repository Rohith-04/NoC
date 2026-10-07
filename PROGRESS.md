# Implementation progress — Linnea NoC router

Handoff notes written 2026-10-06, updated 2026-10-07 so work can resume
exactly where it stopped.
Authoritative design doc: `linnea_router_implementation_spec.md` (untracked,
user's document — left as-is, it still mentions Icarus).

**Toolchain: Verilator only. No Icarus/iverilog support, ever.**
The user's requirement: *"i will eventually use vcs later with the full noc and
uvm so test and i want the final thing to be able to run on vcs so anything
that keeps me close to that goal is fine"* — so everything stays Verilator-clean
**and** VCS-portable (full SVA in the RTL, no tool-specific RTL hacks).

---

## 1. Current state

| Item | State |
|---|---|
| Steps 1–5 (input port, route compute, arbiter, crossbar, output port) | RTL + benches done, all green |
| Step 6 `rtl/router_top.sv` | RTL done, `-Wall` lint clean |
| Step 7 `tb/tb_router_top.sv` | **Done — `ALL 108 CHECKS PASSED`**, 8/8 mutations killed |
| Step 8 `tb/tb_router_chain.sv` (T10, T11) | **Done — `ALL 477 CHECKS PASSED`** |
| Lint sweep (all 7 RTL tops) | clean under `-Wall` |
| Mutation suite (bench side) | **8/8 killed** |
| Negative assertion suite (assertion side) | **`tools/assert_neg.sh` — 6/6 FIRED** |
| Housekeeping (`files.f`, README) | **Done** |
| Documentation (`docs/`, one MD per source file) | **Done — 17 files, all three sections, all required tables** |
| Synthesis pass (spec §10 item 9) | **Out of scope** |

Latest full sweep: all eight benches green, all seven lint targets clean,
`git diff --stat rtl/` showing only the intended `noc_input_port.sv` change.

### Check counts (all should pass in a sweep)

| Bench | Command | Result |
|---|---|---|
| `tb_fifo` | `make TOP=fifo sim` | green (953) |
| `tb_route_compute` | `make TOP=route_compute sim` | green (49178) |
| `tb_noc_input_port` | `make TOP=noc_input_port sim` | green (139) |
| `tb_arbiter` | `make TOP=arbiter sim` | green (83) |
| `tb_crossbar` | `make TOP=crossbar sim` | green (286) |
| `tb_noc_output_port` | `make TOP=noc_output_port sim` | green (139) |
| `tb_router_top` | `make TOP=router_top sim` | green (108) |
| `tb_router_chain` | `make TOP=router_chain sim` | green (477) |
| lint (each RTL top) | `make TOP=<module> lint` | clean |
| assertions (6 families) | `bash tools/assert_neg.sh` | 6/6 FIRED |

---

## 2. THE BIG ONE: Verilator 5.020 breaks arrays of queues

**Symptom.** `tb_router_top` sent T1a's flit into port 0, but the EAST input
port received it; the arbiter then correctly aborted with
`illegal XY pair in->out (2 -> 2)`. Took a long time to find because every
individual construct looked legal.

**Reproducer** (`/tmp/opencode/qrepro3.sv`, reduced from the bench):

```systemverilog
typedef struct { logic [31:0] data; } tx_t;
tx_t tx_q[NUM_PORTS][$];           // <-- array OF QUEUES

task automatic send(input int port, input logic [31:0] data);
  tx_t t; t.data = data;
  tx_q[port].push_back(t);         // <-- runtime index
endtask

initial begin
  send(0, 32'h1111);
  void'(tx_q[0].pop_front());      // queue now empty
  send(2, 32'h2222);
  // tx_q[2].size() == 2, tx_q[2][0].data == 00001111   <-- WRONG
end
```

**What was measured (Verilator 5.020, Debian 5.020-1):**

| Form | Works? |
|---|---|
| `tx_t q[N][$]` + runtime index, push, **inside a task** (auto *or* static) | **BROKEN** |
| `tx_t q[N][$]` + runtime index, push, in `initial` / `always` | OK |
| `tx_t q[N][$]` + **constant** index (if/else dispatch) in a task | OK |
| `tx_t q[N][$]` + `.delete()` after corruption | also unreliable |
| **single** queue `tx_t q[$]` + runtime index (push, read, `delete(idx)`) | **OK** |
| plain 2-D unpacked array `mem[5][16]` + runtime index | OK |

**The fix applied in `tb/tb_router_top.sv`** (documented in-file at the `tx_t`
declaration):

```systemverilog
typedef struct {
  int          port;     // destination port carried with the flit
  logic [1:0]  vc;
  logic [31:0] data;
} tx_t;

tx_t tx_q[$];            // ONE queue, not an array of queues
```

* `send(port, data, vc)` → `t.port = port; tx_q.push_back(t);`
* driver: for each port, **scan** for the oldest entry with `tx_q[i].port == p`
  (preserves arrival order — head-of-line per link, exactly right) then
  `tx_q.delete(drv_idx)`
* `drain()` → `left = tx_q.size();`

**Rule to remember:** in this codebase, *never* declare `type q[N][$]`. Use one
queue with a tag field, or a fixed-size circular buffer.

---

## 3. Bugs found in `tb_router_top` (all bench bugs — the RTL was right)

Every one of these was a real defect caught either by the RTL assertions or by
the bench's own checks:

1. **T1b "illegal XY pair (2 → 2)"** — not an RTL bug, the array-of-queues
   corruption above delivered the *wrong flit* to the EAST port.
2. **T2 counted before the packet finished.** The wait loop stopped at the
   *first* arrival and then asserted `rx_n() == 3` → `got 1 exp 3`, and the two
   late flits then contaminated T3. Now: wait for the first flit (latency
   measurement), then a second bounded wait for all three.
3. **T4 injected an illegal U-turn** — WEST input with `route = DIR_WEST`.
   Legal XY pairs for a WEST input are EAST/NORTH/SOUTH/LOCAL, never WEST; the
   arbiter's `xy_legal` assertion fired (`3 -> 3`). Changed VC1 to
   `DIR_NORTH` (dest `(1,2)`), which is also topologically coherent for a flit
   arriving from `(0,1)`.
4. **T4's downstream-VC expectation was wrong.** The two streams leave through
   *different* output ports, and each output port allocates VC rows from its
   own free list — so both get VC 0. Replaced with the meaningful property:
   *each packet rides exactly one downstream VC for all its flits*, plus the
   tag-partitioned HEAD/BODY/TAIL sequence check ("no payload crossed
   streams"). The original `rx_tag(0) != rx_tag(1) && rx_tag(0) != rx_tag(2)`
   was also unpassable-in-principle with only two distinct tags.
5. **T6 never sent the TAILs.** It sent 3 flits and checked for 5. This also
   left a packet **open** on the EAST input VC0, which is what later tripped
   `noc_input_port: flit sequence broken on VC 0: type=01 while in_pkt=1` in T8.
   Both fixed by sending `mk_tail(...)` after each `mk_head(...)`.
6. **T7's credit model dropped credits instead of delaying them.**
   `ds_credit_valid = credit_en & cr_pipe[CRED_LAT]` *cancelled* the credit, so
   the downstream pool was permanently short and the last 4 flits could never
   be granted after recovery (`got 8 exp c`). Fixed with a `held_credits`
   counter: while `credit_en == 0` a credit is collected, while it is `1` the
   backlog is paid down one per cycle. Closing a loop delays a credit, it never
   cancels one.
7. **T9's latency measurement was negedge-race-prone** — its answer depended on
   whether the test process or the driver got to run first at the negedge where
   the flit was presented (measured `2` instead of `3`). Rewritten to sample
   **both** ends at the posedge that closes each cycle, exactly like the RX
   logger. Now correctly reports 3.

**And one later, in `tb/tb_crossbar.sv` T5.** T5 exists to de-correlate a
crossbar's two muxes: one pair of ports with *same data, different route*, and
one with *different data, same route*, so that in each half one field's check
is blind and only the other can catch a mux pointed at the wrong index. Line
280 copied port 3's payload onto port 4 **as well as** the route, so the second
pair ended up identical in *both* fields — the `T5 data now differs (port 4)`
check could not tell a selection of 3 from a selection of 4, contradicting the
test's own header comment. Deleting that one copy restores the intent; 286
checks, same names, same count. Caught by reading `docs/tb/tb_crossbar.md`
against the source, i.e. by the documentation pass.

---

## 4. Bench weaknesses found by mutation testing (and fixed)

Method: mutate the RTL, build **without `--assert`** so SVA is compiled out,
and require the *bench's own* checks to fail. This proves the bench is not
vacuously riding on the RTL assertions.

Build line for mutation runs (assertions off):

```
verilator --binary --timing --trace -Wall -Wno-BLKSEQ -Wno-WIDTHEXPAND \
  -Wno-UNUSEDSIGNAL -sv --top-module tb_router_top -Mdir obj_dir/v_mut \
  -o run rtl/*.sv tb/tb_router_top.sv
```

(`-Wno-UNUSEDSIGNAL` is needed only for mutants that delete the sole use of a
signal; `make lint` still runs full `-Wall` on the real RTL.)

### Results

All numbers below are from the current suite (it now runs against
`tb_router_top`, which has 108 checks, so totals read 107 or 108).

| Mutation | Script | Result |
|---|---|---|
| `route_compute`: XY direction inverted | `mutate_all` | **killed** (17/107) |
| `arbiter`: stage-2 round-robin ignores its pointer | `mutate_all` | **killed** (1/108) |
| `noc_input_port`: grant wins over fetch (spec §9) | `mutate_all` | **killed** (18/49) |
| `arbiter`: stage-1 ignores the credit pool | `mutate_all` | **killed** (2/108) |
| `crossbar`: data mux reads the port next to the winner | `mutate_all` | **killed** (31/107) |
| `noc_output_port`: header route field merged with the wrong direction | `mutate_all` | **killed** (3/108) |
| `noc_output_port`: route merge never happens | `mutate_out` | **killed** (3/108) |
| `noc_output_port`: route merge applied to every flit | `mutate_out` | **killed** (2/108) |

> `mutate_all` originally carried a stale mutation whose pattern
> (`xbar_out_route_next[o]`) no longer existed in the source and was being
> skipped. It was replaced with the *wrong-direction merge* above, which does
> fire and which the other two do not cover: a merge that always executes but
> writes a constant still satisfies "the condition was true".

**Assertion-side suite — `tools/assert_neg.sh` (new).** The table above
proves the *benches* catch a broken design; those builds run **without**
`--assert`, so nothing in them exercises the SVA. This script proves the
other half. One case per assertion family, rebuilt with `--assert` on, and
it greps for the exact `$error` text of the property under test:

| Family | Case | Evidence |
|---|---|---|
| static parameter check | `fifo`: DEPTH bound widened to 9 | `%Fatal: fifo.sv:62: ... fifo: DEPTH must be a power of two >= 2, got 8` |
| leaf clocking SVA | `noc_input_port`: `in_pkt` never opens | `noc_input_port.sv:870: ... flit sequence broken on VC 0: type=00 while in_pkt=0` |
| leaf clocking SVA | `arbiter`: stage-1 ignores the credit pool | `arbiter.sv:663: ... switched out on [4][0] with no credit` |
| leaf clocking SVA | `crossbar`: data mux reads the port next to the winner | `crossbar.sv:180: ... does not track its selection (0)` |
| leaf clocking SVA | `noc_output_port`: header merge never happens | `noc_output_port.sv:181: ... HEAD route not updated (have 8, want 2)` |
| **top seam SVA** | `router_top`: credit fold forced to `'1`, run against **`tb_router_chain`** | `router_top.sv:444: ... port 1 has no link but returned credits 11` |

Two things worth remembering from that last row:

* **The two `HAS_P`-gated seam properties are vacuous under
  `tb_router_top`** — that bench ties all five ports present. Only the chain
  (A has no WEST, C has no EAST, nobody has NORTH or SOUTH) makes an absent
  port exist at all. New assertions of that kind must be negative-tested
  against the chain.
* The tool **aborts at the first `$error`** (`Verilog $stop`), so a case
  whose target property is beaten to the wire by another one reports MISSED.
  Choose mutations that fire the intended property on the first edge.

### Two mutations initially SURVIVED — and why

**(a) `crossbar`: `st_valid` removed from the data-mux gate.**
Functionally *equivalent*: an idle output already drives `xbar_sel = NUM_PORTS`,
so `< NUM_PORTS` blocks it anyway. Not a bench weakness. Replaced with a
non-equivalent mutant (index off by one), which is killed.

**(b) `arbiter`: stage-2 round-robin ignores its pointer.**
A genuine bench weakness: **T5 created no simultaneous contention.**
Single-flit packets self-pace — after a grant an input port spends a cycle
fetching its next flit, so the two sides drift into *opposite* phases and stage
2 never sees two requesters at once. An arbiter that always picked the lowest
requesting port looked perfectly fair (`NENENENE` either way).

**T5 rewritten**: each side now sends **one 6-flit packet** (H + 4·B + T).
Inside a packet, fetch and grant share a cycle (§9), so `sa_req` stays asserted
on every cycle of the packet and both ports really do ask on the same cycles,
six times running. Check: `first_six_north >= 2 && first_six_east >= 2` (a
latching arbiter gives 6/0). This went 99 → 103 checks and killed the mutant.

**(c) `noc_output_port`: merge applied to every flit** also initially survived,
for two reasons, both fixed:
* `mk_body`/`mk_tail` filler was `12'h0` / `12'h1`, so their `[13:10]` was
  `0000` — and for a BODY the lookahead *is* `DIR_LOCAL` (its `[13:10]` payload
  reads as `route_in = 0000`), so the overwrite wrote back the value already
  there. Filler changed to `12'h201` (→ `[13:10] = DIR_EAST`) and `12'h401`
  (→ `DIR_WEST`) — legal direction values, deliberately, so `unique case
  (route_self_c)` in `route_compute` still matches.
* T2's destination was `(0,1)`, exactly the next router, so the HEAD's
  lookahead was also `DIR_LOCAL`. T2's dest changed to **`(0,2)`** (one hop
  beyond the exit port), so the merged header must read `DIR_SOUTH` — the turn
  the *neighbour* will make.

### New checks added as a result
* `T1a/T1c "outgoing route is the next hop"` → `DIR_LOCAL`, via a new
  `rx_route(i)` helper (`rx[i].data[13:10]`). A single router never consumes
  its own outgoing route field, so this is the **only** outside observation of
  the header merge on a single-router bench.
* `T2 "outgoing route is the next hop"` → `DIR_SOUTH`.
* `T2 "BODY/TAIL flit left unmodified"` — full 32-bit identity; non-heads must
  come out bit-for-bit identical to what went in.

Scripts are checked into the repo: `tools/mutate_all.sh`, `tools/mutate_out.sh`.
They back up, mutate, build, run, and restore; `git diff rtl/` was verified
clean afterwards (all six RTL files back to their originals).

---

## 5. Standing rules / gotchas for this repo

* **`--assert` is mandatory** in sim *and* lint. Without it Verilator parses
  `assert property` and silently drops it (verified empirically).
* **SVA in Verilator:** `|-> ##1 X` unsupported → use `|=> X`. `|-> $past(X)`
  is fine. `##[n:m]` forms all fail. Documented in `rtl/noc_output_port.sv`.
* **No `inside { ... }` in assertions** — lowers to `==?` with a non-constant
  RHS → `%Error-UNSUPPORTED`. Use an explicit `||` chain of `==`.
* **No `'{...}` assignment pattern as an argument** (e.g. as a `push_back`
  argument) — build struct fields one at a time.
* **Never declare an array of queues** — `type q[N][$]`. See §2; use one
  queue of structs with a tag field.
* **Never put `return` or `break` inside a `for` loop in an `automatic
  function` called from an `initial`-block coroutine.** The toolchain hoisted
  the loop's `i++` out of the body: `i` was computed once from an
  uninitialised value and never advanced, so the loop spun forever on `i == 1`
  with no diagnostic. Smoking gun in `obj_dir/<top>/<top>___024root__DepSet_*.cpp`
  — a `__Vtemp = ((IData)(1U) + i);` sitting *above* the `while`. Loops in
  plain tasks and in `always` blocks were fine; the failure needed all three of
  *automatic function* + *early `return`/`break` in the loop body* + *called
  from a coroutine*. `work_pending()` in `tb_router_chain.sv` was rewritten as
  a pair of counter reads, and the end-of-test aggregates moved with it.
  Also in README, *Verilator Language Limits Hit Here*.
* **`$isunknown` is trivially false in a 2-state simulator**, so
  `assignment_valid |-> !$isunknown(out_vc)` only has teeth under VCS. Kept
  deliberately — that is where the network will ultimately be verified.
* **TB port-endpoint rule:** every module port endpoint must be a plain scalar
  or a *whole* array. Element selects (`sig[i]`) at endpoints silently freeze
  after time 0. Constant genvar indices are safe. See README "Testbench Wiring
  Rules".
* **Never start a comment line with the word "Verilator"** (metacomment trap).
* Under Verilator (2-state) `4'bxxxx` folds to `4'b0000` (= DIR_LOCAL).
* Port index: LOCAL 0, NORTH 1, EAST 2, WEST 3, SOUTH 4.
  Direction one-hot: `0000` LOCAL, `0001` NORTH, `0010` EAST, `0100` WEST,
  `1000` SOUTH.
* Legal XY pairs: N→{S,L}, S→{N,L}, E→{W,N,S,L}, W→{E,N,S,L}, LOCAL→{N,E,W,S}.
* Test router coordinates in `tb_router_top`: `CUR_X=1, CUR_Y=1`.
* Assertion sampling: credit counters right after `next_cycle()` (post-commit);
  combinational grants after `settle()`.
* RX logger samples at posedge reading pre-edge values, so after seeing an
  output flit at a negedge one more `@(negedge clk)` is needed before `rx_n()`
  reflects it.
* Bench naming: `tb/tb_<TOP>.sv`, top module `tb_<TOP>`; support files in `tb/`
  that are *not* `tb_*.sv` are auto-included by the Makefile.
* Commands: `make TOP=<x> sim`, `make TOP=<rtl-module> lint`, `make TOP=<x>
  wave`, `make clean`.

---

## 6. Spec assumptions confirmed

* **D1** per-VC credit vector — confirmed.
* **D2** VA is not credit-gated — confirmed.
* **D3** ignore the header's `VC_ID`; downstream VC comes from the sideband —
  confirmed (and asserted in `noc_output_port`: only `[13:10]` is written,
  `[3:2]` untouched).
* **D4** registered credit return — confirmed (`CRED_LAT = 2` in the bench).
* FIFO depth **8** (user chose over spec's 4) → arbiter `DIR_CREDITS =
  FIFO_DEPTH`; `LOCAL_CREDITS = 4` on `router_top`.

---

## 7. Remaining work

Everything through step 8 is done and green, including the documentation
deliverable. What is left is optional polish and the eventual commit.

1. **Documentation** — **done.** 17 files under `docs/`, one per source file
   (`rtl/*.sv`, `tb/*.sv` including `mock_arbiter.sv`, plus `Makefile`), each
   with exactly three sections in order —
   `(1) Ports and state` → `(2) RTL explanation` → `(3) Testing explanation` —
   and each carrying both required tables:

   * port table with columns
     `| Signal | Width | Direction | Source → Destination | Working / description |`
     (for a bench top, whose module has no ports, this table documents the
     interface presented to and extracted from the DUT);
   * separate register/state table with columns
     `| Name | Width | Kind | Reset | Working / description |`.

   Exemplar: `docs/rtl/fifo.md`. README's *Project Structure → Documentation*
   lists them and states the convention.

   | Source | Doc |
   |---|---|
   | `rtl/fifo.sv` | `docs/rtl/fifo.md` |
   | `rtl/route_compute.sv` | `docs/rtl/route_compute.md` |
   | `rtl/noc_input_port.sv` | `docs/rtl/noc_input_port.md` |
   | `rtl/arbiter.sv` | `docs/rtl/arbiter.md` |
   | `rtl/crossbar.sv` | `docs/rtl/crossbar.md` |
   | `rtl/noc_output_port.sv` | `docs/rtl/noc_output_port.md` |
   | `rtl/router_top.sv` | `docs/rtl/router_top.md` |
   | `Makefile` | `docs/Makefile.md` |
   | `tb/tb_fifo.sv` | `docs/tb/tb_fifo.md` |
   | `tb/tb_route_compute.sv` | `docs/tb/tb_route_compute.md` |
   | `tb/tb_noc_input_port.sv` | `docs/tb/tb_noc_input_port.md` |
   | `tb/tb_arbiter.sv` | `docs/tb/tb_arbiter.md` |
   | `tb/tb_crossbar.sv` | `docs/tb/tb_crossbar.md` |
   | `tb/tb_noc_output_port.sv` | `docs/tb/tb_noc_output_port.md` |
   | `tb/mock_arbiter.sv` | `docs/tb/mock_arbiter.md` |
   | `tb/tb_router_top.sv` | `docs/tb/tb_router_top.md` |
   | `tb/tb_router_chain.sv` | `docs/tb/tb_router_chain.md` |

2. **Final verification sweep — run and green:**

   ```
   for t in fifo route_compute noc_input_port arbiter crossbar \
            noc_output_port router_top router_chain; do make TOP=$t sim; done
   for m in fifo route_compute noc_input_port arbiter crossbar \
            noc_output_port router_top; do make TOP=$m lint; done
   bash tools/mutate_all.sh && bash tools/mutate_out.sh   # 8/8 killed
   bash tools/assert_neg.sh                               # 6/6 FIRED
   git diff --stat rtl/                                   # only noc_input_port.sv
   ```

3. **Git.** Last commit is `973ed2c "Input port implementation without
   verification"`. The spec is untracked (user's document, left as-is — it
   still mentions Icarus). **All session changes are uncommitted; nothing has
   been committed this session.** A sensible commit split, if wanted:

   * `rtl/noc_input_port.sv` — spec §4.2 / §9 rewrite (already tracked, modified)
   * `rtl/{arbiter,crossbar,noc_output_port,router_top}.sv` + the six new
     benches + `tb/mock_arbiter.sv` — steps 3–8
   * `Makefile`, `README.md`, `files.f` — Verilator-only flow, wiring rules,
     language limits
   * `tools/` — mutation suite and assertion suite
   * `docs/` — the documentation deliverable
   * `PROGRESS.md` — handoff notes

4. **Out of scope / not started:** synthesis pass at `NUM_VC` 2 and 4
   (spec §10 item 9), AXI4-Stream wrapper, additional routing algorithms.

---

## 8. File map

| File | Role |
|---|---|
| `linnea_router_implementation_spec.md` | authoritative spec (§3 timeline, §4 modules, §5 seams, §6 credit loop, §8 verification plan T1–T10, §9 change list, §10 build order) |
| `rtl/fifo.sv` | reference style; Step 0, verified |
| `rtl/route_compute.sv` | Step 2, verified (49178 checks) |
| `rtl/noc_input_port.sv` | Step 1 + spec §8 `in_pkt` flit-sequence assertion; 139 green |
| `rtl/arbiter.sv` | Step 3, VA + SA, `xy_legal`, credit counters; 83 green |
| `rtl/crossbar.sv` | Step 4, 3 assertions; 286 green, mutation-tested |
| `rtl/noc_output_port.sv` | Step 5, header merge + link register + SVA; 139 green, mutation-tested |
| `rtl/router_top.sv` | Step 6, lint clean |
| `tb/tb_router_top.sv` | Step 7, **108 green**, mutation-tested |
| `tb/tb_router_chain.sv` | Step 8, **477 green** (T10a–d, §6 credit loop, T11 scoreboard) |
| `tb/mock_arbiter.sv` | support file, auto-included by Makefile |
| `Makefile` | Verilator-only `sim` / `lint` / `wave` / `clean` |
| `files.f` | compile list: slang-server (`.slang/server.json -f files.f`) and VCS later |
| `README.md` | features, build/lint/wave, **Testbench Wiring Rules**, **Verilator Language Limits Hit Here** |
| `docs/` | one Markdown per source file, three sections each (§7 item 1) |
| `tools/mutate_all.sh`, `tools/mutate_out.sh` | RTL mutation suite, **bench** non-vacuity (no `--assert`) |
| `tools/assert_neg.sh` | RTL mutation suite, **assertion** non-vacuity (`--assert` on), one case per family |
| `/tmp/opencode/rt.log` | last `tb_router_top` run log |
| `/tmp/opencode/assert_neg.bak.*` | scratch backups used by `assert_neg.sh` (restored on `EXIT`) |
