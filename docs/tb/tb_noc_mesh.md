# `tb_noc_mesh` — `tb/tb_noc_mesh.sv`

The mesh self-test. Every tile sends a packet to every other tile, and the run
is judged on exactly two properties:

1. **Packet integrity.** A flit comes out byte-identical to what went in (a
   header modulo its ROUTE field, which every output port rewrites), each
   packet's flits come out in order, and the network produces no more flits and
   no fewer than it was given.
2. **The correct ejection tile.** A packet comes out on the LOCAL port of the
   tile it was addressed to, and nowhere else.

There is deliberately **no routing oracle** here — no Manhattan distance, no
hop count, no model of the path a packet takes. The bench cannot say how a
packet reached a tile; it can say which tile it must reach and what it must
look like when it gets there (§2.1).

It is the test of `noc_mesh`'s one job: that `ROWS*COLS` routers, wired by that
module and nothing else, pass packets between their LOCAL ports intact and to
the right place. It is *not* a test of `route_compute` (the `router_top` and
`route_compute` benches cover that), not a test of the credit arithmetic (the
input/output port benches and the chain do), and not a measurement of anything
— no latency, no throughput, no distance.

---

## 1. Ports and state

### 1.1 Parameters

Everything under the `EDIT ME -- mesh geometry and traffic shape` banner
(lines 52–114). There is no second place in this file where the shape of the
array is written down, and no place that assumes a 2x2.

| Name | Type | Default | Constraint | Meaning |
|---|---|---|---|---|
| `ROWS` | `parameter int` | 2 | with `COLS`: `ROWS*COLS >= 2` (§2.3) | Rows in the array under test. Passed straight to the `noc_mesh` instance, so one number changes both the stimulus and the array — override with `make TOP=noc_mesh sim ROWS=4 COLS=4`. |
| `COLS` | `parameter int` | 2 | same | Columns; same reasoning. Everything below the banner is written against `ROWS` and `COLS`. |
| `NUM_VC` | `parameter int` | 4 | 2, 4 or 8 (the DUT checks this) | Virtual channels per port. Sizes `inj_vc`/`ej_vc` (`VC_W` bits wide), the ejection-credit vector, `inj_inflight`, and the VC each packet is injected on (`(s+d) % NUM_VC`). |
| `FIFO_DEPTH` | `parameter int` | 4 | power of two `>= 2` | Neighbour input FIFO depth, and three things here at once: it is passed to the DUT, it is the per-VC budget the injection driver enforces on itself (§2.6), and it is the pool lane 2 must exceed (§2.5). |
| `LOCAL_CREDITS` | `parameter int` | `FIFO_DEPTH` | — | The NI receive buffer depth per VC. Its default is written as the expression `FIFO_DEPTH` because linnea_v2 §1 sets the two equal; `make regress` sweeps the knobs one at a time. |
| `MAX_LEN` | `parameter int` | 4 | — | Longest lane-1 packet, in flits. Packet `(s,d)` is `1 + ((s*N + d) % MAX_LEN)` flits long, so the traffic is a fixed function of the geometry: the same `ROWS` and `COLS` always produce the same packets, and a failure reproduces run to run with no seed to remember. |
| `MAX_STALL` | `localparam int` | 500 | — | The watchdog threshold (§2.8): no flit scored, with work still outstanding, for this many cycles and the run is stuck. |
| `INJ_ROUTE` | `localparam logic [3:0]` | `DIR_NORTH` (`4'b0001`) | — | What every injected header carries in its ROUTE field, and why it is not `DIR_LOCAL` (§2.4). |

Also declared in the same block, all `localparam`: `NUM_PORTS = 5`, `VC_W =
(NUM_VC > 1) ? $clog2(NUM_VC) : 1`, `N_TILES = ROWS * COLS`, `CLK_PERIOD =
10ns`, and the two direction codes the bench spells out, `DIR_LOCAL =
4'b0000` and `DIR_NORTH = 4'b0001`.

The `parameter`s except `MAX_LEN` are all handed to the DUT instance (with
`FLIT_W` reached through the value the bench passes from `noc_tb_pkg`), and the
DUT enforces four bounds of its own — `ROWS`/`COLS` `1..8`, `NUM_VC` in 2/4/8,
`FLIT_W >= 16`, `FIFO_DEPTH` a power of two ≥ 2 — fatalling by name; see
`docs/rtl/noc_mesh.md` §1.1. This bench adds one geometry rule of its own on
top: `ROWS*COLS >= 2` (§2.3).

### 1.2 Port declaration

`tb_noc_mesh` is a leaf module with no ports of its own; everything that
crosses its boundary does so through the single `noc_mesh` instance. The table
therefore documents the interface *presented to and extracted from that DUT*,
with the exact packed shapes, because the flat packed boundary **is** the
interface. **Direction is from the DUT's point of view.** The bench's own name
for the last signal is `ej_credit`.

| Signal | Width | Direction | Source → Destination | Working / description |
|---|---|---|---|---|
| `clk` | 1 | input | bench oscillator → `dut`, and every `posedge` process in the bench | `CLK_PERIOD = 10ns`, toggled every 5 ns. Single clock for the whole mesh. |
| `rst_n` | 1 | input | `main` block → `dut` | Active-low *synchronous* reset. Held low for eight negedges so the generator and the driver are never in flight at the same time, then released on a negedge. |
| `inj_data` | `[ROWS-1:0][COLS-1:0][FLIT_W-1:0]` | input | driver (oldest queued flit per tile) → each tile's LOCAL input | One flit per tile per cycle. The bench is every tile's network interface. |
| `inj_valid` | `[ROWS-1:0][COLS-1:0]` | input | driver → DUT | "This cycle's `inj_data`/`inj_vc` is a real flit." Rewritten from scratch every negedge, so idle is a clean 0. |
| `inj_vc` | `[ROWS-1:0][COLS-1:0][VC_W-1:0]` | input | driver → DUT | Which of that tile's input FIFOs the flit buffers into — link sideband, not a header field. |
| `ej_data` | `[ROWS-1:0][COLS-1:0][FLIT_W-1:0]` | output | each tile's LOCAL output → ejection logger / scoreboard | Which `[row][col]` a flit comes out on **is** the answer to "where did it go", so the scoreboard needs no routing model of its own. |
| `ej_valid` | `[ROWS-1:0][COLS-1:0]` | output | DUT → logger, ejection credit pipe | A flit is leaving that tile's network interface this cycle; the logger's only trigger. |
| `ej_vc` | `[ROWS-1:0][COLS-1:0][VC_W-1:0]` | output | DUT → ejection credit pipe | The VC the flit was switched onto on its last hop; decides which VC's LOCAL output credit comes back (§2.6). |
| `lc_credit` | `[ROWS-1:0][COLS-1:0][NUM_VC-1:0]` | output | DUT → injection driver's credit settling | The tile freed a slot in its LOCAL input FIFO: this bench's injection budget, one per flit it pushed in. |
| `lc_ds_credit` | `[ROWS-1:0][COLS-1:0][NUM_VC-1:0]` | input | ejection credit pipe (bench signal `ej_credit`) → DUT | The bench is finished with an ejected flit, so the tile's arbiter may spend that LOCAL output slot again. |

Wiring discipline (README "Testbench Wiring Rules"): every one of those
connections carries a whole array, never an element select — the per-tile
indexing all happens on the bench side.

### 1.3 Registers and state

Everything declared at module scope that is not part of §1.1. `Kind` says what
the declaration *is*; `Reset` says what clears it in a simulation.

| Name | Width | Kind | Reset | Working / description |
|---|---|---|---|---|
| `clk`, `rst_n` | 1 each | variable (clock / reset) | `clk` starts 0 and self-toggles; `rst_n` 0 at time 0, released by `main` | Shared nets; both are in §1.2 as DUT ports. |
| `inj_*`, `ej_*`, `lc_credit`, `ej_credit` | see §1.2 | wire (logic) | `inj_*` cleared by the driver while `!rst_n`, `ej_credit` cleared by the pipe | The whole DUT interface. Driven only by the two processes named in §2.6; the rest of the bench reads them. |
| `exp_t`, `tx_t` | structs | typedef | n/a | The two record types: one injected packet's reference, one queued flit. Every queue below is a queue of these structs — never `type q[N][$]`, which this simulator corrupts under a run-time index (§2.6). |
| `next_tag` | `TAG_W` (26) | register | `'0` at declaration | The tag sequence: one fresh tag per injected packet, so `find_tag()` can name exactly one in-flight packet. |
| `exp_q` | dynamic queue of `exp_t` | queue | starts empty; `inject_pkt()` pushes, `sb_eject()` rewrites one entry's `got` | The reference every ejection is scored against: one entry per injected packet recording the *decision* — source, destination tile, length, VC, KIND — and a running `got` count. Deliberately records **no** expected arrival slot (§2.7). |
| `tx_q` | dynamic queue of `tx_t` | queue | starts empty; `inject_pkt()` pushes, the driver `delete()`s | The single injection queue, carrying the source tile *inside* the entry rather than being one queue per tile. Oldest matching entry wins. |
| `tx_left` | 32 (`int`) | counter | incremented per flit queued, decremented per flit driven | Flits still queued for injection. |
| `sb_outstanding` | 32 (`int`) | counter | `+1` at registration, `−1` when `got == len` | Packets registered that have not delivered their last flit yet. |
| `sb_got_flits` | 32 (`int`) | counter | `+1` per scored flit | Flits the scoreboard matched — the "received" half of flit conservation, and the watchdog's motion signal. |
| `sb_complete` | 32 (`int`) | counter | `+1` per packet reaching `len` | Packets fully delivered. |
| `sb_total_flits`, `sb_packets` | 32 each (`int`) | counter | `+len` / `+1` at generation | What the generator built; the totals the final checks compare against. |
| `work_pending()` | — | function | n/a | True while `tx_left > 0` or `sb_outstanding > 0` — two reads, O(1), and containing no loop at all (§2.8). |
| `inj_inflight` | `int` `[ROWS][COLS][NUM_VC]` | array | 0 at time 0, 0 while `!rst_n` | Flits in flight into one tile on one VC, from this bench's side of the LOCAL link. Bounded by `FIFO_DEPTH`, which is how deep that input FIFO is. |
| `drv_s`, `drv_sc`, `drv_idx`, `drv_vc` | 32 each (`int`) | variable | n/a (scratch) | Driver scratch, deliberately at module scope so only the injection driver can write it. `drv_idx` is the chosen `tx_q` entry; `drv_vc` its VC. |
| `ej_credit` | `[ROWS-1:0][COLS-1:0][NUM_VC-1:0]` | register (pipe) | `'0` while `!rst_n`, cleared every posedge otherwise | The ejection credit pipe (§2.6): one credit, one cycle late, on the VC the ejected flit used. |
| `eject_cnt` | `int` `[ROWS][COLS]` | array | 0 at declaration | Per-tile count of flits that left on the LOCAL port, counted by port at log time — the raw material for the coverage check. |
| `sb_en` | 1 | register (`bit`) | 0 at declaration; set once after `build_traffic()` | Arms `sb_eject`. Traffic is built while reset is still low, so nothing that happens before the run starts is scored. |
| `stall_cnt`, `last_scored` | 32 each (`int`) | counter / variable | 0 while `!rst_n` | The progress watchdog's state (§2.8): consecutive cycles with no new scored flit, and the sample it is compared against. |
| `deadlock_seen` | 1 | register (`bit`) | 0 while `!rst_n` | One-shot: the watchdog reports at most once, and `wait_idle()` then stops waiting instead of burning the rest of its budget. |
| `checks`, `errors` | 32 each (`int`) | counter (in `noc_tb_pkg`) | 0 | The shared reporter this bench imports — `check()`, `check_true()`, `report_stats()` (§2.9). |

---

## 2. RTL explanation

### 2.1 The contract: two properties, and no oracle (lines 3–44)

The header states the whole test: packet integrity, and the correct ejection
tile. Everything else is deliberately left out:

> There is deliberately no routing oracle here -- no Manhattan distance, no
> hop count, no model of the path a packet takes. The bench cannot say how a
> packet reached a tile; it can say which tile it must reach and what it must
> look like when it gets there.

The reason is that baking a routing algorithm into the scoreboard would turn
any legitimate routing change into a regression read, and would make the test
answer a question nobody asked. Note the two properties are *not* symmetric:
"which tile" is a fact the packet itself carries (the destination fields the
bench wrote at generation time), and "what it must look like" is a fact the
bench knows because it built the flit. "Which way did it get there" is neither —
it is a property of the implementation, and the implementation is allowed to
change it.

The same comment spells out what this is not: not a `route_compute` test, not
a credit-arithmetic test, and not a performance measurement — no latency,
throughput or Manhattan number is computed anywhere in the file. It also notes
the bench's field discipline: tests name fields, never bit positions and never
signals — `flit_dst_x(h)`, `flit_route(h)`, `mk_head(…)`, `ROUTE_MASK` all come
from `noc_tb_pkg`, the only file that knows where the bits are, so moving a
field in the header moves this file's behaviour or does not compile rather than
silently keeping the old slice. The whole bench sees four groups of DUT
signals (§1.2); every inter-router wire in the mesh is `noc_mesh`'s business.

### 2.2 The EDIT ME block (lines 52–114)

The banner carries the run command it exists for:

```systemverilog
//   make TOP=noc_mesh sim ROWS=4 COLS=4
```

`ROWS`/`COLS` are `parameter`s declared there and passed straight to the DUT
instance, so the make variables reach both the stimulus and the array under
test from one number (the Makefile turns them into `-GROWS=`/`-GCOLS=`, which
is also what the rebuild stamp hashes, so changing the geometry rebuilds).
`NUM_VC`, `FIFO_DEPTH`, `LOCAL_CREDITS` and `MAX_LEN` sit beside them, and
§1.1 explains what each is used for.

The banner also says which geometries are worth running: `1x1`, `2x2`, `3x3`
and `2x3` — with the "walls" note pointing at §2.3 for why the small ones are
not trivial. 3x3 is the smallest geometry with an interior tile that has four
neighbours; 1x2 and 2x1 are the smallest that exercise an edge tile sending
across the array, and `make regress` runs exactly those four beyond the
default.

### 2.3 A tile never sends to itself (lines 246–269)

`build_traffic()` walks every ordered pair of tiles and skips `s == d` on
purpose. This is a design property, not an oversight:

- Spec §2 enumerates "XY legal (input -> output) pairs, 16 of 25" and
  **LOCAL → LOCAL is not one of them**. The four LOCAL outputs are N, E, W, S;
  a packet injected at a router has to leave it.
- `route_compute` will happily compute `DIR_LOCAL` for a packet addressed to
  the tile it was injected on (its step 1 computes the exit port fresh from the
  destination, and the destination *is* this tile).
- The arbiter's `xy_legal` assertion then fires **on the grant** — `sa_gnt … |->
  xy_legal(port, dir_to_idx(out_port))` — which is the point at which an
  illegal turn would actually reach the crossbar. LOCAL → LOCAL is the
  `p == 0, o == 0` case the function does not list.
- Spec §2's table sides with the arbiter: "Anything else is a bug: assert on
  it." So loopback belongs to the network interface, not to the network, and
  the traffic generator never asks for it.

That also makes **1x1 unusable as a traffic test**: with one tile and no
self-send there is no legal pair at all, so the bench rejects the geometry at
time 0 rather than letting it pass with zero checks:

```systemverilog
initial begin
  assert (N_TILES >= 2)
  else $fatal(1, "tb_noc_mesh: ROWS*COLS must be >= 2 -- section 2's XY table has no LOCAL->LOCAL pair, so a single tile has nothing legal to send to (got %0dx%0d)", ROWS, COLS);
end
```

The `initial` block runs at time 0, before reset is released and before the
generator is called, so an illegal geometry dies as a configuration error
rather than as an empty green run. Hence `1x1` is deliberately absent from the
Makefile's `MESH_GEOMS`.

### 2.4 Why `INJ_ROUTE` is `DIR_NORTH` and not `DIR_LOCAL` (lines 98–114)

```systemverilog
localparam logic [3:0]  INJ_ROUTE = DIR_NORTH;
```

On a LOCAL input port `route_compute` ignores `route_in` entirely (its step 1
computes `route_self` from the destination for `IS_LOCAL_PORT`, and only the
directional instances read `route_in`), so this value is dead the instant the
flit is built — and that is the point. It must **not** survive to the wire:
`noc_output_port`'s header merge replaces it with the lookahead on every head,
at every hop, so a flit that arrives anywhere still carrying it means a merge
did not happen.

It is deliberately *not* `DIR_LOCAL`, which is what `tb_router_chain` injects.
`DIR_LOCAL` is also the correct value at ejection — the terminating router
stamps exactly that (§2.7) — so a bench that injects it catches a missing merge
only on multi-hop packets, where an intermediate hop's lookahead would be the
surviving non-LOCAL value. On a small mesh most packets are one hop, and
`DIR_LOCAL` would leave those checking nothing at all: the value arriving is
the value injected whether or not the merge ran. A direction that is simply
wrong for every packet makes the check bite on all of them, and costs nothing
when the merge works, because `route_compute` never reads the field on a LOCAL
port.

### 2.5 The two traffic lanes (lines 271–358)

Both lanes funnel through one task, `inject_pkt(s, d, len, vc, kind)`, so the
bookkeeping exists once and cannot drift between them: it allocates the tag,
pushes the `exp_t` reference, bumps `sb_packets` / `sb_total_flits` /
`sb_outstanding`, and pushes one `tx_t` per flit — each built by `exp_flit()`
from the same reference the scoreboard will later score against.

**Lane 1 — `inject(s, d)`: the shape the pattern picks.**

```systemverilog
len = 1 + ((s * N_TILES + d) % MAX_LEN);
inject_pkt(s, d, len, (s + d) % NUM_VC, (s + d + len) % 4);
```

Deterministic rather than drawn: an RNG draw would shift every later packet's
shape and make "did this change alter the traffic?" unanswerable the first time
something moves. It covers `1..MAX_LEN` flits, so a lone `HEAD_TAIL` crosses
the mesh as well as a multi-flit packet.

**Lane 2 — `inject_long(s, d)`: length chosen only to exceed a link's credit
pool.**

```systemverilog
inject_pkt(s, d, FIFO_DEPTH + 1, (s + d) % NUM_VC, (s + d + 1) % 4);
```

The reasoning, straight from the comment: a packet keeps one VC for its whole
trip (the arbiter switches each flit out on its input VC), and the credit pool
for a (link, VC) pair holds `FIFO_DEPTH` flits — the init value in
`arbiter.sv`'s `credit_init`, where every non-LOCAL output starts at
`DIR_CREDITS` = `FIFO_DEPTH`. So a packet of `FIFO_DEPTH + 1` flits cannot
cross a link unless that link's credit return wire is actually carrying credits
back.

**Why the lane exists.** Lane 1 alone tops out at `MAX_LEN`, and at the default
`FIFO_DEPTH = 4` that is exactly the pool, so a packet can cross a link on the
credits it started with and the network never has to hear an answer. The
concrete evidence the comment gives: move the northbound credit return to the
wrong neighbour port and the default 2x2 run **still passes**, because the
heaviest thing it ever asks of that link is three flits on one VC — which fits
the 4-credit pool. One extra packet per pair, and every directed link carries
at least one pair's XY path, forces a credit round-trip through every link in
the mesh instead.

This is not a routing model or a timing oracle: nothing in lane 2 counts hops
or measures latency, it only makes the packets big enough that the wiring this
module owns has to work.

`build_traffic()` then runs both lanes over every ordered pair with `s != d`,
using flat tile indices because `inject()` derives the coordinates — two nested
loops, and "every ordered pair except the diagonal" reads directly.

### 2.6 The injection driver and the ejection credit pipe (lines 360–463)

**The driver** is one `always @(negedge clk)`, running after the edge that
delivered this cycle's credit returns, in three steps:

1. **Settle credits.** For every tile and VC, a returned LOCAL credit
   (`lc_credit[r][c][k]`) decrements `inj_inflight[r][c][k]`.
2. **Zero the three boundary arrays**, so an idle tile drives a clean 0 rather
   than a stale 1.
3. **At most one flit per tile.** A linear scan of the single `tx_q` finds the
   *oldest* entry for that tile — which preserves arrival order, so a tile can
   never overtake its own earlier packet, and keeps every index a plain
   variable read of one queue. The entry's VC is range-checked against
   `NUM_VC` (a bad number becomes a reported failure instead of a silently
   indexed queue), and the flit is driven only while
   `inj_inflight[r][c][vc] < FIFO_DEPTH`. Otherwise it stays queued for the
   next negedge — which is how backpressure from the credit loop shows up as
   honest delay rather than as corruption.

The queue is *one* queue carrying the source tile alongside the flit, not an
array of queues (`tx_t q[N_TILES][$]`): an array of queues with a variable
index corrupts silently in this simulator — `push_back` writes the wrong
element. A single queue indexed by a variable is well behaved.

**The ejection credit pipe** is one `always @(posedge clk)`: a flit observed on
a tile's LOCAL output sets that tile's credit on the VC the flit was switched
onto, one cycle later, and the whole register is cleared every edge so it is
exactly one pulse per ejected flit. Two cycles from "flit on the wire" to
"credit usable" — the same loop the line bench measures at `NI_LAT = 0`
(`docs/tb/tb_router_chain.md` §2.4). Returning the credit on a *different* VC
would refill a pool nobody was drawing from, which is why `ej_vc` is decoded
against each `k` explicitly rather than used as an index.

### 2.7 The scoreboard (lines 465–579)

The ejection logger runs on posedge while `rst_n`, sweeps every tile, bumps
`eject_cnt[r][c]` and — if `sb_en` — calls `sb_eject(r, c, data)` the moment a
flit reaches its destination's network interface, so a wrong route is reported
at the cycle it happens rather than at the end of the run.

`sb_eject` works through, in order:

1. **Match by tag.** `flit_tag(data)` against `exp_q` (`find_tag()` is a
   linear scan; tags are handed out one per packet by `next_tag`, so exactly
   one entry can match). No match is a hard failure: *"flit … ejected at
   (r,c) was injected by this bench"*.
2. **No overrun.** `got >= len` before the packet finished is *"packet …
   delivers no more than its N flits"*.
3. **The ejection tile.** `rr == pe.dr && cc == pe.dc` — *"packet … reaches
   (dr,dc), the tile it was sent to"*. This is the whole routing question the
   test asks.
4. **The flit itself**, against a reference *rebuilt* rather than stored:
   `exp_flit(pe, pos)` calls `mk_ht` / `mk_head` / `mk_tail` / `mk_body` with
   the packet's own destination, route, KIND and tag, so given the packet and
   the position within it the expected flit is reproduced exactly — no copy of
   the stimulus is kept and no queue is walked to find one.
   - A header (position 0) is compared with the ROUTE field masked off:
     `data & ~ROUTE_MASK` against `want & ~ROUTE_MASK`. ROUTE is the one field
     every output port on the way is allowed to rewrite, so a header may differ
     in it and nothing else.
   - A BODY or TAIL is compared **whole** — the merge must not reach it — and
     the package's payload constructors put a deliberately non-zero filler
     where the merge writes, so an unwanted splice changes something visible.
5. **The fields routers must leave alone** (heads only):
   - **KIND** — written once by the source, and routers are not its consumer,
     so it must come out of any number of hops identical to what was injected:
     the whole content of assumption D3, now that this field is KIND rather
     than a VC id.
   - **`flit_route(data) == DIR_LOCAL`** — the terminating router stamps
     `DIR_LOCAL` into the lookahead it writes on the way out, because its own
     `route_compute` says "this packet ends here". Since ROUTE is the one
     header field allowed to differ from what was sent, this is also where a
     missing merge shows up (§2.4).

Only then does it bump `sb_got_flits`, write the entry back (one queue, one
computed index, no in-place field write on a queue element) and, when `got`
reaches `len`, bump `sb_complete` and decrement `sb_outstanding`.

**Arrival order between independent packets is not checked** — `exp_t`
records no expected arrival slot. Two packets on different VCs may legally
overtake each other, so the order in which independent packets arrive is not a
property of this design. What is a property, and what `got`/`len`/`dr`/`dc`
therefore prove, is per-packet integrity: each packet's own flits arrive, in
order, at its own tile, exactly once.

### 2.8 The progress watchdog, and why `work_pending()` has no loop (lines 581–628)

The watchdog is a **stall counter, not a timeout**. On every posedge it
compares `sb_got_flits` against the previous sample: any movement resets
`stall_cnt`, otherwise it grows. It fires only when `stall_cnt > MAX_STALL`
(500) *and* `work_pending()` is still true — so a slow run that is still moving
is never mistaken for a deadlock — and it reports exactly one failure, naming
how many flits were delivered and how many quiet cycles had passed, which is
the number that says whether the mesh wedged in the network or at the injection
boundary. `deadlock_seen` makes it one-shot, and also tells `wait_idle()` to
stop waiting instead of spinning out the rest of its budget.

`wait_idle(40000)` is the outer loop: it runs negedges while `work_pending()`
and then checks *"all traffic settled within 40000 cycles"*. `settle()` is
twenty more negedges so a straggler still in flight after the queue drains gets
a chance to be scored rather than silently missed.

The function the watchdog and `wait_idle()` both lean on must contain **no
loop at all**:

```systemverilog
function automatic bit work_pending();
  return (tx_left > 0) || (sb_outstanding > 0);
endfunction
```

It *could* have been a scan of `exp_q` for an entry with `got < len`, and a
previous bench had it walk a queue instead — this toolchain hoisted the loop
counter out of that loop when inlining the function into the coroutine that
runs the tests: the counter was set once, never incremented, and the test spun
forever. A counter has no loop to miscompile. That is why every "how much is
left" quantity in the bench (`tx_left`, `sb_outstanding`, `sb_got_flits`,
`sb_complete`, `sb_total_flits`, `sb_packets`) is a running total maintained
where the event happens, and `work_pending()` is two O(1) reads — which it has
to be anyway, since the watchdog calls it on every clock edge.

### 2.9 Coverage, conservation and the report (lines 630–717)

After `wait_idle()` and `settle()`, the `main` block runs:

- **`every packet fully delivered`** — `sb_complete == sb_packets`. Packets
  counted individually, so one packet arriving twice cannot mask another never
  arriving.
- **`flit conservation (built == scored)`** — `sb_got_flits == sb_total_flits`.
  An independent count of the *same* thing: flits matched by tag against flits
  summed at generation, so a lost flit shows up twice.
- **`the tiles ejected every injected flit`** — the receiver's own tally,
  summed from `eject_cnt` by port rather than by tag, reaches the same number:
  nothing was delivered outside the scoreboard's view.
- **Per-tile coverage** — `check_coverage()` asserts `eject_cnt[r][c] > 0` for
  every tile. Without it, a mesh where one row was simply never wired would
  still pass: its packets would never arrive, but the scoreboard only follows
  packets that did.
- **`final_report()`** prints the geometry, packet/flit totals, a note if the
  watchdog fired, and `report_stats()` — `ALL <n> CHECKS PASSED` or
  `<err>/<n> CHECKS FAILED`.

Everything above is reached in one `initial` block: hold reset for eight
negedges, `build_traffic()`, raise `sb_en`, release reset, `wait_idle(40000)`,
`settle()`, the three conservation checks plus per-tile coverage, report,
`$finish`. Reset is held
until the traffic exists so the generator and the driver are never in flight
at the same time: the driver owns `tx_q` from the moment `rst_n` rises.

---

## 3. Testing explanation

**Bench:** `tb/tb_noc_mesh.sv`, top module `tb_noc_mesh`.

### 3.1 How to run it

```
make TOP=noc_mesh sim                    # default geometry, 2x2
make TOP=noc_mesh sim ROWS=4 COLS=4      # any geometry; the make variables
                                         # become -GROWS/-GCOLS and force a
                                         # rebuild (the stamp hashes them)
make TOP=noc_mesh lint                   # clean, full -Wall over rtl/*.sv
```

`+vcd` on the run binary (`./obj_dir/v_noc_mesh/run +vcd`) dumps
`sim/noc_mesh.vcd`. `make regress` phase 4 repeats the run at `1x2`, `2x1`,
`3x3` and `2x3` with the same `ROWS=`/`COLS=` form.

### 3.2 Results at every geometry

| Geometry | Final output | packets | flits |
|---|---|---|---|
| 2x2 (default) | `ALL 236 CHECKS PASSED` | 24 | 90 |
| 1x2 | `ALL 44 CHECKS PASSED` | 4 | 15 |
| 2x1 | `ALL 44 CHECKS PASSED` | 4 | 15 |
| 3x3 | `ALL 1389 CHECKS PASSED` | 144 | 544 |
| 2x3 | `ALL 580 CHECKS PASSED` | 60 | 225 |

The generator is a fixed function of the geometry (§2.5), so the packet and
flit totals follow from its formula; at 2x2 they reproduce the run's own
printed `24 packets, 90 flits injected, 90 flits scored`. 1x2 and 2x1 are not
the same test — one leaves every tile without north/south links, the other
without east/west, so each exercises two of `noc_mesh`'s four walls.

### 3.3 Where the checks come from

Five contributors, and the sum is closed for every geometry above:

| Source | Count |
|---|---|
| Scoreboard, per scored flit: ejection tile + flit compare | `2 × flits` |
| Scoreboard, per head (position 0): KIND + `DIR_LOCAL` | `2 × packets` |
| Final: fully delivered + flit conservation + tiles ejected everything | 3 |
| Coverage: one per tile | `ROWS*COLS` |
| `wait_idle`'s settle check | 1 |

At 2x2: `2×90 + 2×24 + 3 + 4 + 1 = 236`. The same expression gives 44, 44,
1389 and 580 for the four other geometries in the table. Nothing else
contributes in a passing run: the watchdog's progress check and the driver's
VC-range guard are both failure-only paths.

### 3.4 What the bench deliberately does not check

- **No routing oracle.** No Manhattan distance, no hop count, no expected
  path — see §2.1. Which tile a packet reaches is checked; how it got there is
  not, because that is an implementation choice.
- **No arrival order between independent packets**, for the reason in §2.7:
  different VCs may legally overtake.
- **No latency or throughput measurement.** No cycle counts, no `max_gap`, no
  link-rate assertion — that is the chain bench's job (`tb_router_chain` §3.5).
- **No observation of any inter-router wire.** The bench sees only the four
  signal groups of §1.2; the links between tiles are never sampled by anything
  in this file. The boundary outward faces do have a watcher — `noc_mesh`'s own
  `walls` block (`docs/rtl/noc_mesh.md` §3.2) — and that is a property of the
  DUT, not of the bench (§3.5).
- **1x1 is rejected, not tested** (§2.3) — there is no legal traffic to send.

### 3.5 Assertion coverage

The sim build carries `--assert`, so every `assert property` in `rtl/` is live
for the whole run, and none of it fires in a passing run:

- **`arbiter.sv`** — including the XY-legality assertion quoted in §2.3
  (`sa_gnt |-> xy_legal(...)`), which is the one that would catch a loopback
  request, plus the credit-bound and grant-consistency families. Lane 2's
  `FIFO_DEPTH + 1`-flit packets (§2.5) are what push the credit families hard:
  every directed link in the mesh carries at least one pair's path, and each
  such link must now round-trip a credit to get the packet across.
- **`router_top.sv`** — the four cross-block seam properties on all five ports
  of every tile, of which the two `HAS_P`-gated ones ("nothing routed out of
  an absent port", "no credit on a link that does not exist") are non-vacuous
  on every boundary tile — and every mesh the bench runs has boundary tiles,
  unlike `tb_router_top`, which ties all five ports present.
- **`rtl/noc_mesh.sv`** — the four `walls` assertions of the module under test
  (`docs/rtl/noc_mesh.md` §3.2), watching the outward face of every boundary
  link. This is the check a flit routed off the top edge of the array lands in.
- **The immediate parameter checks** — `noc_mesh`'s four `initial`-block
  `$fatal`s (illegal geometry or knobs die at time 0) and `fifo`'s two bounds
  in every VC FIFO of every tile.

`make TOP=noc_mesh lint` compiles only `rtl/*.sv` at full `-Wall` and is
clean; nothing in `tools/` targets this file, so these assertions are proven
by the run itself rather than by the negative suites.
