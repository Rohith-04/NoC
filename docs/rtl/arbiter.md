# `arbiter` — `rtl/arbiter.sv`

Virtual-channel allocation, switch allocation, and credit bookkeeping for one
router. Owns everything that is **shared** between input ports; owns nothing
that is *per-VC assignment* state — that lives in `noc_input_port`. This
block never knows which packet an input port is holding, only which output it
is asking for.

Three independent pieces:

| Piece | What it does |
|---|---|
| **VA** | **VC-matched** (v2 §4.4). One row per `(output port, output VC)`; a row's candidates are the **input ports** asking for that port *at the same VC index*, so a packet's input VC and its output VC can never disagree. There is **no column stage** — a requester maps to exactly one row, so there is nothing to throw away. Still **combinational in the request cycle**: the grant is not registered (spec §1.1), so the input port latches `out_port` and its `assignment_valid` flag at the same edge the arbiter latches `alloc_busy`, and there is no downstream-VC register on that edge any more — matched VCs make it a copy of the index that fetched it. |
| **SA** | Two stages. Stage 1 picks one VC *within* an input port, masked by the credit count for that VC's target output. Stage 2 picks one input port *per output*. Splitting it this way is what makes the crossbar selection a single one-hot vector per output. |
| **CRED** | A counter per `(output, output VC)`. Init = free slots the *downstream* consumer has — `DIR_CREDITS` tracks the neighbour input FIFO depth, `LOCAL_CREDITS` the NI receive buffer. Decrement on switch, increment on return; simultaneous +1/−1 nets to zero (spec §1.1). |

The two combinational halves **do not read each other**, deliberately: VA is
not credit-gated (assumption D2) and SA does not know about VA's reservation.
That independence is what lets them be verified separately.

**Port index encoding (spec §2):** `LOCAL 0, NORTH 1, EAST 2, WEST 3,
SOUTH 4`. The 4-bit one-hot direction codes arriving on `*_req_out_port`
(`0000/0001/0010/0100/1000`) are converted to indices by `dir_to_idx` as
soon as they enter this module. Everything internal — row indices,
`xbar_sel`, the pointers — is an index. One representation per boundary is
what stops direction/index mix-ups from silently selecting the wrong port.

---

## 1. Ports and state

### 1.1 Parameters

| Name | Type | Default | Meaning |
|---|---|---|---|
| `NUM_PORTS` | `int` | 5 | Fixed by the 5×5 crossbar. |
| `NUM_VC` | `int` | 4 | Virtual channels per port (v2 §1). Sizes every `(port, VC)` array in the module and the `VC_W` sidebands; valid values are 2, 4 or 8. |
| `LOCAL_IDX` | `int` | 0 | Index of the LOCAL port (spec §2). |
| `DIR_CREDITS` | `int` | 4 | Neighbour input FIFO depth — init and ceiling for `credit_count[o != LOCAL][*]`. **Set from `router_top.FIFO_DEPTH`**, because a credit *is* a free slot in that FIFO. |
| `LOCAL_CREDITS` | `int` | 4 | NI receive buffer depth per VC — init and ceiling for `credit_count[LOCAL][*]`. |

Derived locals — values below are for the default 5 × 4 configuration:

- `OIDX_W = (NUM_PORTS > 1) ? $clog2(NUM_PORTS) : 1` — **3**. The port
  space, and `rr_pick_port`'s `NUM_PORTS` "nobody" sentinel has to fit in
  that space too (0..7 for five ports). That holds because `NUM_PORTS` is
  locked at 5 — it is not a property the formula guarantees in general, so
  if ports are ever added this line moves with them.
- `VC_W = (NUM_VC > 1) ? $clog2(NUM_VC) : 1` — **2**. The VC index width:
  sizes `sa_req_out_vc`, `st_out_vc`, `rr1`, and the internal
  `va_gnt_out_vc`. Derived here rather than passed in, so a `-GNUM_VC`
  sweep cannot leave a sideband narrower than the index it carries.
- `CRED_MAX = max(DIR_CREDITS, LOCAL_CREDITS)` — **4**. The ceiling one
  credit counter may hold.
- `CRED_W = $clog2(CRED_MAX + 1)` — **3**. The counters must hold
  `0..CRED_MAX`.

### 1.2 Port declaration

Direction is from the DUT's point of view.

| Signal | Width | Direction | Source → Destination | Working / description |
|---|---|---|---|---|
| `clk` | 1 | input | clock generator → `always_ff`, all SVA | Rising edge. |
| `rst_n` | 1 | input | reset generator → `always_ff`, `disable iff` | Synchronous, active low, matching `fifo.sv`. |
| `va_req` | `NUM_PORTS × NUM_VC` | input | `noc_input_port.req_va` → VA row stage | This VC holds a HEAD/HEAD_TAIL and does not yet own a downstream VC. |
| `va_req_out_port` | `NUM_PORTS × NUM_VC × 4` | input | `noc_input_port.va_req_out_port` → `dir_to_idx` in the row stage | The output port the packet needs from *this* router, as a one-hot direction code. |
| `va_req_single` | `NUM_PORTS × NUM_VC` | input | `noc_input_port.va_req_single` → VA tier select | The packet is a single flit (HEAD_TAIL); VA gives it the higher priority tier. |
| `va_gnt` | `NUM_PORTS × NUM_VC` | **output** | VA → `noc_input_port.req_va` handshake / `assignment_valid` set | One bit per **requester** — an input port *and* a VC index. Under VC matching (v2 §4.4) the grant on `(p, k)` **is** the allocation: the packet now owns downstream VC `k` itself, so no assignment accompanies the grant across this boundary. |
| `sa_req` | `NUM_PORTS × NUM_VC` | input | `noc_input_port.req_sa` → SA stage 1 | This VC holds a flit **and** owns a downstream VC. |
| `sa_req_out_port` | `NUM_PORTS × NUM_VC × 4` | input | `noc_input_port.sa_req_out_port` → `dir_to_idx` | Output direction it wants (stage-2 target), one-hot code. |
| `sa_req_out_vc` | `NUM_PORTS × NUM_VC × VC_W` | input | `noc_input_port.sa_req_out_vc` → credit mask index | Which downstream VC it targets — indexes `credit_count`. Always the requester's own VC index (VC matching), so the pool stage 1 tests is this VC's own pool. |
| `sa_req_last` | `NUM_PORTS × NUM_VC` | input | `noc_input_port.sa_req_last` → `s1_last` → `cr_release` | The active flit is the packet's last. A level; the arbiter ANDs it with its own grant before releasing the row. |
| `sa_gnt` | `NUM_PORTS × NUM_VC` | **output** | SA stage 2 → `noc_input_port` (fetch rule, assignment release), `router_top.a_sa_gnt` | Stage 2 granted this VC; its flit crosses this cycle. |
| `sa_pick` | `NUM_PORTS × NUM_VC` | **output** | SA stage 1 → `noc_input_port` OR-mux, `router_top.a_sa_pick` | Stage-1 pick. One-hot per port *regardless* of whether stage 2 later grants it. `sa_gnt` implies `sa_pick`. |
| `xbar_sel` | `NUM_PORTS × 3` | **output** | SA stage 2 → `crossbar.xbar_sel` | `xbar_sel[o]` = **input port index** leaving through output `o`. Driven `0` when nobody asks — always a legal index; `st_valid` masks it all the way to the link register. |
| `st_valid` | `NUM_PORTS` | **output** | SA stage 2 → crossbar, output ports, credit decrement, `router_top` seam assertion | `st_valid[o]` = some input port won output `o` this cycle. |
| `st_out_vc` | `NUM_PORTS × VC_W` | **output** | SA results → `noc_output_port.st_out_vc` (the `vc_id` sideband) | The winning flit's downstream VC. Cleared when `!st_valid` rather than left stale, so a future bug in that gating cannot silently corrupt credit accounting. |
| `ds_credit_valid` | `NUM_PORTS × NUM_VC` | input | downstream router's `credit_return_valid` (or the NI) → `cr_inc` | `ds_credit_valid[o][k]` = a free slot appeared downstream in output `o`, VC `k`. Per-VC vector rather than one pulse plus a tag, because two VCs can fetch in the same cycle (assumption D1). |

### 1.3 Registers and state

| Name | Width | Kind | Reset | Working / description |
|---|---|---|---|---|
| `alloc_busy` | `NUM_PORTS × NUM_VC` | register | `'0` | A row `(output o, output VC k)` is reserved once VA grants it, and stays reserved until the **last** flit of that packet wins SA — so no second packet can be handed the same downstream VC while the first is still draining into it. |
| `credit_count` | `NUM_PORTS × NUM_VC × CRED_W` | register | `credit_init(o)` — `LOCAL_CREDITS` for `o == LOCAL_IDX`, else `DIR_CREDITS` | Free slots downstream. The whole credit loop (spec §6) exists to keep this in `[0, credit_max(o)]`. |
| `rr_va[o][k]` | `OIDX_W` each (`[NUM_PORTS][NUM_VC]`) | register | `'0` | Which **input port** row `(o, k)` considers first. The row is pinned to a single VC already — a VC-matched allocator only ever asks input VC `k` for output VC `k` — so the only thing left to arbitrate between is the `NUM_PORTS` ports, and the pointer stays in port space (`OIDX_W`) instead of the flattened `(port, VC)` width it needed when one row could see every VC at once. Advanced to `(winner + 1) % NUM_PORTS` when the row is granted. |
| `rr1[p]` | `VC_W` each (`[NUM_PORTS]`) | register | `'0` | Which VC of input port `p` SA stage 1 considers first. |
| `rr2[o]` | `OIDX_W` each (`[NUM_PORTS]`) | register | `'0` | Which input port output `o` considers first in stage 2. |
| `row_pidx`, `row_val` | `OIDX_W` / 1 each (`[NUM_PORTS][NUM_VC]`) | wire (combinational) | n/a | VA row-stage output: the winning **input port** (or `NUM_PORTS` = nobody) and whether the row produced a winner. Feeds the final grants (§2.3), the `alloc_busy` set, and the VA assertions. |
| `va_gnt_out_vc` | `NUM_PORTS × NUM_VC × VC_W` | wire (combinational) | n/a | **Assertion-only, internal** (v2 §4.4 vs §4.5). The downstream VC each grant reserved — driven as the row's own index `k`, which by VC matching is also the requester's input VC. Deliberately **not a module output** any more: with the two indices unable to disagree the sideband carried no information across the boundary, so the port and the wires carrying it through `router_top` are gone. It survives because §4.5 asks for `granted output VC == input VC index` to be *asserted*, and that property has no other statement (§2.8). Feeds assertions only; folds away when they are compiled out. |
| `va_kept` | `NUM_PORTS × NUM_VC` (`int unsigned`) | wire (combinational) | n/a | **Assertion-only.** Rows won *per requester*, counted from `row_val`/`row_pidx` (§2.6). Folds away entirely when assertions are compiled out. |
| `s1_valid`, `s1_idx`, `s1_vc`, `s1_oport`, `s1_last` | `NUM_PORTS` each (widths `1`/`VC_W`/`VC_W`/`3`/`1`) | wire (combinational) | n/a | SA stage-1 results: a candidate exists, which VC, its downstream VC, its **output port index** (direction converted here, once), and whether it is the packet's last flit. |
| `s2_sel`, `s2_any` | `NUM_PORTS × 3` / `NUM_PORTS` | wire (combinational) | n/a | SA stage-2 results; drive `xbar_sel` and `st_valid` directly. |
| `cr_dec`, `cr_inc`, `cr_release` | `NUM_PORTS × NUM_VC` each | wire (combinational) | n/a | Credit direction flags and the row-release condition, factored out so the sequential block and the assertions talk about **one shared signal** (§2.7). |

---

## 2. RTL explanation

### 2.1 Helpers (lines 132–220)

- **`dir_to_idx`** — one-hot direction → port index (`0000→0 … 1000→4`),
  "set-bit position plus one, with all-zero mapping to LOCAL". An illegal
  code falls back to LOCAL as a *defined* fallback; a separate assertion
  catches the code being illegal in the first place, so the fallback can
  never mask a real bug by quietly routing to the wrong port.
- **`rr_pick_vc` / `rr_pick_port`** — round-robin over a
  mask, starting the search **at** `start` and wrapping. Returns the selected
  index, or the **mask width itself** ("nobody") when the mask is empty.
  Returning an out-of-range value rather than a sentinel of 0 keeps "no
  winner" distinguishable from "port 0 won" — which matters because stage 2
  must not grant anything when there are no requesters. The two copies differ
  only in width: small per-width functions beat one function taking an
  over-wide mask, because the caller would otherwise zero-extend and
  re-truncate at every call site, exactly where index bugs hide. (A third,
  wider copy over the flattened `(port, VC)` requester space used to live
  here for VA; VC matching deleted it, since a row's candidates are ports of
  one fixed VC.)
- **`xy_legal`** — the 16 legal (input, output) pairs of spec §2:

  | in → out |
  |---|
  | LOCAL → N, E, W, S |
  | NORTH → S, LOCAL |
  | EAST → W, N, S, LOCAL |
  | WEST → E, N, S, LOCAL |
  | SOUTH → N, LOCAL |

  XY dimension-order routing fixes this table independently of the
  destination: a packet arriving from the east has already had its X
  corrected, so it can only continue west, turn north/south, or terminate.
  Anything outside the table means a packet would **turn back the way it
  came** — a routing deadlock waiting to happen — so it is asserted rather
  than tolerated.
- **`credit_init` / `credit_max`** — the per-output ceiling, `LOCAL_CREDITS`
  for LOCAL and `DIR_CREDITS` everywhere else.

### 2.2 VA — row stage (lines 290–329)

For every `(o, k)` row, the candidates are the **input ports** satisfying
both

```
va_req[p][k]                                // asking at all
dir_to_idx(va_req_out_port[p][k]) == o      // asking for THIS port
```

plus rows that are not already `alloc_busy`. Note what is absent: there is
**no scan over an input VC `v`**. A row's output VC and a candidate's input
VC are the *same index k* — that is the whole content of "VC-matched" (v2
§4.4). The input VC therefore lives in the row index rather than in the
candidate list, and the candidate set collapses from `NUM_PORTS × NUM_VC`
requesters to at most `NUM_PORTS` ports. `HEAD_TAIL` ("single") requesters
still get the first tier, round-robin within it:

```systemverilog
mask = '0; single = '0; win = NUM_PORTS;
for (int p = 0; p < NUM_PORTS; p++) begin
  if (!alloc_busy[o][k] && va_req[p][k] &&
      (dir_to_idx(va_req_out_port[p][k]) == 3'(o))) begin
    mask[p] = 1'b1;
    if (va_req_single[p][k]) single[p] = 1'b1;
  end
end
if (|single) mask = single;                 // tier: prefer single-flit, else everyone
win            = rr_pick_port(mask, int'(rr_va[o][k]));
row_pidx[o][k] = OIDX_W'(win);
row_val[o][k]  = (win != NUM_PORTS);
```

The **single tier** lets a one-flit packet preempt the queue without any
deadlock risk: a long packet's row is either free (so a single competes
normally) or reserved (so the row is disabled for *everyone*, tier included —
so a single cannot starve it either).

The candidate scan runs **unconditionally** so that the row's reservation
status belongs on the eligibility test, not wrapped around the loop.
Putting the test around it instead leaves `mask`/`single`/`win` unassigned
on the reserved path, which the tool correctly reads as a latch. Same reason
for declaring them inside the innermost scope.

### 2.3 VA — final grants, and why there is no column stage (lines 331–370)

The old separable allocator had a second VA stage — a **column stage** —
because a requester could win several rows at once: it was scanned into
every row asking for its output port, so a requester holding two VCs, or
asking more than once, would end up owning two downstream VCs and could
send interleaved packets into a single VC slot. The column stage threw all
but one row away (keep the lowest `k`, break ties within a `k` on the
lowest `o`, drop the rest), and the rows it dropped were wasted even though
some *other* requester was waiting for them.

VC matching removes the problem instead of arbitrating it away. A
requester `(p, k)` is eligible only for the row `(o, k)` where `o` is the
single port `va_req_out_port[p][k]` names — it appears in **exactly one
row** and can win at most one, so every row that found a candidate is
simply granted:

```systemverilog
for (int o = 0; o < NUM_PORTS; o++)
  for (int k = 0; k < NUM_VC; k++)
    if (row_val[o][k]) begin
      va_gnt[row_pidx[o][k]][k] = 1'b1;
      va_gnt_out_vc[row_pidx[o][k]][k] = VC_W'(k);
    end
```

No second arbitration stage, no row to drop, no dropped-row waste — and
`va_kept` (§2.6) asserts the one-row property rather than leaving it as a
claim in a comment.

`va_gnt_out_vc` is driven as `k`, the row's own index, which by VC matching
is also the input VC of the requester that won it. The signal is
deliberately **not a module output** any more (v2 §4.4): because the two
indices can no longer disagree, the sideband carried no information across
the module boundary — the input port's `out_vc` register and the two wires
carrying it through `router_top` existed only to reproduce a value every
reader already knew, and they are gone. What stays is the *internal* signal,
because v2 §4.5 asks for `granted output VC == input VC index` to be
asserted and that property has no other statement (§2.8). It feeds
assertions only and folds away when they are compiled out.

### 2.4 SA — stage 1: pick one VC within an input port (lines 401–459)

```systemverilog
o = dir_to_idx(sa_req_out_port[p][v]);
if (sa_req[p][v] && (credit_count[o][sa_req_out_vc[p][v]] != '0)) mask[v] = 1'b1;
win = rr_pick_vc(mask, rr1[p]);
sel = (win != NUM_VC) ? win : 0;      // clamp before use: indexing with the
                                      // "nobody" sentinel reads past the array
s1_valid[p] = (win != NUM_VC);
```

**This is the only place credits gate anything.** A VC with no downstream
credit still holds a valid VA reservation — it simply waits here, which is
exactly what assumption D2 asks for: gating VA as well would let a packet
reserve a downstream VC it cannot use yet and block others for no benefit,
since the reservation has to survive the wait anyway.

`s1_oport` is a port **index** (the incoming `sa_req_out_port` is a
direction; the spec calls this signal `s1_out`). Converting here, once, is
what lets stage 2 compare it directly against an output loop index.

`sa_pick` is set from stage 1 alone — one-hot per port regardless of whether
stage 2 later grants it. The input port uses it to qualify which VC's flit is
presented; the crossbar independently picks the winner via `xbar_sel`. So a
**pick without a grant is harmless** (the crossbar output is masked by
`st_valid`) while a **grant without a pick** would put an unqualified flit on
the wire.

### 2.5 SA — stage 2 and results (lines 461–526)

```systemverilog
req2[p] = s1_valid[p] && (s1_oport[p] == 3'(o));
s2_any[o] = |req2;
w = OIDX_W'(rr_pick_port(req2, int'(rr2[o])));
s2_sel[o] = s2_any[o] ? w : '0;         // always a legal index
```

Because stage 1 already collapsed each input port to a single candidate, stage
2 has at most `NUM_PORTS` requesters and its winner **is** the crossbar select
— no second merge step.

`sa_results` then walks `o` and `p` with loop-constant indices rather than
indexing `xbar_sel` directly, so each per-port grant is an ordinary bit set
instead of a two-level dynamic select:

```systemverilog
if (st_valid[o]) for (p) if (OIDX_W'(p) == xbar_sel[o]) begin
  st_out_vc[o]   = s1_vc[p];
  sa_gnt[p][s1_idx[p]] = 1'b1;
end
```

### 2.6 VA — `va_kept` (the assertion-support counter) (lines 372–399)

```systemverilog
va_kept[p][v] = count of o with row_val[o][v] && row_pidx[o][v] == p;
```

A count, per (input port, VC), of how many rows that requester won this
cycle. Under VC matching it always reads 0 or 1: the candidate list is
pinned to the requester's own VC and its one target port, so `(p, k)` is
eligible for exactly one row — and that is precisely why the column stage
could be deleted (§2.3). The count stays as a live assertion rather than a
comment, so a future change that widens the candidate scan — for instance
scanning input VC `v` again "for flexibility" — fails here instead of
silently reintroducing interleaved packets on one downstream VC.

It is per **requester**, not per port, and always was: spec §4.3 counts
`5*NUM_VC` requesters — the flattened `(port, vc)` pairs. Two VCs of one
input port are two independent requesters: each has its own
`assignment_valid` in the input port, each asks with its own `va_req`, and
a separable allocator is expected to hand them two different rows in the
same cycle. A port-wide count calls a legal, and necessary, outcome a bug —
the first run of T11's mixed-VC random traffic tripped it for exactly that
reason. The grant vector cannot see a double win either: `va_gnt` is a
single bit per requester, so a second write would just overwrite the first.

Not synthesizable-significant: it feeds assertions only.

### 2.7 Credits and the sequential block (lines 528–626)

```systemverilog
cr_dec[o][k]     = st_valid[o] && (st_out_vc[o] == VC_W'(k));
cr_inc[o][k]     = ds_credit_valid[o][k];
cr_release[o][k] = st_valid[o] && s1_last[xbar_sel[o]] && (st_out_vc[o] == VC_W'(k));
```

Factored into named signals so the sequential block and the assertions talk
about **one shared condition** — an assertion that re-derives the condition it
is meant to police can drift away from the RTL and end up checking a rule
nobody implements. `cr_release` is `cr_dec` **plus** "the winner's flit is a
tail", both keyed off the same cycle, so a row cannot be released on the
strength of a tail still waiting for a credit.

Credits:

```systemverilog
if      (cr_dec && !cr_inc) credit_count <= credit_count - 1;
else if (!cr_dec &&  cr_inc) credit_count <= credit_count + 1;
```

Both true at once means a flit left and a slot was freed in the same cycle —
the two cancel, the value holds. That is spec §1.1's "net to zero" stated as
control flow rather than as arithmetic that could wrap.

Round-robin pointers advance only on a **real win**:

- `rr1[p]` advances only when the picked VC actually won stage 2
  (`s1_valid[p] && st_valid[s1_oport[p]] && xbar_sel[s1_oport[p]] == p`).
  A VC that keeps losing to a sibling and is rotated past anyway would never
  be picked again once the sibling stopped requesting — the pointer would have
  walked away from the only pending requester.
- `rr2[o]` advances whenever output `o` switched a flit.
- `rr_va[o][k]` advances when the row is granted — in **port** space,
  `(row_pidx + 1) % NUM_PORTS`, because the row is pinned to `k` and only
  the port index needs rotating.

`alloc_busy` is **release-then-reserve**, so if both ever targeted the same
row the reservation would win (the row ends up owned by the new packet — the
safe answer). They cannot in fact co-occur: VA only grants a row when
`!alloc_busy`, and `alloc_busy` stays high until the tail has switched out.
There is an assertion for exactly that.

### 2.8 Assertions (lines 628–795)

All `@(posedge clk) disable iff (!rst_n)`, unconditional SVA — the same tool
parses these today and will parse them again when the network moves to the
commercial simulator.

**Credit bounds (per output, per VC):**

| Property | Meaning |
|---|---|
| `credit_count <= credit_max(o)` | The credit loop is sized so correct traffic can never violate this; leaving the range is a **logic bug, not a congestion condition**, and is worth failing on. |
| `cr_dec \|-> credit_count != 0` | A switch-out must have a credit to spend — the same condition stage 1 masked on, so a failure means the mask and the counter disagreed within one cycle. |
| `(cr_inc && !cr_dec) \|-> credit_count < credit_max(o)` | A credit return must not overflow the downstream depth — an extra return means a slot was freed twice. |
| `cr_release \|-> alloc_busy` | A row can only fall out of the reserved state if it was reserved, checked in the same cycle against the same pre-edge value. |
| `!(cr_release && row_val)` | Reserve and release in the same cycle would leave the row owned by nobody and everybody at once. |

**SA (per input port):**

| Property | Meaning |
|---|---|
| `$countones(sa_pick[gp]) <= 1` | At most one stage-1 pick per port. |
| `$countones(sa_gnt[gp]) <= 1` | At most one stage-2 grant per port. |
| `sa_gnt \|-> sa_pick` | Otherwise the input port would be told to offer a VC that was never selected. |
| `sa_gnt \|-> credit_count[...] != 0` | Never grant a VC whose target had no credit (§4.3). Checks the grant end-to-end so a future change to the mask *or* the counter cannot drift apart silently. |
| `sa_gnt \|-> xy_legal(gp, dir_to_idx(sa_req_out_port))` | The 16 legal pairs. Fires **on the grant**, which is the point at which an illegal turn would actually reach the crossbar. |
| `sa_req \|-> $onehot0(sa_req_out_port)` | Direction codes must be one-hot-or-zero, so `dir_to_idx`'s LOCAL fallback is never what produced an answer. |
| `va_req \|-> $onehot0(va_req_out_port)` | Same for the VA path. |

**VA (per input port, per VC):**

| Property | Meaning |
|---|---|
| `va_kept[gp][gv] <= 1` | One `(port, vc)` never walks away holding two downstream VCs — see §2.6 for why this is per-requester and not per-port. |
| `va_gnt \|-> va_req` | A grant always answers a request. Structural rather than stateful — the row stage only ever considers `va_req` candidates — but it is the only check on the write through `row_pidx` back into the flattened `va_gnt` vector, which a re-indexing refactor could get wrong while leaving every other property intact. |
| `va_gnt \|-> (va_gnt_out_vc == VC_W'(gv))` | **The VC-matched rule itself (v2 §4.5):** a grant on input VC `gv` reserves output VC exactly `gv`. Stated on the grant because that is the only point where the two indices are still separately observable — past here the input port either registers the value once or derives from it, so a mismatch introduced downstream would surface as a credit miscount rather than as the misallocation it really is. Non-vacuous precisely because of how the row stage builds its mask: the candidate list is indexed by the row's own `k`, so this only holds while nobody widens it back to an arbitrary input VC (§2.6). |

---

## 3. Testing explanation

**Bench:** `tb/tb_arbiter.sv`, top module `tb_arbiter` (**84** checks).
**Run:** `make TOP=arbiter sim` → `ALL 84 CHECKS PASSED`.

### 3.1 Why 84 checks and not 800

Everything here is a small, enumerable structure: 5 ports × 4 VCs — 20
requesters — 16 legal turns out of 25, and two credit pools chosen by
output-port type (both of size 4 at the defaults). The bench therefore
targets the *interesting* transitions rather than sweeping:

- **VA allocation and VC matching (T6)** — three requesters (NORTH, EAST,
  WEST) on VC0 all asking for LOCAL: exactly one wins, and only row
  `(LOCAL, 0)` is reserved. Then the negative form: rows 1..3 are still
  free and all three are still asking, yet **nothing** is granted — a VC0
  requester cannot reach a row on any other VC (the VC-matched rule, v2
  §4.4). The remaining rows are drained one VC at a time, each needing its
  own requester, and with every row reserved nobody is granted anything at
  all. The grant's reserved VC is read back hierarchically — the bench
  samples `u_arb.va_gnt_out_vc` — and pinned to the requester's own index.
- **The single-flit tier** — a `va_req_single` (HEAD_TAIL) requester beats
  the multi-flit HEADs on the same row; a reserved row disables *both*
  tiers.
- **Round-robin fairness** — the pointers walk: T4 rotates `rr1` after a
  real win (VC0 wins, so its sibling's turn comes next), and T5 is checked
  as a four-cycle *sequence* rather than a hand-computed pointer — the
  stage-2 winner alternates NORTH/EAST while the granted VC is pinned per
  cycle, including the cycle where the loser's stage-1 pointer had **not**
  advanced, so it picks its second VC instead.
- **Stage 1 collapses an input port to one candidate (T4)** — both VCs want
  EAST, still exactly one pick and one grant for that input; and
  `st_out_vc` is pinned to the VC actually granted on every switch (T4,
  T5), because a sideband mismatch would buffer the flit downstream in the
  wrong slot while decrementing the right pool.
- **SA stage 1 credit masking (T7)** — the SOUTH pool is drained to 0: the
  VC is no longer eligible, there is no grant, nothing switches, and the
  sideband is cleared too. One returned credit makes it eligible again.
  This is the check that most directly pins "credits gate SA and nothing
  else".
- **SA stage 2 per-output exclusivity (T5)** — two input ports wanting
  LOCAL: exactly one grant into that output every cycle, `xbar_sel` names
  the winner, `st_valid` is LOCAL alone. With no requesters at all (R0) the
  grant vectors are empty and `st_valid` low.
- **Credit counter arithmetic (R0, T7)** — init value per port type
  (`DIR_CREDITS` for a directional port, `LOCAL_CREDITS` for LOCAL),
  decrement on switch, refusal at 0, increment on return, and the
  simultaneous +1/−1 case netting to zero — checked with a discriminator
  that would catch the net being applied as two decrements *or* twice in
  favour of the return.
- **`alloc_busy` set and hold (T6)** — the grant reserves the row and it
  stays reserved across cycles while the requesters keep asking; the rows
  one index along stay free throughout. Release needs a tail to switch out
  of the row, which this bench never drives — it happens in the system
  benches, while the *rules* for it are policed continuously by the
  properties in §2.8.
- **The bench's own continuous properties** — `sa_gnt |-> sa_req`, at most
  one grant per input port, and at most one grant *into* an output (a
  flattened count over `gnt_to_out`) hold on every cycle of the run,
  regardless of which directed test is active.

### 3.2 Bench mechanics

The arbiter is combinational in the request cycle with registered pointer and
credit state, so the bench drives requests, settles, samples the grants, and
then steps the clock to let the pointers and counters update. Combinational
grant checks are sampled **after a settle**, and credit-counter checks
**after** the edge that updates them — sampling the wrong side of the edge is
the classic way to make a correct counter look broken.

### 3.3 Assertion coverage

All fifteen properties in §2.8 are live throughout the run — the bench
holds the DUT in reset only at the start, so the credit bounds, the pointer
discipline and the VA contracts are checked on essentially every cycle.

`tools/assert_neg.sh` proves **two** of them actually fire, with `--assert`
**on**.

**The credit gate.** The case drops the credit term from the stage-1 mask
(§2.4), so stage 1 becomes eligible with an empty pool and the grant happens
anyway:

```
%Error: arbiter.sv:653: Assertion failed in ... gen_cr_bound[4]. gen_cr_bound_vc[0]:
        arbiter: switched out on [4][0] with no credit
```

Note it hits the *credit-bound* property first rather than the "granted with
zero credit" one — both are true of that cycle, and the tool stops at the
first violation.

**The VC-matched contract (v2 §4.5).** This one looks untestable: the row
stage builds its candidate mask from the row's own `k`, so the two indices
cannot disagree today, and a reviewer could fairly call the property
tautological. The case hands the row the *next* output VC
(`VC_W'((k + 1) % NUM_VC)` instead of `VC_W'(k)`), and the sideband
immediately reports a partner one slot along on every grant:

```
%Error: arbiter.sv:789: Assertion failed in ... gen_sa[2]. gen_va_req[0]:
        arbiter: VA granted port 2 input vc 0 but reserved output vc 1
```

If that message never appears, the property is only holding by accident —
which is the whole reason the case exists.

### 3.4 Mutation sanity

Two mutations in `tools/mutate_all.sh` target this file; both are
**killed** by `tb_router_top` (built **without** `--assert`, so these prove
the *bench* side). That bench reports `ALL 104 CHECKS PASSED` clean, and
reaches all 104 under both of these mutants as well — neither stops a
packet from arriving, so none of the bench's `rx_n()` guards swallows a
check (see `tb_router_top.md` §3.4 for why that denominator moves).

| Mutation | Result |
|---|---|
| stage-2 round-robin ignores its pointer (`idx = (start+i) % NUM_PORTS` → `idx = i`) | killed — 1/104 |
| stage-1 ignores the credit pool (`mask[v] = sa_req && credit != 0` → `mask[v] = sa_req`) | killed — 2/104 |

The first is a fairness-only bug: every flit still reaches the right output
and only the arbitration order changes — a class of bug that never shows up
as a wrong destination, which is exactly why it is worth mutating and
running against the *system* bench rather than trusting the single-module
bench to notice. The second removes the only gate on flow control, so an
empty pool hands out grants and flits go out with no credit behind them —
caught as two failures in the clean run rather than as a hang, since the
design still moves, it just stops being correct.

### 3.5 What this bench cannot show

It cannot show the VA/SA halves working *together* under real traffic — for
that the mock arbiter is replaced by the real one in `tb_router_top`, and then
by three real arbiters in `tb_router_chain`. The mixed-VC random traffic in
T11 of the chain bench is also what originally exposed the per-port VA
uniqueness assertion as wrong (§2.6), which no single-module test could have
done.
