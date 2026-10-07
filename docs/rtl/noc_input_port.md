# `noc_input_port` — `rtl/noc_input_port.sv`

Terminates one incoming router link and owns everything belonging to the
**receive side** of that link:

- one FIFO per virtual channel (buffering + flow control),
- one `route_compute` per virtual channel (routing + lookahead),
- the per-VC packet control state (route latch, output-VC assignment),
- the request side of the VA and SA arbiters.

It deliberately does **not** allocate, arbitrate or switch — those live in
`arbiter` and `crossbar`. This module only asks for what it needs and obeys
the grants it is handed. That split is what makes the arbiter testable on its
own with a mock input port and the input port testable on its own with a mock
arbiter (`tb/mock_arbiter.sv`).

`NUM_VC` identical copies of everything below run in parallel, with **no
cross-VC state**: two VCs on the same port may be at completely different
points in a packet's lifetime simultaneously, which is the entire point of
having them.

---

## 1. Ports and state

### 1.1 Parameters

| Name | Type | Default | Meaning |
|---|---|---|---|
| `NUM_VC` | `int` | 2 | Virtual channels on this port (spec §1.1). |
| `CUR_X` | `logic [2:0]` | `'0` | This router's X coordinate, folded into `route_compute`. |
| `CUR_Y` | `logic [2:0]` | `'0` | This router's Y coordinate. |
| `IS_LOCAL_PORT` | `bit` | 0 | `1` on the LOCAL instance: there is no upstream header, so `route_compute` derives `route_self` from the destination fields and `rc_route_in` is structurally ignored. `0` on NORTH/EAST/WEST/SOUTH: the previous router already computed `route_self` and put it in bits `[13:10]`. |

### 1.2 Port declaration

Direction is from the DUT's point of view.

| Signal | Width | Direction | Source → Destination | Working / description |
|---|---|---|---|---|
| `clk` | 1 | input | clock generator → FIFOs, both `always_ff`, all SVA | Rising edge. |
| `rst_n` | 1 | input | reset generator → FIFOs, `always_ff`, `disable iff` | **Synchronous, active low** — deliberately matching `fifo.sv`. Mixing async-reset and sync-reset flops on one reset net is a classic synthesis surprise (recovery/removal violations on the async ones only), so every sequential block in this design uses `@(posedge clk)` + `if (!rst_n)`. |
| `flit_data` | 32 | input | upstream `noc_output_port.flit_data` (or the NI) → FIFO `data_in` and the field extract | Incoming payload. Format: see §1.4. |
| `flit_valid` | 1 | input | upstream `flit_valid` → `fifo_wr_enable` decode | Write enable for exactly the FIFO named by `vc_id`. |
| `vc_id` | 2 | input | upstream `vc_id` sideband → VC demultiplex | **Authoritative** VC selector. The `VC_ID` field inside a HEAD flit (bits `[3:2]`) is stale after the first hop and is ignored — assumption D3. |
| `credit_return_valid` | `NUM_VC` | output | `noc_input_port` → upstream router's `ds_credit_valid[...][k]` | One bit per VC, so two VCs may free a slot in the same cycle. Registered: `credit_return_valid <= fetch`, so it means "one FIFO slot was freed by a prefetch read", **not** "one flit left the router". |
| `req_va` | `NUM_VC` | output | input port → `arbiter.va_req` | `head_valid && !assignment_valid && is_head` — this VC holds a HEAD and does not yet own a downstream VC. |
| `va_req_out_port` | `NUM_VC × 4` (unpacked) | output | input port → `arbiter.va_req_out_port` | The output port the packet needs from *this* router. Live `route_compute` output in the arrival cycle, the latched copy every cycle after (§2.5). |
| `va_req_single` | `NUM_VC` | output | input port → `arbiter.va_req_single` | The packet is a single flit (HEAD_TAIL). VA uses it as a priority tier so short packets jump ahead. |
| `va_gnt` | `NUM_VC` | input | `arbiter.va_gnt` → assignment state | VA won this cycle. |
| `va_gnt_out_vc` | `NUM_VC × 2` (unpacked) | input | `arbiter.va_gnt_out_vc` → `out_vc[v]` | Which downstream VC was assigned; latched for the packet's life. |
| `req_sa` | `NUM_VC` | output | input port → `arbiter.sa_req` | `head_valid && assignment_valid` — this VC holds a flit **and** owns a downstream VC. |
| `sa_req_out_port` | `NUM_VC × 4` (unpacked) | output | input port → `arbiter.sa_req_out_port` | Which output port it wants (stage-2 target). The latched `out_port[v]`, stable for the packet. |
| `sa_req_out_vc` | `NUM_VC × 2` (unpacked) | output | input port → `arbiter.sa_req_out_vc` | Which downstream VC it targets — the credit-mask index. |
| `sa_req_last` | `NUM_VC` | output | input port → `arbiter.sa_req_last` | The active flit is the packet's last (TAIL or HEAD_TAIL). A **level**, not a pulse: asserted as long as the last flit sits at the head, and the arbiter ANDs it with its own grant before releasing the output-VC reservation — so a stalled TAIL cannot release anything. |
| `sa_gnt` | `NUM_VC` | input | `arbiter.sa_gnt` → fetch rule, head tracker, assignment release | Stage 2 granted this VC; its flit crosses this cycle. |
| `sa_pick` | `NUM_VC` | input | `arbiter.sa_pick` → OR-mux | Stage 1 picked this VC; selects the pre-crossbar mux early so the data mux is not on the stage-2 path. `sa_gnt` implies `sa_pick`. |
| `st_flit_data` | 32 | output | input port → `router_top` fold → `crossbar.xbar_in_data[p]` | Post-mux payload for this port. The VC OR-mux is resolved **here**, so the crossbar only has to mux across input ports rather than stacking a 2:1 VC mux inside a 5:1 mux. |
| `st_route_next` | 4 | output | input port → `router_top` fold → `crossbar.xbar_in_route_next[p]` | Lookahead for the downstream router, to be merged into `[13:10]` of a HEAD by `noc_output_port`. |

### 1.3 Registers and state

| Name | Width | Kind | Reset | Working / description |
|---|---|---|---|---|
| `head_valid` | `NUM_VC` | register | `'0` | `data_out` holds an active, fetched flit. High in the **arrival cycle** (t+1 after a fetch in t), aligned with the data itself. |
| `arrive` | `NUM_VC` | register | `'0` | Registered `fetch`. High in exactly the cycle a freshly fetched flit appears on `data_out`. The **only** event that marks "a new flit is here"; it drives route capture and the live VA output-port mux. (Historically `fifo_rd_enable_d1`; renamed because it became load-bearing.) |
| `out_port` | `NUM_VC × 4` (unpacked) | register | `DIR_LOCAL` per VC | This VC's packet's exit port from *this* router. Captured from `rc_route_self` on the arrival cycle, held until the packet's last flit leaves. |
| `out_vc` | `NUM_VC × 2` (unpacked) | register | `'0` | Downstream VC assigned by VA, held for the packet's life. |
| `assignment_valid` | `NUM_VC` | register | `'0` | This VC's packet owns a downstream VC, so it may ask for the switch. Set by `va_gnt`, cleared by `sa_gnt && is_last`. |
| `in_pkt` | `NUM_VC` | register | `'0` | **Verification only — no datapath logic reads it.** High while this VC is between a HEAD and its TAIL. Exists so the sequence assertion can state the rule in the spec's vocabulary ("HEAD, BODY\*, TAIL") instead of restating the type encoding at every use. |
| `fifo_wr_enable`, `fetch` | `NUM_VC` each | wire (combinational) | n/a | Write decode and the read/fetch rule (§2.3). `fetch == fifo_rd_enable` by construction. |
| `fifo_data_out` | `NUM_VC × 32` | wire | n/a | Each FIFO's registered output — the per-VC "head register". |
| `fifo_empty`, `fifo_full`, `fifo_err` | `NUM_VC` each | wire | n/a | FIFO status. |
| `rc_dest_x`, `rc_dest_y` | `NUM_VC × 3` each | wire | n/a | Header fields `[6:4]` / `[9:7]` of `data_out`. |
| `rc_route_in` | `NUM_VC × 4` | wire | n/a | Header `[13:10]` of `data_out` — the sender's lookahead, consumed as `route_in`. |
| `rc_route_self` | `NUM_VC × 4` | wire | n/a | `route_compute` output: this router's exit port. |
| `rc_route_next` | `NUM_VC × 4` | wire | n/a | `route_compute` output: the downstream router's route. |
| `flit_type` | `NUM_VC × 2` | wire | n/a | `data_out[1:0]`. Only meaningful while `head_valid`. |
| `is_head`, `is_last` | `NUM_VC` each | wire | n/a | `= flit_type[0]` and `= flit_type[1]` (§1.4). |

### 1.4 Flit format and type encoding

```
HEAD / HEAD_TAIL           BODY / TAIL
[31:14] RESERVED           [31:2]  PAYLOAD
[13:10] ROUTE               [1:0]  FLIT_TYPE
 [9:7]  DEST_Y
 [6:4]  DEST_X
 [3:2]  VC_ID   (ignored by routers; the sideband vc_id is authoritative)
 [1:0]  FLIT_TYPE
```

| type | name | `is_head = type[0]` | `is_last = type[1]` |
|---|---|---|---|
| `00` | BODY | 0 | 0 |
| `01` | HEAD | 1 | 0 |
| `10` | TAIL | 0 | 1 |
| `11` | HEAD_TAIL | 1 | 1 |

Both shortcuts depend on this exact encoding, so there is an elaboration-time
assertion pinning it down (§2.7).

---

## 2. RTL explanation

### 2.1 The timing rule everything else follows

The FIFO's `data_out` is **registered**: a read issued in cycle *t* places
the fetched flit on `data_out` in *t+1*. Every signal in this module is
defined relative to that one fact:

| cycle | event |
|---|---|
| *t* | `fetch[v] = 1` — `fifo_rd_enable` asserted, `data_out` still stale |
| *t+1* | `data_out` = fetched flit, `head_valid = 1`, `arrive = 1` — **arrival cycle**. `route_compute` is live against this flit's header and the first VA request is issued now. |
| end of *t+1* | `out_port` latched from `rc_route_self` |
| *t+2* | `out_port` stable; SA request can be issued (once VA granted) |

Route capture keys off `arrive && is_head`, **not** off an edge of
`head_valid`. A `head_valid` edge mixes two different things (a flit becoming
active and a flit arriving) and, when `head_valid` is already high across a
grant, misses the event entirely.

### 2.2 Packet flow

```
incoming link → VC demux (by sideband vc_id) → per-VC FIFO --fetch--> credit_return (t+1)
                                                        |
                                                        v
                                              data_out = active flit   <- head register
                                                        |
                    +--> route_compute --> route_self (exit port) / route_next (lookahead)
                    +--> VA request   (fresh packet still needs a downstream VC)
                    +--> SA request   (packet already owns a downstream VC)
                                        |
                                        v
                              sa_pick chooses this VC's flit for the crossbar
```

### 2.3 The fetch rule (spec option ii)

```systemverilog
fetch = (!head_valid || sa_gnt) && (!fifo_empty || fifo_wr_enable);
```

Two independent clauses:

1. **The head register must be free.** Free either because no flit is active,
   or because the active flit is leaving this cycle (`sa_gnt`) — in which case
   the departing flit frees the register at the same edge the new one arrives,
   so both may happen at once.
2. **There must be something to fetch** — a buffered flit, or a flit arriving
   on the link right now that the FIFO's empty-bypass will forward straight to
   `data_out` without entering storage.

There is **no combinational loop** through `sa_gnt`: `sa_gnt` is a function of
registered state only (`sa_req` comes from `head_valid`/`assignment_valid`,
credits are counters), so it is already settled when this expression
evaluates.

When `fetch` and `sa_gnt` coincide, `head_valid` stays 1 (fetch wins the
assignment ordering in §2.6). That is what buys one flit per cycle per VC. The
alternative — letting the grant clear `head_valid` — strands the flit that was
just fetched, and a back-to-back stream degenerates to one flit every three
cycles: fetch, hold, grant, fetch…

### 2.4 Credits

```systemverilog
credit_return_valid <= fetch;
```

A credit means "one FIFO slot was freed by a prefetch read", not "one flit
left the router". `data_out` is extra storage on top of the FIFO depth and is
**not** counted, so the downstream side sees depth+1 physical slots against
`depth` credits — conservative by exactly one slot, which is what makes the
loop safe against the same-cycle arrival/departure case.

Registering also keeps the credit wire off this module's combinational path
(assumption D4).

With `DEPTH = 8` that is 9 physical positions against 8 credits.

### 2.5 The arrival-cycle live mux

```systemverilog
va_req_out_port[i] = arrive[i] ? rc_route_self[i] : out_port[i];
```

In the arrival cycle `out_port` still holds the *previous* packet's route (or
`DIR_LOCAL`, out of reset), but `route_compute` is already valid against the
new header — so the combinational value is taken. From the next cycle on,
`out_port` has been latched from that very value, so the register is read
instead. The two sides are the same number by construction; the mux exists
purely to avoid one cycle of dead time between "flit arrives" and "route is
requestable".

Without it, a HEAD arriving into an idle VC would request VA against
`out_port = DIR_LOCAL` and win an allocation it has no business having.

### 2.6 The sequential block (lines 560–648)

Three events in one `always_ff`, with their relative priority being the whole
ballgame:

```systemverilog
arrive              <= fetch;
credit_return_valid <= fetch;

if (fetch[v])      head_valid[v] <= 1'b1;   // fetch MUST win over sa_gnt
else if (sa_gnt[v]) head_valid[v] <= 1'b0;

if (arrive[v] && is_head[v]) out_port[v] <= rc_route_self[v];

if (arrive[v]) begin
  if (is_head[v])      in_pkt[v] <= !is_last[v];
  else if (is_last[v]) in_pkt[v] <= 1'b0;
end
```

`arrive` is the registered form of `fetch`, so it pulses exactly once per flit
actually fetched — the packet-boundary tracker therefore observes every flit
on this VC exactly once and in order, which is what the sequence assertion
polices: no flit skipped, none seen twice.

A second, smaller `always_ff` owns `assignment_valid` / `out_vc`:

```systemverilog
if (va_gnt[v])                        begin assignment_valid[v] <= 1'b1; out_vc[v] <= va_gnt_out_vc[v]; end
if (sa_gnt[v] && is_last[v])          assignment_valid[v] <= 1'b0;
```

VA and SA release the bit from opposite ends. They are two separate `if`s
rather than `if/else` because they genuinely cannot overlap for the same VC in
one cycle — a VC cannot acquire an assignment and release one simultaneously —
but last-write-wins makes the outcome well defined regardless of which
convention a future edit assumes. A HEAD_TAIL packet sets and clears the bit
in two consecutive cycles with no special-casing.

### 2.7 Requests and the crossbar-facing OR-mux

- `req_va = head_valid && !assignment_valid && is_head` — asked **exactly
  once per packet**. BODY/TAIL never ask (they inherit the assignment) and a
  VC mid-packet never re-asks.
- `req_sa = head_valid && assignment_valid`, with `sa_req_out_port/out_vc`
  read straight from the latched registers.
- The OR-mux:

  ```systemverilog
  st_flit_data = '0; st_route_next = '0;
  for (int v = 0; v < NUM_VC; v++)
    if (sa_pick[v]) begin st_flit_data |= fifo_data_out[v]; st_route_next |= rc_route_next[v]; end
  ```

  `sa_pick` is one-hot across this port's VCs (guaranteed by SA stage 1,
  checked below), so OR-ing the masked contributions selects exactly the
  picked VC and yields 0 when nothing is picked — which the crossbar ignores
  because `st_valid` is low in that case. The self-read on `|=` is safe
  because the seed assignment happens first in the same evaluation, so there
  is no combinational feedback.

### 2.8 Assertions (lines 748–888)

Unconditional SVA — this toolchain parses it today and VCS will later; there
is deliberately no per-simulator conditional anywhere in the RTL.

**Elaboration-time (line 748).** Pins the type-encoding table itself. Editing
`FLIT_TAIL` alone would pass the dynamic check while silently disagreeing with
every other module and testbench that hard-codes `2'b10` — hence both a static
and a dynamic check.

**Per-VC, in a `for (g…)` generate:**

| Property | Protects |
|---|---|
| `va_gnt \|-> req_va` | The arbiter cannot grant an allocation nobody asked for (seam #6). |
| `sa_gnt \|-> req_sa` | It cannot switch a flit this module did not offer. |
| `sa_gnt \|-> sa_pick` | Stage 2 must select a VC stage 1 already picked — `st_flit_data` is muxed by `sa_pick`, so a grant without a pick would switch garbage. |
| `fetch \|-> (!head_valid \|\| sa_gnt)` | Clause 1 of the fetch rule, with its own message so you know *which* half broke. |
| `fetch \|-> (!fifo_empty \|\| fifo_wr_enable)` | Clause 2 — reading an empty FIFO is only legal when a write is bypassing past it in the same cycle. |
| `!(fifo_wr_enable && fifo_full)` | Writing into a full FIFO means the arbiter handed out more credits than the downstream buffer has slots. **Credit accounting is what is being indicted, not this module.** |
| `!fifo_err` | The FIFO's own union of the two illegal operations, asserted separately as belt-and-braces: if the FIFO's idea of a violation ever drifts from this module's, one of the three catches it. |
| `va_gnt \|-> !assignment_valid` | A VA grant while an assignment is already live would leak the old downstream VC — two packets believing they own it. |
| `assignment_valid \|-> !$isunknown(out_vc)` | `out_vc` must be written before anything depends on it. Note `$isunknown` is trivially false in a 2-state simulator, so this only has teeth under VCS — kept deliberately, since that is where the network will ultimately be verified. |
| `head_valid \|->` both type shortcuts match the named constants | `is_head` gates VA eligibility and route capture; `is_last` tells the arbiter when to release the output VC. Stated against named constants rather than raw bit positions so an encoding change must be made deliberately, next to the comment explaining why it is safe. |
| `head_valid \|-> out_port` is one of the five `DIR_*` codes | Checked against the legal codes, not merely "one-hot", so a corrupted `4'b0011` is caught too. Written as a chain of `==` rather than `inside {…}` because the tool refuses that form inside a property. |
| `arrive \|-> (in_pkt ? !is_head : is_head)` | **Flit sequence: HEAD, BODY\*, TAIL** (spec §8). Sampled on `arrive`, which pulses once per fetched flit, so it sees every flit once and in order. `in_pkt` still holds the state from *before* this flit, because the sequential block updates it at the same edge — exactly the "what was I expecting next?" answer the check needs. A continuation while no packet is open → a header was lost. A head while a packet is open → a second header, or a flit seen twice. |

**Whole-port (outside the per-VC loop):**

| Property | Protects |
|---|---|
| `$countones(sa_pick) <= 1` | At most one pick — not *exactly* one: when the port has nothing to offer, stage 1 picks nothing and all bits are 0. |
| `$countones(sa_gnt) <= 1` | At most one VC may be switched in a cycle; the port has a single 32-bit datapath to the crossbar. |

---

## 3. Testing explanation

**Bench:** `tb/tb_noc_input_port.sv`, top module `tb_noc_input_port`
(**139** checks). Uses `tb/mock_arbiter.sv` in place of the real arbiter.
**Run:** `make TOP=noc_input_port sim` → `Checks : 139 / Errors : 0 /
ALL TESTS PASSED`.

### 3.1 Why a mock arbiter

The split in the module header exists precisely so this module can be tested
without the arbiter. The mock grants on demand and in the pattern the spec's
section 3 timeline requires, so the bench can say "cycle *c2*: grant" and
check the exact consequence — rather than modelling SA's credit masks and
round-robin just to get a grant to happen.

### 3.2 What the tests cover

- **Spec §3 timeline (T2, three-flit packet).** The bench walks HEAD → BODY →
  TAIL cycle by cycle against the documented table: `req_va` before the
  header is fetched, `credit_return` one cycle after each fetch, `req_sa`
  once the VA grant lands, three consecutive grants at *c2/c3/c4* proving one
  flit per cycle per VC, and the correct payload on `st_flit_data` at each
  step. This is the test that would catch the fetch/grant ordering bug
  described in §2.3.
- **The arrival-cycle live mux** (§2.5) — that `va_req_out_port` reads the
  live `route_compute` output in the arrival cycle and the latched register
  afterwards, and that the two agree.
- **Route capture on `arrive && is_head`** — including the case where
  `head_valid` was already high across a grant, which a `head_valid`-edge
  implementation would miss.
- **Fetch legality both halves**, and the empty-bypass path (a flit arriving
  on the link while the FIFO is empty reaches `data_out` without entering
  storage).
- **VA/SA handshake consistency** — every grant the mock issues is matched by
  a request in the same cycle.
- **Credit return timing** — registered, one cycle after the fetch.
- **Sequence integrity** across a multi-flit packet and across back-to-back
  packets on the same VC.
- **Reset** — `head_valid`, `arrive`, `credit_return_valid`, `in_pkt` and
  `out_port` all take their documented reset values.

### 3.3 Assertion coverage

All fifteen assertions in §2.8 — fourteen `assert property` blocks plus the
elaboration-time encoding check — are live throughout the run, including the
elaboration-time encoding check. `tools/assert_neg.sh` proves the sequence
property actually fires, with `--assert` **on**:

```
%Error: noc_input_port.sv:870: Assertion failed in TOP.tb_noc_input_port.u_relay.gen_assert_vc[0]:
        noc_input_port: flit sequence broken on VC 0: type=00 while in_pkt=0
```

The case mutates the `in_pkt` update so a HEAD closes the packet instead of
opening it, which makes the BODY of T2 arrive "while no packet is open". The
run aborts at the first violation — that `$stop` is the proof that the
assertion side of the flow works and is not vacuous.

### 3.4 Mutation sanity

`tools/mutate_all.sh` runs one mutation against `tb_router_top`:

| Mutation | Result |
|---|---|
| grant wins over fetch (spec §9) — swap the `head_valid` assignment order so `sa_gnt` clears before `fetch` sets | **18/49 CHECKS FAILED** |

That is the ordering described in §2.6: with the grant winning, a back-to-back
stream advances one flit every three cycles and the throughput claims in
`tb_router_top` and `tb_noc_input_port` both fail.

### 3.5 What this bench cannot show

It cannot show that the merged `route_next` is consumed correctly (there is no
`noc_output_port` in the picture at the crossbar seam), nor that the credit
loop closes across a real link. Those are `tb_noc_output_port` and
`tb_router_chain` respectively.
