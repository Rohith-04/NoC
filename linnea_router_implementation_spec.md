# Project Linnea — Router Implementation Spec (v1)

Everything needed to finish the router RTL: decisions, timing model, per-module signals and equations, seams, tests, build order. Supersedes `linnea_router_design_reference.md` wherever they disagree (changes are listed in section 9). The FIFO is separately built and verified and is not covered here except for the interface assumptions in section 7.

Methodology reminder: for each module, prose (this doc) -> datapath with register boundaries -> timing diagram -> RTL as a transcription. Section 3 is the reference timeline; check your own waveforms against it.

---

## 1. Decisions

### 1.1 Locked

- Full 5x5 crossbar. 2 VCs per port (`NUM_VC = 2`), FIFO depth 4, 32-bit flits, XY DOR, lookahead routing.
- VA then SA, sequential, no speculation. VA is a flat separable allocator (row arbiter per output VC over `5*NUM_VC` requesters, column arbiter per requester), HEAD_TAIL over HEAD, round-robin within tier. Flat-VA scaling cost with VC count is accepted.
- SA is two-stage: per-input VC pick (credit-masked), then one single-winner round-robin arbiter per output port.
- VA grant: allocator is combinational in the request cycle; the input port latches `assignment_valid` and `out_vc` at the clock edge; SA requests start the next cycle. The arbiter does not register its grant outputs.
- The arbiter learns "last flit" from the level signal `sa_req_last`, ANDed with its own grant. HEAD_TAIL counts as last.
- One RC instance per VC. `route_next` is a combinational passthrough (no register) with its own 4-bit path to the output port.
- LOCAL output is flat with the other ports (VCs, VA, credits).
- FIFO has registered `data_out`: read in cycle t gives the flit on `data_out` in t+1. `data_out` is the per-VC head register.
- `head_valid` is aligned with the data (high in the cycle the flit is on `data_out`). Route capture is triggered by the fetch-arrival event, not by a `head_valid` edge.
- Fetch rule (option ii): `fetch = (!head_valid || sa_gnt) && (!fifo_empty || fifo_wr_enable)`. On a same-cycle fetch and grant the fetch wins and `head_valid` stays 1. This gives 1 flit per cycle per VC.
- SA and ST fuse into the grant cycle (`data_out` is held until the grant, so no ST register). The link register is the LT boundary.
- Credits return on the prefetch read. `data_out` is extra storage not counted in credits (5 slots vs 4 credits: conservative, safe).
- Credit counters (per output port, per VC, init 4) live in the arbiter. A +1 and a -1 in the same cycle net to 0.
- Signal naming: stage, then direction, then field.

### 1.2 Assumed in this spec, needs your confirm or veto

| # | Assumption | Why | If you veto |
|---|---|---|---|
| D1 | Credit return is a per-VC vector (`credit_return_valid[NUM_VC]`), not one pulse plus a VC tag. | Credit return is tied to fetch, not switch. Two VCs can fetch in the same cycle (one on a grant, one idle), so a single tag can't carry both. The old "one flit switched per port per cycle" argument no longer applies. | Serialize fetches to one per port per cycle (costs throughput and an extra pick). |
| D2 | VA is not credit-gated; only SA is. | The reference doc puts credits in SA only. A VC reserved with zero credits just waits in SA. The old session summary mentioned VA gating; this treats it as superseded. | Add `credit_count != 0` to VA's row eligibility. |
| D3 | The HEAD flit's `VC_ID` field `[3:2]` is ignored by routers. The sideband `vc_id` is authoritative and header merge never rewrites it. | Otherwise the field is stale after the first hop. | Header merge also rewrites `[3:2]` with the downstream VC; adds a mux on the output path. |
| D4 | `credit_return_valid` is registered one cycle after the fetch. | Keeps the credit wire off the input port's combinational path. Credit loop is about 3 cycles against 4 credits (section 6). | Drive it combinationally (saves 1 cycle of loop, longer path). |

---

## 2. Parameters and encodings

```
NUM_PORTS = 5      NUM_VC = 2      FIFO_DEPTH = 4      CUR_X, CUR_Y (per router, compile-time)
LOCAL_CREDITS = depth of the NI's receive buffer per VC (init value for credit_count[LOCAL][*])
```

Flit type `[1:0]`: `00 BODY, 01 HEAD, 10 TAIL, 11 HEAD_TAIL`.
- `is_head = type[0]` (HEAD, HEAD_TAIL). `is_last = type[1]` (TAIL, HEAD_TAIL). Both shortcuts depend on this encoding; keep an assertion tying them to it.

Route direction (4 bits): `0000 LOCAL, 0001 NORTH, 0010 EAST, 0100 WEST, 1000 SOUTH`. Y grows downward, so increasing Y is SOUTH.

Port index (used for `xbar_sel`, array indices): `LOCAL 0, NORTH 1, EAST 2, WEST 3, SOUTH 4`. A direction maps to an index by its set-bit position plus one (`0000` maps to 0). Input port N means the port facing the north neighbor. An EAST output wires to the neighbor's WEST input.

Flit formats (32 bits):
```
HEAD       [31:14] reserved  [13:10] ROUTE  [9:7] DEST_Y  [6:4] DEST_X  [3:2] VC_ID (ignored by routers, D3)  [1:0] TYPE
BODY/TAIL  [31:2] payload                                                                                      [1:0] TYPE
HEAD_TAIL  [31:14] payload (18b)  [13:10] ROUTE  [9:7] DEST_Y  [6:4] DEST_X  [3:2] VC_ID                       [1:0] TYPE
```
Open for the NI, not the router: there is no SRC field, and 18 bits can't hold an AXI request address.

XY legal (input -> output) pairs, 16 of 25:
- LOCAL -> N, E, W, S
- N -> S, LOCAL; S -> N, LOCAL
- E -> W, N, S, LOCAL; W -> E, N, S, LOCAL

Anything else is a bug: assert on it.

---

## 3. Reference timeline (idle router, FIFO empty)

3-flit packet H, B, T arriving back-to-back on E input VC0, destined for the W output. Assumes credits available and the downstream output VC free.

| Cycle | Input link / FIFO | Input port VC0 | Arbiter | Output |
|---|---|---|---|---|
| c0 | H on link, `flit_valid`, `vc_id=0`. `fifo_wr_enable=1` | `fetch=1` (bypass: `!head_valid && wr_enable`) | | |
| c1 | B on link. B is written into the FIFO RAM because `head_valid=1` and no grant | H on `data_out`. `head_valid=1`, `arrive=1`. RC live. `va_req=1`, `va_req_out_port = rc_route_self`. End of c1: `out_port`, `out_vc`, `assignment_valid` latched | VA grants (combinational). `alloc_busy[W][k]` set at the edge | |
| c2 | T on link, written to FIFO | `sa_req=1`. `sa_gnt=1`. `fetch=1` (B is in FIFO) | stage 1 picks VC0 (credit ok), stage 2 grants. `xbar_sel[W]=E`. `credit_count[W][k]` decrements at the edge | ST: H crosses the crossbar. Header merge writes `route_next` into `[13:10]`. Link register loads at the edge |
| c3 | | B on `data_out`. `arrive=1`, no capture (not a head). `sa_req=1`, `sa_gnt=1`. `fetch=1` (T) | grant | **H on the output link.** B crosses the crossbar |
| c4 | | T on `data_out`. `sa_req_last=1`. `sa_gnt=1`. FIFO empty, so `fetch=0`. At the edge `head_valid` goes 0 and `assignment_valid` goes 0 | grant. `alloc_busy[W][k]` clears at the edge | B on the output link |
| c5 | | idle | | T on the output link |

Per-hop latency (flit on the input link to the same flit on the output link) is 3 cycles. Steady-state throughput is one flit per cycle per VC. Back-to-back packets in the same VC work: a new HEAD arrives into a VC whose `assignment_valid` cleared at the previous TAIL's grant.

If VA denies the HEAD in c1, it re-requests in c2 with `va_req_out_port = out_port` (captured at the end of c1).

Critical paths (find them in synthesis, don't guess):
- `sa_req -> credit mask -> stage-1 pick -> stage-2 arbiter -> xbar_sel -> crossbar mux -> header merge -> link reg` (SA+ST fused).
- `sa_gnt -> fetch -> FIFO read enable` (new, from option ii).
- Local port only: `data_out header -> compute_dir -> va_req_out_port -> VA allocator -> latch`.

---

## 4. Module specs

### 4.1 `route_compute` (one per VC)

```
module route_compute #(CUR_X, CUR_Y, IS_LOCAL_PORT) (
  input  [2:0] dest_x, dest_y,          // from data_out header
  input  [3:0] route_in,                // data_out[13:10]; unused when IS_LOCAL_PORT=1
  output [3:0] route_self,
  output [3:0] route_next
);
```
- `compute_dir(x, y, dx, dy)`: if `dx > x` EAST, else if `dx < x` WEST, else if `dy > y` SOUTH, else if `dy < y` NORTH, else LOCAL.
- N/E/S/W instance: `route_self = route_in` (no logic). Local instance: `route_self = compute_dir(CUR_X, CUR_Y, dest_x, dest_y)`.
- `route_next`: if `route_self == LOCAL`, then LOCAL (explicit, not don't-care). Else compute `next_x/next_y` as `CUR` plus or minus 1 along `route_self`, and return `compute_dir(next_x, next_y, dest_x, dest_y)`.
- Outputs are only meaningful while a HEAD or HEAD_TAIL is on `data_out`.

### 4.2 `noc_input_port` (one per port; owns FIFOs, RC, per-VC state)

Parameters: `NUM_VC`, `CUR_X`, `CUR_Y`, `IS_LOCAL_PORT`.

**Link side**

| Signal | Dir | Width | Description |
|---|---|---|---|
| `flit_data` | in | 32 | flit from upstream |
| `flit_valid` | in | 1 | flit present |
| `vc_id` | in | 2 | sideband: which VC's FIFO this flit belongs to |
| `credit_return_valid` | out | NUM_VC | per-VC pulse, registered one cycle after the fetch (D1, D4) |

**Arbiter-facing (per VC `v`)**

| Signal | Dir | Width | Description |
|---|---|---|---|
| `va_req[v]` | out | 1 | head flit needs a downstream VC |
| `va_req_out_port[v]` | out | 4 | route_self: live RC output in the arrival cycle, `out_port` after |
| `va_req_single[v]` | out | 1 | flit is HEAD_TAIL |
| `va_gnt[v]` | in | 1 | VA won this cycle |
| `va_gnt_out_vc[v]` | in | 2 | output VC won |
| `sa_req[v]` | out | 1 | VC has an assigned packet and a valid head flit |
| `sa_req_out_port[v]` | out | 4 | `out_port` |
| `sa_req_out_vc[v]` | out | 2 | `out_vc` (credit mask index) |
| `sa_req_last[v]` | out | 1 | head flit is TAIL or HEAD_TAIL |
| `sa_gnt[v]` | in | 1 | stage-2 result delivered to the picked VC (at most one VC per port per cycle) |
| `sa_pick[v]` | in | 1 | stage-1 pick, one-hot across VCs. Selects the pre-crossbar mux early |

**Crossbar-facing**

| Signal | Dir | Width | Description |
|---|---|---|---|
| `st_flit_data` | out | 32 | picked VC's `data_out`, muxed by `sa_pick` |
| `st_route_next` | out | 4 | picked VC's `rc_route_next`, muxed by `sa_pick` |

**Internal, per VC**

| Name | Description |
|---|---|
| `head_valid` | `data_out` holds an active, fetched flit |
| `arrive` | registered `fetch`: the cycle a freshly fetched flit is on `data_out` (this is `fifo_rd_enable_d1`) |
| `out_port[3:0]` | latched `rc_route_self` at HEAD arrival; held for the packet. Replaces `own_route` |
| `out_vc[1:0]` | latched `va_gnt_out_vc`; held for the packet |
| `assignment_valid` | VA has granted a downstream VC to the packet at the head |

**Equations**

```
fifo_wr_enable[v] = flit_valid && (vc_id == v)
fetch[v]          = (!head_valid[v] || sa_gnt[v]) && (!fifo_empty[v] || fifo_wr_enable[v])
fifo_rd_enable[v] = fetch[v]

flit_type[v] = fifo_data_out[v][1:0]
is_head[v]   = flit_type[v][0];   is_last[v] = flit_type[v][1]

// sequential
head_valid[v]    <= fetch[v] ? 1 : (sa_gnt[v] ? 0 : head_valid[v])
arrive[v]        <= fetch[v]
credit_return_valid[v] <= fetch[v]
if (arrive[v] && is_head[v])       out_port[v] <= rc_route_self[v]
if (va_gnt[v])                     { assignment_valid[v] <= 1; out_vc[v] <= va_gnt_out_vc[v] }
if (sa_gnt[v] && is_last[v])       assignment_valid[v] <= 0      // mutually exclusive with va_gnt

// requests
va_req[v]          = head_valid[v] && !assignment_valid[v] && is_head[v]
va_req_out_port[v] = arrive[v] ? rc_route_self[v] : out_port[v]
va_req_single[v]   = (flit_type[v] == HEAD_TAIL)
sa_req[v]          = head_valid[v] && assignment_valid[v]
sa_req_out_port[v] = out_port[v]
sa_req_out_vc[v]   = out_vc[v]
sa_req_last[v]     = is_last[v]

// to crossbar
st_flit_data  = OR over v of (sa_pick[v] ? fifo_data_out[v]  : 0)
st_route_next = OR over v of (sa_pick[v] ? rc_route_next[v]  : 0)
```
Reset: `head_valid, arrive, assignment_valid, credit_return_valid = 0`; `out_port = LOCAL`; `out_vc = 0`.

Why `fetch` wins over a grant retiring `head_valid`: when both occur, the next flit is arriving on `data_out` next cycle, so the VC must stay active. Under old code the grant overwrote the fetch and lost the flit.

### 4.3 `arbiter` (VA + SA, credits; stateless about per-VC assignments)

| Signal | Dir | Width | Description |
|---|---|---|---|
| `va_req[p][v]` | in | 1 | from each input port VC |
| `va_req_out_port[p][v]` | in | 4 | |
| `va_req_single[p][v]` | in | 1 | HEAD_TAIL tier bit |
| `va_gnt[p][v]` | out | 1 | |
| `va_gnt_out_vc[p][v]` | out | 2 | |
| `sa_req[p][v]` | in | 1 | |
| `sa_req_out_port[p][v]` | in | 4 | |
| `sa_req_out_vc[p][v]` | in | 2 | |
| `sa_req_last[p][v]` | in | 1 | |
| `sa_gnt[p][v]` | out | 1 | stage-2 result to the picked VC |
| `sa_pick[p][v]` | out | 1 | stage-1 pick (one-hot per port) |
| `xbar_sel[o]` | out | 3 | input-port index switched to output `o` |
| `st_valid[o]` | out | 1 | output `o` carries a flit this cycle |
| `st_out_vc[o]` | out | 2 | downstream VC of that flit (becomes sideband `vc_id`) |
| `ds_credit_valid[o][k]` | in | 1 | credit returned by the downstream router for output VC `k` (D1) |

**Internal state:** `alloc_busy[o][k]`, `credit_count[o][k]` (reset to 4; `LOCAL_CREDITS` for `o=LOCAL`), VA row pointers `rr_va[o][k]`, stage-1 pointer `rr1[p]`, stage-2 pointer `rr2[o]`.

**VA, per output port `o`, per output VC `k`**
1. Candidates: all `(p, v)` with `va_req` and `idx(va_req_out_port) == o`.
2. Row `(o, k)` is enabled only if `!alloc_busy[o][k]`. It picks one candidate: `va_req_single` first, then round-robin from `rr_va[o][k]`.
3. Column, per requester: if it won more than one row, keep the lowest `k` and drop the others. A dropped row grants nobody this cycle (known separable inefficiency; revisit only if the performance model says so).
4. On a final grant: `va_gnt[p][v]=1`, `va_gnt_out_vc=k`, `alloc_busy[o][k] <= 1`, `rr_va[o][k]` advances. A dropped row changes nothing.
5. No credit gating (D2).

**SA stage 1, per input port `p`**
```
elig[p][v] = sa_req[p][v] && credit_count[idx(sa_req_out_port[p][v])][sa_req_out_vc[p][v]] != 0
sa_pick[p] = one-hot RR pick over elig[p] (pointer rr1[p])
s1_valid[p] = |elig[p];  s1_out[p], s1_vc[p], s1_last[p] = fields of the picked VC
```

**SA stage 2, per output port `o`**
```
req2[p]      = s1_valid[p] && (s1_out[p] == o)
w            = RR winner over req2 (pointer rr2[o])
xbar_sel[o]  = w;  st_valid[o] = |req2;  st_out_vc[o] = s1_vc[w]
sa_gnt[w][picked vc] = 1
```
Pointer updates: `rr2[o]` advances past `w` on a grant. `rr1[p]` rotates only when `p`'s picked VC actually won stage 2 (otherwise a VC that keeps losing is starved by its sibling).

**State updates at the clock edge**
```
for each output o with st_valid[o]:
    credit_count[o][st_out_vc[o]] -= 1
    if (s1_last[xbar_sel[o]])  alloc_busy[o][st_out_vc[o]] <= 0
for each (o, k) with ds_credit_valid[o][k]:
    credit_count[o][k] += 1          // same-cycle +1 and -1 net to 0
```
Never grant to a masked VC, never let `credit_count` leave `0..4`; assert both.

Legality assertion: every `(p, idx(out_port))` pair that gets a `sa_gnt` must be in the 16-pair XY table (section 2).

### 4.4 `crossbar`

```
xbar_in_data[p]        (32)  = st_flit_data from input port p
xbar_in_route_next[p]  (4)   = st_route_next from input port p
xbar_out_data[o]       = st_valid[o] ? xbar_in_data[xbar_sel[o]]       : 0
xbar_out_route_next[o] = st_valid[o] ? xbar_in_route_next[xbar_sel[o]] : 0
```
Five independent 5:1 muxes, and a separate 4-bit set for `route_next`. Pure combinational, no state.

### 4.5 `noc_output_port` (one per port)

| Signal | Dir | Width | Description |
|---|---|---|---|
| `xbar_out_data` | in | 32 | from crossbar |
| `xbar_out_route_next` | in | 4 | from crossbar |
| `st_valid` | in | 1 | from arbiter |
| `st_out_vc` | in | 2 | from arbiter |
| `flit_data`, `flit_valid`, `vc_id` | out | 32, 1, 2 | link to the downstream router (registered) |

```
merged = xbar_out_data
if (merged[0])  merged[13:10] = xbar_out_route_next      // HEAD or HEAD_TAIL; never touches [3:2] (D3)
always_ff:  flit_data <= merged;  flit_valid <= st_valid;  vc_id <= st_out_vc      // reset: flit_valid = 0
```
This register is the LT boundary. If the physical link needs more pipelining, it is added after this register and the credit loop grows by that many cycles.

### 4.6 `router_top`

- 5 `noc_input_port` instances (parameters `CUR_X`, `CUR_Y`, `IS_LOCAL_PORT` = 1 for LOCAL only), 1 `arbiter`, 1 `crossbar`, 5 `noc_output_port`.
- Per port, link in: `flit_data, flit_valid, vc_id`; credit out: `credit_return_valid[NUM_VC]`. Link out: `flit_data, flit_valid, vc_id`; credit in: `ds_credit_valid[NUM_VC]`.
- Wire `sa_pick`, `sa_gnt`, `va_gnt*` back from the arbiter to each input port, and `st_*` from input ports into the crossbar.
- Edge-of-mesh ports: tie incoming `flit_valid` and `ds_credit_valid` to 0. XY with in-range destinations never routes there; assert it.
- If Icarus (`-g2012`) rejects unpacked-array ports, flatten them into packed vectors (for example `[NUM_PORTS*NUM_VC-1:0]`) with index macros. Check this on a 10-line test before writing the arbiter.

---

## 5. Seams to inspect (where independently-verified blocks meet)

1. **FIFO output holds.** `data_out` must be stable while `rd_en = 0`; `head_valid` depends on it. Verify in the FIFO TB.
2. **FIFO bypass.** A write and read in the same cycle on an empty FIFO returns the written word on `data_out` next cycle. A read on an empty FIFO with no write is illegal; `fetch` must never do it. A full FIFO with read and write in one cycle stays a protocol violation (credits make it unreachable).
3. **`fetch` versus grant.** Same-cycle fetch and grant must keep `head_valid = 1`.
4. **`arrive` versus `va_req_out_port`.** The live mux selects on `arrive`, and `out_port` captures on the same event.
5. **Credit vector on both sides.** Input port `credit_return_valid[NUM_VC]` to the neighbor arbiter's `ds_credit_valid[o][NUM_VC]`. The old single-pulse-plus-tag wording must be gone everywhere.
6. **`sa_pick` and `sa_gnt` agree.** `sa_gnt[p][v]` implies `sa_pick[p][v]`. `st_flit_data` uses `sa_pick`, `xbar_sel` uses the stage-2 winner.
7. **Port index and direction mapping.** One function used by the arbiter, the crossbar and the tests.
8. **Output VC reuse.** `alloc_busy` clears at the TAIL's grant; the next HEAD may win VA the cycle after and its flits queue in the same downstream VC FIFO behind the TAIL. The downstream input port must handle HEAD directly after TAIL.
9. **LOCAL ejection.** The NI honors credits and VC-tagged flits (NI constraint, parked for the AXI work).
10. **Header merge versus encoding.** `merged[0]` as `is_head` depends on the 2-bit type encoding.

---

## 6. Link protocol and credit loop

Downstream: `flit_data[31:0], flit_valid, vc_id[1:0]` (sideband). Upstream: `credit_return_valid[NUM_VC]`.

Credit loop for a grant at cycle g: decrement visible g+1; flit on wire g+1; downstream fetch (bypass) at g+1, flit on `data_out` g+2; registered credit return visible g+2; upstream increments at the end of g+2 and the credit is usable g+3. That is a loop of about 3 cycles against 4 credits, so full rate is sustainable if the downstream VC drains immediately. Confirm in simulation with a three-router chain; extra link pipeline stages lengthen it and may need more credits.

---

## 7. FIFO interface assumptions (verified module, do not change)

`fifo_wr_enable, fifo_wr_data` in; `fifo_rd_enable` in; `fifo_data_out` (registered), `fifo_empty` out. Read in cycle t gives `data_out` in t+1. Reads on empty with no simultaneous write are illegal.

---

## 8. Verification plan

**Assertions (inline or bind module)**
- `sa_gnt` only with `sa_req`; at most one `sa_gnt` per input port per cycle; at most one grant per output per cycle.
- `fifo_rd_enable |-> (!head_valid || sa_gnt)` and `(!fifo_empty || fifo_wr_enable)` (no double fetch, no read when empty).
- `credit_count` stays in `0..4`; no `sa_gnt` while credits are 0.
- `alloc_busy[o][k]` set only by a VA grant and cleared only by a last-flit grant.
- Every grant is an XY-legal (input, output) pair.
- Per VC: flit sequence is HEAD, BODY*, TAIL (or a lone HEAD_TAIL); no flit lost or duplicated.

**Directed tests**
- T1 single HEAD_TAIL, LOCAL -> EAST and EAST -> WEST.
- T2 the 3-flit packet of section 3: check three consecutive grants and the cycle numbers.
- T3 two packets back-to-back in the same VC.
- T4 two VCs on one input port, different outputs (stage-1 pick; no two grants on one input in a cycle).
- T5 two inputs to the same output (stage-2 fairness), both VCs.
- T6 VA contention: three requesters, two output VCs; HEAD_TAIL beats HEAD.
- T7 credit exhaustion and recovery; same-cycle +1/-1.
- T8 fetch and grant in the same cycle (collision case).
- T9 empty-FIFO bypass (flit on the link with an empty FIFO).
- T10 `route_next` correctness: a packet through three routers in a line.
- T11 random traffic with a scoreboard, then a deadlock watchdog.

**Toolchain:** Icarus Verilog for simulation, Verilator `--lint-only`, gtkwave. Makefile: `make sim TOP=<tb>`, `make lint`, `make wave`, `make clean`.

---

## 9. Changes from earlier docs and code

| Item | Was | Now |
|---|---|---|
| `head_valid` | set from `fifo_rd_enable_d1` (one cycle late) | set on `fetch`, aligned with `data_out` |
| Fetch | `!head_valid && (...)` (double fetch, one flit per 3 cycles) | `(!head_valid \|\| sa_gnt) && (...)` |
| Grant vs fetch priority | grant clears `head_valid` over fetch | fetch wins |
| Route capture | rising edge of `head_valid` via `head_valid_d1` | `arrive && is_head`; `head_valid_d1` removed |
| `va_req_out_port` | `own_route` | `arrive ? rc_route_self : out_port` |
| Register name | `own_route` | `out_port` |
| `req_flit_type` | 2 bits | `va_req_single`, 1 bit |
| SA | flat pool | two stage, credit mask before the pick |
| `st_flit_data/type` | per VC | single post-mux `st_flit_data`, `st_route_next`; type output not needed (`sa_req_last` covers it) |
| Credit return | one pulse plus VC tag | per-VC vector (D1) |
| Arbiter outputs | `xbar_sel` only | adds `sa_pick`, `st_valid`, `st_out_vc` |
| ST | separate stage after SA | fused with SA in the grant cycle |

---

## 10. Build order and done criteria

1. **Fix `noc_input_port`.** Apply section 4.2 and section 9. Done when T2, T8 and T9 pass at port level with a mock arbiter.
2. **`route_compute`.** Check the existing module against 4.1 (Local versus relay parameter). Done when the exhaustive coordinate sweep matches a software model.
3. **VA allocator** standalone. Done when T6 passes, plus no-double-grant and `alloc_busy` checks.
4. **SA** (stage 1 and 2) standalone. Done when T4, T5 and the credit mask checks pass.
5. **Arbiter wrapper** with `credit_count`, `alloc_busy`, pointers. Done when T7 passes.
6. **Crossbar and output port.** Done when merge/route_next checks pass.
7. **`router_top`** and the single-router tests T1 to T9, then lint clean.
8. **Three-router chain** for T10 and the credit loop; then random traffic.
9. **Synthesis pass** at `NUM_VC` 2 and 4 with a per-module breakdown. Pull the worst paths and compare to the three critical paths listed in section 3.

---

## 11. Deferred (not blocking)

- Speculative VA/SA, VA/SA bypass of `assignment_valid`.
- MESI message-class VC separation. This becomes mandatory once AXI request/response share the network.
- LT cycle count and link pipelining (floorplan-dependent).
- Local-port RC registered before VA (decide from synthesis).
- HEAD_TAIL 18-bit payload against a real MESI message list.
- NI: SRC field, AXI address decode, request/response deadlock, backpressure bridge, credit and VC handling at LOCAL.
