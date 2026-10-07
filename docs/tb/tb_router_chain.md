# `tb_router_chain` — `tb/tb_router_chain.sv`

Three `router_top` instances wired into a horizontal line, with real
router-to-router link wires and a real credit loop, running tests T10 and T11
of spec section 8 plus the section 6 credit-loop confirmation. Everything from
T1 down to T9 looks at *one* router, so every property those benches prove is a
property of a block. Two things are inherently two-block properties and can
never be observed that way: `route_next`, because a router writes the *next*
hop's direction into the header it transmits and then never looks at that field
again — the merge is only meaningful to whoever receives the flit — and the
section 6 credit loop, because `credit_return_valid` has to leave one router
and arrive at the arbiter of the one that fed it, through the same wires a real
link would carry. Two hops in a line give the first property two observations;
a long stream at full rate is what proves the second loop is short enough for
the credits on hand.

---

## 1. Ports and state

### 1.1 Ports and link wires

`tb_router_chain` is a leaf module with no ports of its own: everything that
crosses its boundary does so through the three `router_top` instances `u_a`,
`u_b` and `u_c`. The table therefore documents the interface *presented to and
extracted from those DUTs*. **The Direction column is from the DUT's point of
view: `input` means the bench drives the signal into the router, `output`
means the router drives it out.** `clk` and `rst_n` are single nets shared by
all three instances; rows 3–10 name three declarations each, one per router,
bench signals carrying an `a_` / `b_` / `c_` prefix and connecting to the same
DUT port; the last four rows are bench-side mirrors of DUT outputs, read by the
logger, the NI pipe and the credit assembly and never connected to a port.

| Signal | Width | Direction | Source → Destination | Working / description |
|---|---|---|---|---|
| `clk` | 1 | input | bench oscillator → `u_a`, `u_b`, `u_c` (and every `posedge` process in the bench) | `CLK_PERIOD = 10ns`, toggled every 5 ns. Single clock for the whole chain; nothing in the bench is asynchronous. |
| `rst_n` | 1 | input | `reset_dut()` → the three DUTs | Active-low *synchronous* reset (the DUT convention, same as `fifo`). Held low for five posedges, then released on a negedge so it is stable a full half-cycle before the next active edge. |
| `a_in_data`, `b_in_data`, `c_in_data` | `[NUM_PORTS-1:0][31:0]` | input | `link_and_inject`: LOCAL ← oldest matching flit of `tx_q`; EAST/WEST ← neighbour's registered `*_out_*` → DUT `in_flit_data` | One 32-bit flit per input port. Port indices are `LOCAL_IDX` 0, NORTH 1, `EAST_IDX` 2, `WEST_IDX` 3, SOUTH 4. A's WEST, C's EAST and everybody's NORTH/SOUTH carry no traffic and are held at 0. The whole array is rewritten from scratch on every negedge. |
| `a_in_valid`, `b_in_valid`, `c_in_valid` | `[NUM_PORTS-1:0]` | input | same → DUT `in_flit_valid` | Per-port "the data/VC next to me is a real flit this cycle". Zeroed before the copies, so an idle or absent port is a clean 0 rather than a stale 1 — which is what `router_top`'s tie-off expects to see. |
| `a_in_vc`, `b_in_vc`, `c_in_vc` | `[NUM_PORTS-1:0][1:0]` | input | same → DUT `in_vc_id` | Downstream VC id travelling *beside* the flit (assumption D3: the header's own `[3:2]` field is payload and is ignored). |
| `a_out_data`, `b_out_data`, `c_out_data` | `[NUM_PORTS-1:0][31:0]` | output | DUT `out_flit_data` → neighbour's input at the next negedge (A.EAST→B.WEST, B.EAST→C.WEST, B.WEST→A.EAST, C.WEST→B.EAST) and → `r_out_data` | The link-transmit registers. They only change at a posedge, which is what makes the negedge copy in §2.3 a faithful wire model. |
| `a_out_valid`, `b_out_valid`, `c_out_valid` | `[NUM_PORTS-1:0]` | output | DUT → `r_out_valid` (logger, NI pipe) and the neighbour's `*_in_valid` | Per-port "a flit is on this link during this cycle". This is the signal `rx_logger` keys off, and index `LOCAL_IDX` is what triggers an ejection credit in `ni_pipe`. |
| `a_out_vc`, `b_out_vc`, `c_out_vc` | `[NUM_PORTS-1:0][1:0]` | output | DUT → `r_out_vc` and the neighbour's `*_in_vc` | Sideband that must travel with its flit (asserted inside `noc_output_port`); the NI pipe decodes it to decide which VC's credit to send back. |
| `a_cred_ret`, `b_cred_ret`, `c_cred_ret` (`credit_return_valid`) | `[NUM_PORTS-1:0][NUM_VC-1:0]` | output | DUT → `ds_credit_assembly` (directional indices) and `link_and_inject`'s credit settling (LOCAL index) | One bit per VC: "a slot has just been freed in *this* router's input port *p*". It is returned by the router that **received** flits, so it has to be routed back to the neighbour that **sent** them — hence A.EAST's credits come out of B's WEST port, not A's. |
| `a_ds_cred`, `b_ds_cred`, `c_ds_cred` (`ds_credit_valid`) | `[NUM_PORTS-1:0][NUM_VC-1:0]` | input | `ds_credit_assembly`: directional ← neighbour's `credit_return_valid`; LOCAL ← `ni_pipe[r][NI_LAT]` → DUT `ds_credit_valid` | One bit per VC: "there is a free slot downstream on this outgoing link", which the arbiter counts as a credit. Absent ports are left at 0 — precisely the value `router_top`'s "no credit may come back on a link that does not exist" assertion demands. |
| `r_out_data` | `[N_RTR-1:0][NUM_PORTS-1:0][31:0]` | output (mirror) | continuous `assign` from `a_out_data` / `b_out_data` / `c_out_data` → `rx_logger`, `ni_credit_pipe` | Whole-DUT-array copy folded into one run-time-indexable aggregate, so "router *r*, port *o*" can be selected with a variable. Never used in a port connection. |
| `r_out_valid` | `[N_RTR-1:0][NUM_PORTS-1:0]` | output (mirror) | continuous `assign` from `a_out_valid` / `b_out_valid` / `c_out_valid` → logger, hop tallies, `ni_credit_pipe` | The logger's trigger. |
| `r_out_vc` | `[N_RTR-1:0][NUM_PORTS-1:0][1:0]` | output (mirror) | continuous `assign` from `a_out_vc` / `b_out_vc` / `c_out_vc` → logger, `ni_credit_pipe` | Records which VC each flit was switched onto. |
| `r_cred_ret` | `[N_RTR-1:0][NUM_PORTS-1:0][NUM_VC-1:0]` | output (mirror) | continuous `assign` from `a_cred_ret` / `b_cred_ret` / `c_cred_ret` → credit assembly, injection settling | Router-indexed view of every returned credit. |

Wiring discipline (README "Testbench Wiring Rules"): no port connection and no
generate endpoint contains an element select — the cross-router copies and the
per-index snooping all happen on the bench-side aggregates above, and each
router's port arrays are connected to its instance whole.

### 1.2 Registers and state

Everything declared at module scope that is not part of §1.1. `Kind` says what
the declaration *is*; `Reset` says what clears it in a simulation.

| Name | Width | Kind | Reset | Working / description |
|---|---|---|---|---|
| `NUM_PORTS` | 1 (`int`) | localparam | elaboration | 5. Width of every port-indexed array; fixed by the 5×5 crossbar. Only ports 0, 2 and 3 exist in this topology. |
| `NUM_VC` | 1 (`int`) | localparam | elaboration | 2. VCs per port; sizes the credit vectors `[NUM_VC-1:0]` and the per-VC inflight accounting. |
| `N_RTR` | 1 (`int`) | localparam | elaboration | 3. Routers in the line; sizes `r_*`, `eject_cnt`, `ni_pipe`, `inj_inflight`, and every loop over routers. |
| `LOCAL_IDX`, `EAST_IDX`, `WEST_IDX` | 1 each (`int`) | localparam | elaboration | 0, 2, 3. The three port indices this chain uses (NORTH 1 and SOUTH 4 are named nowhere in the bench — they can only ever be absent). |
| `FIFO_DEPTH` | 1 (`int`) | localparam | elaboration | 8. Passed to all three DUTs as their input-FIFO depth, *and* used as the per-VC inflight budget the bench's LOCAL driver enforces on itself. |
| `LOCAL_CRED` | 1 (`int`) | localparam | elaboration | 4. Passed as `LOCAL_CREDITS` — the NI receive-buffer depth per VC, and the tight pool the section 6 test exercises. |
| `CLK_PERIOD` | `realtime` | localparam | elaboration | 10 ns. Half period 5 ns → 100 MHz. |
| `NI_LAT` | 1 (`int`) | localparam | elaboration | 0. Extra stages in `ni_pipe` beyond its receive register; the single knob that sets the ejection-credit loop length (§2.4). |
| `MAX_STALL` | 1 (`int`) | localparam | elaboration | 500. Watchdog threshold: no new logged flit for more than this many cycles while work is outstanding is a deadlock. |
| `PKT_FLITS` | 1 (`int`) | localparam | elaboration | 16. Length of the single packet used by the section 6 credit-loop test. |
| `Y_COORD`, `X_A`, `X_B`, `X_C` | 3 (`logic [2:0]`) | localparam | elaboration | 1, 0, 1, 2. Router coordinates; every legal route in this test set is therefore EAST, WEST or LOCAL. |
| `FLIT_BODY`, `FLIT_HEAD`, `FLIT_TAIL`, `FLIT_HEAD_TAIL` | 2 each (`logic [1:0]`) | localparam | elaboration | `00`, `01`, `10`, `11`. Section 2 flit-type encoding, used by the constructors and by the scoreboard's sequence check. |
| `DIR_LOCAL`, `DIR_EAST`, `DIR_WEST` | 4 each (`logic [3:0]`) | localparam | elaboration | `0000`, `0010`, `0100`. The three direction codes this line can produce; `rx_route()` results are compared against them. |
| `rx_t`, `exp_t`, `tx_t` | structs | typedef | n/a | The three record types: one logged hop, one injected packet's reference, one queued flit. All queues below are queues of structs — never `type q[N][$]`, which this simulator corrupts under a run-time index. |
| `clk`, `rst_n` | 1 each | variable (clock / reset) | `clk` starts 0 and self-toggles; `rst_n` 0 at time 0, released by `reset_dut()` | Shared clock and reset nets; both are in §1.1 as DUT ports. |
| `a_*`, `b_*`, `c_*` (24 declarations) | see §1.1 | wire (logic) | cleared to 0 while `!rst_n` | The three DUT port sets. Bench-driven members are written only by `link_and_inject` (inputs) or by `ds_credit_assembly` (`ds_cred`); DUT-driven members are read-only to the bench. |
| `r_out_data`, `r_out_valid`, `r_out_vc`, `r_cred_ret` | see §1.1 | wire (continuous assign) | follows the DUT | The four aggregates of §1.1; they hold no state of their own. |
| `tx_q` | dynamic queue of `tx_t` | queue | starts empty; `send()` pushes, the driver `delete()`s | The single injection queue. Carries `rtr` *inside* the entry rather than being one queue per router, because an array of queues indexed by a variable corrupts silently in this simulator. Oldest matching entry wins. |
| `exp_q` | dynamic queue of `exp_t` | queue | `exp_q.delete()` in `reset_dut()` and at the top of T11 | The scoreboard's reference: one entry per injected packet with `tag`, `src`, `dest`, `len`, `vc` and the running `got` count. Deliberately records **no** expected arrival slot. |
| `rx` | dynamic queue of `rx_t` | queue | `clear_rx()` between tests | The receive log: one entry per flit leaving any router on any port, with router, port, VC, cycle and payload. |
| `sb_en` | 1 | register (`bit`) | 0 at declaration; set only inside T11, cleared on exit and by `reset_dut()` | Arms `sb_eject`. T10 and the credit-loop test inject without registering expectations, so scoring every ejection unconditionally would call each of them "a flit nobody injected". |
| `sb_outstanding` | 32 (`int`) | counter | `sb_reset()` | Registered packets that have not yet delivered their last flit. Incremented where an entry is created, decremented the moment `got` reaches `len`. Read by `work_pending()`. |
| `sb_got_flits` | 32 (`int`) | counter | `sb_reset()` | Flits matched by the scoreboard — the "received" half of flit conservation. |
| `sb_complete` | 32 (`int`) | counter | `sb_reset()` | Packets that reached `len` — the "every packet fully delivered" half. |
| `sb_total_flits` | 32 (`int`) | counter | `sb_reset()` | Flits injected in the current scored run, summed at generation time. |
| `eject_cnt` | `int` × `N_RTR` | array | zeroed by `clear_rx()` | Per-router count of flits that left on the LOCAL port, i.e. were delivered to that router's network interface. Counted by port at log time, not by re-walking the log. |
| `east_cnt`, `west_cnt`, `bad_port_cnt` | 32 each (`int`) | counter | zeroed by `clear_rx()` | Flit-hops that crossed a **present** east- or westbound link, and flits that left through a port the router does not have — NORTH (1) or SOUTH (4) anywhere, plus A's WEST and C's EAST, gated by the `HAS_EAST_P` / `HAS_WEST_P` tables. The last must be 0. |
| `stall_cnt` | 32 (`int`) | counter | 0 while `!rst_n` | Consecutive cycles with no new `rx` entry; cleared by any observed arrival. |
| `last_rx_n` | 32 (`int`) | variable | 0 while `!rst_n` | Previous sample of `rx_n()`, the comparison the stall detection is built on. |
| `deadlock_seen` | 1 | register (`bit`) | 0 while `!rst_n`; cleared by `reset_dut()` | One-shot: the watchdog reports at most once, so a stuck run prints its diagnosis instead of repeating it every cycle. |
| `ni_pipe` | `[N_RTR-1:0][NI_LAT:0][NUM_VC-1:0]` | array (shift register) | `'0` while `!rst_n` | The NI ejection-credit pipe: one `NI_LAT+1`-deep, `NUM_VC`-wide pipe per router, feeding `ds_credit_valid[LOCAL]` (§2.4). |
| `inj_inflight` | `int` `[N_RTR][NUM_VC]` | array | 0 at time 0, 0 while `!rst_n` | Inflight flits per (router, VC) on the LOCAL injection path. Bounded by `FIFO_DEPTH`; decremented when that router returns a LOCAL credit. |
| `drv_idx`, `drv_vc` | 32 each (`int`) | variable | n/a (scratch) | Driver scratch, deliberately at module scope so only `link_and_inject` can write them. `drv_idx` is the chosen `tx_q` entry, `drv_vc` its VC. |
| `checks` | 32 (`int`) | counter | 0 | Total assertions recorded; incremented by `check`, `check_true` and by every scored flit in `sb_eject` (silent on success, printed on failure). |
| `errors` | 32 (`int`) | counter | 0 | Failures. Three paths bump it directly without a `check`: `send()`'s router-range guard, the driver's VC-range guard, and the watchdog. |
| `cyc` | 32 (`int`) | counter | 0 | Free-running cycle counter, `cyc <= cyc + 1` on posedge. Read *pre-edge* by the logger, so consecutive log entries differ by exactly 1 and `max_gap == 1` means back-to-back. |
| `tag_seq` | 18 (`logic [17:0]`) | register | 18'h0001 | The packet-tag sequence T11 hands out one per packet; tags ride in `data[31:14]` and are how every test identifies its flits. |

Test-local variables (`i0`, `base`, `exp_hops`, `sent`, `n_ht`, the per-test
tags …) live inside the test tasks and are not module scope.

---

## 2. RTL explanation

### 2.1 Chain topology and the `HAS_*` tie-offs (lines 268–344)

A horizontal line at Y = 1, X = 0, 1, 2, with EAST = +X:

```
 (0,1) A --EAST--> B --EAST--> C (2,1)
```

The three instances share `NUM_PORTS(5)`, `NUM_VC(2)`, `LOCAL_IDX(0)`,
`FIFO_DEPTH(8)` and `LOCAL_CREDITS(LOCAL_CRED = 4)`; they differ only in
coordinates and in the presence mask:

| instance | `CUR_X` | `HAS_LOCAL` | `HAS_NORTH` | `HAS_EAST` | `HAS_WEST` | `HAS_SOUTH` |
|---|---|---|---|---|---|---|
| `u_a` | 0 | 1 | 0 | 1 | 0 | 0 |
| `u_b` | 1 | 1 | 0 | 1 | 1 | 0 |
| `u_c` | 2 | 1 | 0 | 0 | 1 | 0 |

A has no WEST neighbour, C has no EAST neighbour, and nobody has a NORTH or a
SOUTH. Those ports are *declared absent* rather than left floating, and that
is the whole point: `router_top` folds each input through its presence mask at
elaboration (`assign l_flit_valid = HAS_P[p] ? in_flit_valid[p] : 1'b0;`) so
an undriven input cannot look like a stream of flits, and it asserts the tie is
never load-bearing — `!HAS_P[p] |-> !a_st_valid[p]` (nothing may be routed out
of a port with no neighbour) and `!HAS_P[p] |-> !(|credit_return_valid[p])`
(no credit may come back on a link that does not exist). Note what is *not*
tied: `router_top` deliberately leaves the outgoing side ungated, so an actual
`out_flit_valid` on an absent port is the bug the assertion is looking for
rather than something the tie hides. The bench carries the same rule on its own
side in two places: `ds_credit_assembly` leaves absent ports at their default
0, and `bad_port_cnt` (§2.5) counts any flit observed leaving a port the router
it left from does not have — NORTH or SOUTH on any of the three, plus A's WEST
and C's EAST.

The LOCAL ports are the network interfaces: the bench injects on one and
ejects on another, and the ejection side hands credits back through the model
in §2.4.

### 2.2 Clock, reset and the drive-on-negedge / sample-on-posedge convention

`clk` free-runs from `initial clk = 1'b0; always #(CLK_PERIOD/2) clk = ~clk;`
and `cyc` increments on every posedge. `reset_dut()` pulls `rst_n` low, waits
five posedges, releases it on a negedge, waits one more negedge, then wipes
`rx`, the hop tallies, `exp_q`, the scoreboard totals, `sb_en` and
`deadlock_seen` so no test can inherit another's debris.

Everything the bench *drives* happens on the negedge (`link_and_inject`, the
watchdog, and the `drain`/`wait_idle` loops all step on `@(negedge clk)`);
everything the DUT *does* happens on the posedge. The two halves of the
convention reinforce each other:

- **Copying at the negedge is a wire.** The DUT's outputs are registers, so
  they change only at a posedge. A copy taken at the negedge in the middle of
  the cycle is therefore bit-for-bit the value the receiving router will sample
  at the *next* posedge — what a continuous wire would deliver, with no link
  latency added and no race at the sampling edge. The same reasoning is why
  `link_and_inject` settles the returned credits at the negedge rather than a
  cycle later: it keeps the inflight count exact instead of one cycle
  conservative.

- **The logger needs one extra negedge before a flit is visible.**
  `rx_logger` runs `always @(posedge clk)` *alongside* the DUT, so its reads
  see **pre-edge** values: at the very edge that launches a flit onto a link it
  still reads the link's previous content, and it records the flit only at the
  *following* posedge. A test that watches `out_flit_valid` rise at the negedge
  inside that cycle therefore finds `rx_n()` unchanged — one more
  `@(negedge clk)` is needed before the entry is there (PROGRESS.md §5 states
  this as a standing rule of the repo). This is invisible in the tests only
  because `drain()` and `wait_idle()` loop over negedges anyway.

- **`cyc` is stamped pre-edge, so a gap of 1 means back-to-back.** The logger
  captures `cyc` in the same active region in which it appends the record,
  before that edge's increment lands. Flits recorded on consecutive posedges
  therefore carry consecutive cycle numbers, which is exactly what
  `max_gap() == 1` asserts: one flit per cycle on that (router, port) pair.

### 2.3 The link and injection driver: `tx_q` and `link_and_inject` (lines 783–925)

One `always @(negedge clk)` process owns every `*_in_*` array — there is no
second driver anywhere, so no element of them can be written from two places.
While `!rst_n` it holds the arrays and `inj_inflight` cleared; otherwise it
runs three steps, in this order:

1. **Settle credits.** For every router and VC, a returned LOCAL credit
   (`r_cred_ret[r][LOCAL_IDX][k]`) decrements `inj_inflight[r][k]`. This is
   the upstream half of the injection contract: the LOCAL input's FIFO is
   `FIFO_DEPTH` deep per VC, and a bench that ignores the return path drives
   that FIFO past its depth and turns every overflow into a bogus failure.

2. **Zero, then copy the four inter-router wires.** `a_in_*[EAST]` ←
   `b_out_*[WEST]`, `b_in_*[WEST]` ← `a_out_*[EAST]`, `b_in_*[EAST]` ←
   `c_out_*[WEST]`, `c_in_*[WEST]` ← `b_out_*[EAST]`. The zeroing first is
   what keeps A's WEST, C's EAST and both NORTH/SOUTH slots at a permanent,
   honest 0.

3. **Inject one flit per router.** A linear scan of the single `tx_q` finds the
   oldest entry whose `rtr` matches (so a router can never overtake its own
   earlier packet, and every index is a plain variable read of one queue). The
   entry's VC is range-checked against `NUM_VC`, and only if
   `inj_inflight[r][vc] < FIFO_DEPTH` is the flit driven onto `LOCAL`,
   `inj_inflight` bumped and the entry `delete()`d — otherwise it stays queued
   for the next negedge, which is how backpressure from the credit loop shows
   up as honest delay rather than as corruption.

Tests reach this path only through `send(rtr, data, vc)`, which guards the
router number (an out-of-range index is reported and counted as an error
instead of silently indexing `tx_q`) and pushes `{rtr, vc, data}`.

### 2.4 Credits: the router-to-router wires and the `ni_pipe` network interface (lines 710–781)

`ds_credit_assembly` is a single `always_comb` that builds all three
`*_ds_cred` arrays, so each has exactly one driver. Two kinds of source, and
they are not interchangeable:

- **Directional ports** get the neighbour's returned credits, wired literally:
  `a_ds_cred[EAST] = b_cred_ret[WEST]`, `b_ds_cred[WEST] = a_cred_ret[EAST]`,
  and the mirror pair between B and C. The asymmetry is the point — a credit
  means "a slot freed in the downstream input port", so A's eastbound link is
  paid by the WEST input port of B that consumed those flits, never by
  anything A itself returned.
- **The LOCAL port** gets `ni_pipe[r][NI_LAT]`.

`ni_pipe` is the network-interface model. At each posedge, a flit observed on
router *r*'s LOCAL output sets stage 0 of that router's pipe for the VC it was
switched onto (indexed by an explicit compare against `k`, not by the 2-bit
sideband directly, so an out-of-range value cannot select past the end); the
stages then shift. With `NI_LAT = 0` stage 0 is wired straight into
`ds_credit_valid[LOCAL]`, and the arbiter counts it at the next posedge — the
two-cycle "flit on the wire → credit usable" shape of section 6's registered
credit return, i.e. "visible g+2, usable g+3" for a flit that went out at g+1.

`NI_LAT` exists so that number can be moved, and it is 0 here on purpose: at
`NI_LAT = 0` the ejection loop is three cycles against `LOCAL_CREDITS = 4`,
full rate with a credit to spare; at 1 it is four against four, still holding
but exactly on the boundary; at 2 it is five against four and the fourth flit
of any back-to-back run stalls for a cycle. The credit-loop test in §3.5 is
what noticed — running it with two more stages of NI latency turned the last
`max_gap` into 2.

### 2.5 The receive log (lines 604–708)

`rx_logger` runs on posedge (while `rst_n`) and sweeps all `N_RTR ×
NUM_PORTS` combinations of `r_out_valid`. Every hit becomes one `rx_t` —
router, port, VC, `cyc` (pre-edge), payload — built field by field, because
this toolchain rejects an `'{...}` assignment pattern passed as an argument.
Order within one cycle is router-major, port-minor, but tests identify flits by
tag, never by slot, so simultaneous packets from different routers cannot be
confused.

While logging it does three things that would otherwise be end-of-test walks:

- **Hop tallies**: `eject_cnt[r]` on `LOCAL`, `east_cnt` on `EAST`,
  `west_cnt` on `WEST`, and `bad_port_cnt` on anything else — where "anything
  else" is tested against the **per-router** presence tables
  `HAS_EAST_P[N_RTR]` and `HAS_WEST_P[N_RTR]` (`A={E,W: 1,0}`, `B={1,1}`,
  `C={0,1}`), so A's WEST and C's EAST land in `bad_port_cnt` alongside NORTH
  and SOUTH rather than being silently absorbed into `east_cnt`/`west_cnt`.
  The presence tables are restated in the bench rather than read back from the
  instances, because `HAS_*` are constants on those instances and their
  elaborated values are not reachable from bench code.
- **Scoreboard**: if `sb_en` and the flit left on `LOCAL`, `sb_eject()` runs
  immediately, so a wrong route is reported on the cycle it happens rather than
  at the end of the test.

The accessors tests are written against are `rx_n()`, `rx_tag()`, `rx_type()`,
`rx_route()` (the `[13:10]` route field *as it appears on a link* — a single
router never consumes its own outgoing route field, so this is the only
outside observation of the next router's merge input), `hop_n(rtr, port, tag)`,
`max_gap(rtr, port, tag)` and `find_tag(tag)`. `clear_rx()` empties the log and
zeroes the tallies between tests.

### 2.6 Flit constructors and the deliberately wrong route field (lines 368–427)

`mk_head`, `mk_ht`, `mk_body` and `mk_tail` build the section 2 formats:
`[1:0]` type, `[3:2]` VC, `[6:4]` dx, `[9:7]` dy, `[13:10]` route, `[31:14]`
tag. Every test passes `DIR_LOCAL` as the header's `route` argument on purpose:
on a LOCAL input port `route_compute` ignores `route_in` entirely and computes
the exit direction from the destination, so the injected value is the one
field in the header that must *not* survive to the wire. If the output-port
merge ever stopped happening, the header would leave with `DIR_LOCAL` instead
of the next hop and T10 would say so.

`mk_body`/`mk_tail` fill `[31:2]` with `{tag, 12'h201}` and `{tag, 12'h401}`
— deliberately non-zero *in `[13:10]`* (`DIR_EAST` and `DIR_WEST`), the exact
field the merge writes. A real direction value there, rather than a run of
zeros, is what makes an unwanted overwrite of a BODY/TAIL observable: the
lookahead for those payload bits is never the value they already carry. These
two constants are kept identical to `tb_router_top`'s, because the chain tests
compare a received body against the one that was sent.

### 2.7 The scoreboard (lines 429–590)

Every packet registered in `exp_q` carries `tag`, `src`, `dest`, `len`, `vc`
and `got` — and deliberately **no expected arrival slot**. `sb_eject(rtr,
data)` runs on every LOCAL ejection while `sb_en` is set and works through:

1. **Match by tag** (`data[31:14]`). No match is a hard failure — "scoreboard:
   flit nobody injected".
2. **No overrun.** `got >= len` before the packet finished is "more flits than
   sent".
3. **Right router.** `pe.dest != rtr` fails.
4. **Position within the packet**, checked by *index*, not by arrival order:
   a one-flit packet must be `HEAD_TAIL`, position 0 must be `HEAD`,
   `len-1` must be `TAIL`, everything between must be `BODY`. The log holds
   every hop of every packet mixed together, so index is the only meaningful
   axis.
5. **Header integrity for heads**: `dx`/`dy` still name the real destination
   (nothing may touch them across two hops), `route[13:10]` reads `DIR_LOCAL`
   at the packet's own destination — the terminating lookahead that tells the
   NI "this is yours" — and `vc[3:2]` still equals the injected VC (assumption
   D3: it rides along as payload and must survive byte-identical).

Only then does it bump `sb_got_flits`, write the entry back and, when `got`
reaches `len`, bump `sb_complete` and decrement `sb_outstanding`.

**Arrival order between independent packets is not checked** — that is a
property this design does not have. An intermediate hop may allocate two
packets different output VCs, and two VCs are allowed to overtake each other;
that is what virtual channels are *for*. What is a property, and what the
scoreboard therefore proves, is per-packet integrity: each packet's own flits
arrive in order, at the right router, exactly once, with their fields intact.
Within a packet the order is checked (rule 4); between packets it is not, and
`exp_q` never recorded a slot to check it against.

### 2.8 The helpers, and why `work_pending()` is two counter reads (lines 592–602, 927–1010)

- **`drain(max_cycles)`** runs negedges until `tx_q` is empty *and* `rx_n()`
  has not moved for 32 consecutive cycles, or the budget runs out, then checks
  `"drain settled within N cycles"`. The quiet window is what makes it safe
  across two hops: the injection queue empties long before the last flit
  reaches its destination, so stopping at "queue empty" would score a run with
  half the traffic still in flight.
- **`wait_idle(max_cycles)`** runs while `work_pending()` and checks
  `"all traffic settled within N cycles"`. Used by T11, where "everything
  arrived" is the actual pass condition rather than an inference from a quiet
  link.
- **`settle()`** (`repeat (12) @(negedge clk)`) is declared but never called
  in this bench — a leftover helper.
- **The watchdog** runs on every negedge: any new `rx` entry clears
  `stall_cnt`, otherwise it grows; when `work_pending()` is still true after
  `MAX_STALL = 500` motionless cycles it raises exactly one
  `"deadlock: no flit moved for 500 cycles"` failure and prints the queue plus
  every incomplete packet's `got/len`, so a wedged credit loop is diagnosed
  instead of hanging the run.

`work_pending()` is the load-bearing little function:

```systemverilog
function automatic bit work_pending();
  return (tx_q.size() > 0) || (sb_outstanding > 0);
endfunction
```

It *could* have been a scan of `exp_q` for an entry with `got < len`, and
originally was — but this toolchain miscompiled it: the function was inlined
into the coroutine running the tests, and the loop's `i++` was hoisted above
the loop, so `i` was set once from an uninitialised value and never advanced
again — the loop spun forever on `i == 1` with no warning (README's gotcha
section documents the exact `__Vtemp` signature in the generated C++). A
counter has no loop to miscompile. So every "how much is left" quantity in the
bench — `sb_outstanding`, `sb_got_flits`, `sb_complete`, `sb_total_flits`, and
the hop tallies — is a running total maintained where the event happens, and
`work_pending()` is a pair of O(1) reads. The watchdog calls it on every clock
edge and `wait_idle()` on every iteration, so O(1) is required anyway.

### 2.9 Recording a pass or a failure (lines 349–366)

`check(what, actual, expected)` increments `checks`, then compares with `===`
and prints `[PASS]` with the actual value, or `[FAIL]` with
`got … exp …` and increments `errors`. `check_true(what, cond)` is the same
for a predicate. Two things worth knowing when reading a transcript:

- `check` prints `actual` as `%h`, so `T11 every packet fully delivered 24`
  is 36 packets and `T11 every hop logged exactly once 12b` is 299 hops.
- `sb_eject` increments `checks` on every scored flit but only prints on
  failure, so the visible `[PASS]` lines are far fewer than the final count.

The `main` block ends with `if (errors == 0) $display("ALL %0d CHECKS PASSED",
checks); else …` and `$finish`. `+vcd` on the run binary dumps
`sim/router_chain.vcd`.

---

## 3. Testing explanation

**Bench:** `tb/tb_router_chain.sv`, top module `tb_router_chain` (1467 lines).
**Run:** `make TOP=router_chain sim` — reports **`ALL 477 CHECKS PASSED`**
(0 `[FAIL]` lines, no assertion errors). Tests execute in the `main` block in
the order below; each starts with `clear_rx()` so the log and hop tallies are
per-test.

### 3.1 T10a — two-hop HEAD_TAIL, A → C (task `t10a_two_hop_head_tail`, 16 checks)

One `HEAD_TAIL` (tag `18'hA_2001`) injected at A for destination (2,1), two
hops away, then `drain(400)`. Exactly 3 log entries are expected, and they
prove the `route_next` story end to end:

- hop 1 left router A via EAST, and its route field reads `DIR_EAST` — A
  computed "B is the next hop" from the destination, *not* from the injected
  `DIR_LOCAL`;
- hop 2 left router B via EAST, and its route field reads `DIR_LOCAL` — B
  rewrote it, because C *is* the destination. This is the check that cannot be
  made on a single router: a router writes the field and then discards it, so
  only a real receiver can show that the field produced was the one the next
  router needed;
- the flit was ejected at C on LOCAL, with type and tag intact at all three
  observation points.

### 3.2 T10b — the same trip in reverse, C → A (task `t10b_two_hop_reverse`, 13 checks)

Tag `18'hB_2002`, injected at C for (0,1). `route_compute` corrects X before
Y, so the westbound walk is a separate code path from the eastbound one, and
B's lookahead must come out pointing WEST into A rather than east into C:
hop 1 leaves C on WEST with route `DIR_WEST`, hop 2 leaves B on WEST with route
`DIR_LOCAL`, and the flit ejects at A. Sending from the far end also proves the
chain does not rely on A happening to be first.

### 3.3 T10c — a four-flit packet across both hops (task `t10c_two_hop_multi_flit`, 48 checks)

HEAD + two BODY + TAIL (tag `18'hC_2003`) from A to C, `drain(600)`, expecting
12 log entries. Three things a single-flit test cannot see:

- the merge happens once per hop, on the head only, and writes a *different*
  value each time (`DIR_EAST` at A, `DIR_LOCAL` at B) — checked at all three
  routers, so a field that was merely forwarded would fail hop 2;
- BODY and TAIL are compared **bit-for-bit** against `mk_body`/`mk_tail` at
  both hops and again after ejection. Their payload carries a real direction in
  `[13:10]`, so a merge applied to every flit instead of to heads changes them;
- all four flits stay together: each index is checked for the right router and
  the right output port, so no hop may drop, duplicate or reroute one.

### 3.4 T10d — the three one-hop legs (task `t10d_single_hop_legs`, 15 checks)

Three `HEAD_TAIL` packets sent in one run (tags `18'hD_2011` A→B, `18'hD_2012`
B→A, `18'hD_2013` B→C), expecting 6 log entries. A→B finishes with
`route_next = DIR_LOCAL` computed at A — the whole "lookahead says terminate"
case in one hop — and its route field is checked to say exactly that. B→A and
B→C cover both directional outputs of the middle router, the only instance
with a neighbour on both sides, using `find_tag()` plus `hop_n()` per leg to
show each packet left once and ejected once. Finally a loop asserts that every
logged flit used only LOCAL, EAST or WEST — nothing ever appeared on an
unwired port.

### 3.5 Section 6 credit loop at full rate (task `t_credit_loop_full_rate`, 8 checks)

One 16-flit packet (`PKT_FLITS`, tag `18'hF_3001`), one VC, from A to C,
`drain(800)`. Four count checks — 16 flits on A's east link, 16 across B's
east link, 16 ejected at C, and 48 entries in total ("nothing else left the
line") — and then the three that matter:

```
CL A->B ran at one flit per cycle          1
CL B->C ran at one flit per cycle          1
CL ejection at C ran at one flit per cycle 1
```

`max_gap == 1` on all three means no link ever stalled, so the credit return
loop closed in time on both hops *and* on ejection. Directional outputs hold
`FIFO_DEPTH = 8` credits against a loop of about 4 and are never in danger;
the interesting hop is C's ejection, where `LOCAL_CREDITS = 4` faces the
three-cycle loop of `NI_LAT = 0`. That is the balance section 6 calls
sustainable, and this test is its confirmation: with two more cycles of NI
latency the fourth flit stalls and this last `max_gap` reads 2 — which is
exactly the failure mode the spec warns about.

### 3.6 T11 — random traffic with a scoreboard (task `t11_random_traffic`, 11 printed + 366 scoreboard checks)

Twelve rounds × three sources = 36 packets. For each: `len = $urandom_range(1,
6)`, destination any *other* router (dest == source on a LOCAL input is not a
legal LOCAL pair in section 2's table), a random VC from `NUM_VC`, and a fresh
tag from `tag_seq`. Each packet is pushed into `exp_q` (so `sb_outstanding`
and `sb_total_flits` grow at generation time), `sb_en` is raised, and
`wait_idle(4000)` waits for the scoreboard to be fully paid. The mix keeps the
middle router forwarding east and west simultaneously, on both VCs. The run
prints `36 packets, 6 of them single-flit, 129 flits`.

Every final check, and what it is really proving:

| Check | Comparison | What it proves |
|---|---|---|
| `all traffic settled within 4000 cycles` | `!work_pending()` | No deadlock: every packet was delivered within budget, not merely "the link went quiet". |
| `T11 every packet fully delivered` | `sb_complete == sent` (36) | Every registered packet reached its `len` — counted per packet, so one packet arriving twice cannot mask another never arriving. |
| `T11 flit conservation (sent == received)` | `sb_got_flits == sb_total_flits` (129) | An independent count of the *same* thing (flits matched by tag, vs flits summed at generation), so a lost flit shows up twice. |
| `T11 the receiver ejected every injected flit` | `eject_cnt[0]+[1]+[2] == sb_total_flits` (129) | The receiver's tally, counted **by port** rather than by tag, reaches the same number: nothing was delivered outside the scoreboard's view (and nothing outside the LOCAL ports). |
| `T11 every hop logged exactly once` | `rx_n() == exp_hops` (299) | The log length is **predicted exactly at generation time** as `sum(len * (\|dest-src\| + 1))` — every flit logs once per link it crosses (XY in a straight line never detours) plus once at ejection. This is the check that catches an extra hop, a repeated log entry, or a flit swallowed on the way; bounding it instead of predicting it would catch almost nothing. |
| `T11 router %0d ejected traffic` (×3) | `eject_cnt[r] > 0` | Every router delivered something — otherwise half the traffic never made it through the middle. |
| `T11 eastbound links carried traffic` | `east_cnt > 0` | The eastbound links were actually used (observed: 85 eastbound + 85 westbound flit-hops, which with 129 ejections is the 299 predicted above). |
| `T11 westbound links carried traffic` | `west_cnt > 0` | Same for the westbound direction — B forwards both ways, not just A→C. |
| `T11 flits avoided the absent ports` | `bad_port_cnt == 0` | No flit ever left through a port the router it left from does not have — NORTH/SOUTH anywhere, plus A's WEST and C's EAST. The bench-side echo of `router_top`'s `!HAS_P[p] \\|-> !a_st_valid[p]`, and a genuinely independent one: the DUT's copy only fires if SVA is enabled, whereas this counter is tallied by the logger whatever the build flags. |

Throughout, the watchdog runs: if a credit loop wedged under this load, the
run fails with the outstanding packets named instead of hanging. The
scoreboard's own per-flit checks (right router, type sequence, intact
destination/route/VC fields) add another 366 checks — see §3.7.

### 3.7 Where the 477 checks come from

- Printed by `check`/`check_true`: T10a 16, T10b 13, T10c 48, T10d 15,
  credit loop 8, T11 11 → **111**.
- Added silently on success by `sb_eject`: 129 scored flits × 2 (right router
  + type sequence) + 36 heads × 3 (dx/dy, route field, VC field) → **366**.
- 111 + 366 = **477**, with `errors == 0`.

### 3.8 Assertion coverage

The Makefile compiles every run with `--assert` (mandatory: without it
Verilator parses `assert property` and silently drops it), so all SVA in
`rtl/` is live for this run, and none of it fired:

- **`fifo.sv`** — the two immediate parameter checks (`WIDTH > 0`, `DEPTH` a
  power of two ≥ 2), evaluated at time 0 in every FIFO instance (one per VC per
  input port: 5 × 2 × 3 = 30 here).
- **`noc_input_port.sv`** — the static flit-encoding check, and the per-VC
  clocking SVA: grant/request/pick consistency, fetch legality, "FIFO protocol
  violations must be unreachable" (`err`, full-write, empty-read),
  output-VC-assignment integrity, flit-type encoding, out-port legality, the
  `HEAD, BODY*, TAIL` sequence assertion, one-hot `sa_pick` and single-grant.
  The sequence and FIFO families are driven hardest here — by T10c's four-flit
  packet, the 16-flit credit-loop packet and T11's 129 flits.
- **`arbiter.sv`** — credit bounds, switch-without-credit, credit-return
  overflow, release/reserve bookkeeping, one-hot pick and grant, grant ⇒
  pick, zero-credit grant, XY-pair legality, one-hot0 direction codes and VA
  row accounting. This bench is the most demanding stimulus they get: the
  section 6 test runs a 16-flit packet at one flit per cycle through the
  `LOCAL_CREDITS = 4` loop, which is precisely where an off-by-one in the
  credit count would show up as `credit_count … out of range` or `switched out
  with no credit`.
- **`crossbar.sv`** — selection in range, idle output silent, and "data and
  route_next name the same input port", exercised by T11's concurrent
  two-directional traffic.
- **`noc_output_port.sv`** — legal lookahead direction, HEAD route actually
  rewritten by the merge, non-HEAD `[13:10]` preserved, `[3:2]` untouched,
  merge confined to `[13:10]`, `flit_valid` exactly one cycle behind a grant,
  and the sideband travelling with its flit. T10a–T10c are written specifically
  to observe this merge from outside (§2.6).
- **`router_top.sv`** — the four cross-block seam properties × 5 ports × 3
  instances = 60 concurrent assertions: grant ⇒ stage-1 pick, grant ⇒
  request, "no credit on a link that does not exist", and "nothing routed to
  an absent port". The two `!HAS_P[p]` properties are the reason this bench
  exists in assertion terms: `tb_router_top` instantiates its single DUT with
  all five ports present, so they are vacuous there. `tools/assert_neg.sh`
  says so explicitly and runs its `router_top` seam case against
  `router_chain`, where A has no west link and nobody has a north or south
  link.
