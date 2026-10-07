# `arbiter` — `rtl/arbiter.sv`

Virtual-channel allocation, switch allocation, and credit bookkeeping for one
router. Owns everything that is **shared** between input ports; owns nothing
that is *per-VC assignment* state — that lives in `noc_input_port`. This
block never knows which packet an input port is holding, only which output it
is asking for.

Three independent pieces:

| Piece | What it does |
|---|---|
| **VA** | Flat separable allocator. A row stage picks one candidate per `(output port, output VC)` row; a column stage keeps one row per requester. **Combinational in the request cycle** — the grant is not registered (spec §1.1), so the input port latches `out_port`/`out_vc` at the same edge the arbiter latches `alloc_busy`. |
| **SA** | Two stages. Stage 1 picks one VC *within* an input port, masked by the credit count for that VC's target output. Stage 2 picks one input port *per output*. Splitting it this way is what makes the crossbar selection a single one-hot vector per output. |
| **CRED** | A counter per `(output, output VC)`. Init = free slots the *downstream* consumer has. Decrement on switch, increment on return; simultaneous +1/−1 nets to zero (spec §1.1). |

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
| `NUM_VC` | `int` | 2 | Virtual channels per port (spec §1.1). |
| `LOCAL_IDX` | `int` | 0 | Index of the LOCAL port (spec §2). |
| `DIR_CREDITS` | `int` | 8 | Neighbour input FIFO depth — init and ceiling for `credit_count[o != LOCAL][*]`. **Set from `router_top.FIFO_DEPTH`**, because a credit *is* a free slot in that FIFO. |
| `LOCAL_CREDITS` | `int` | 4 | NI receive buffer depth per VC — init and ceiling for `credit_count[LOCAL][*]`. |

Derived locals:

| Name | Value (5×2) | Meaning |
|---|---|---|
| `NREQ` | 10 | `NUM_PORTS × NUM_VC` — the flattened **requester id space** (`p*NUM_VC + v`). |
| `RIDX_W` | 4 | `$clog2(NREQ)` |
| `OIDX_W` | 3 | `$clog2(NUM_PORTS)` |
| `VIDX_W` | 1 | `$clog2(NUM_VC)` |
| `CRED_MAX` | 8 | `max(DIR_CREDITS, LOCAL_CREDITS)` |
| `CRED_W` | 4 | `$clog2(CRED_MAX + 1)` — the counters must hold `0..CRED_MAX` |

### 1.2 Port declaration

Direction is from the DUT's point of view.

| Signal | Width | Direction | Source → Destination | Working / description |
|---|---|---|---|---|
| `clk` | 1 | input | clock generator → `always_ff`, all SVA | Rising edge. |
| `rst_n` | 1 | input | reset generator → `always_ff`, `disable iff` | Synchronous, active low, matching `fifo.sv`. |
| `va_req` | `NUM_PORTS × NUM_VC` | input | `noc_input_port.req_va` → VA row stage | This VC holds a HEAD/HEAD_TAIL and does not yet own a downstream VC. |
| `va_req_out_port` | `NUM_PORTS × NUM_VC × 4` | input | `noc_input_port.va_req_out_port` → `dir_to_idx` in the row stage | The output port the packet needs from *this* router, as a one-hot direction code. |
| `va_req_single` | `NUM_PORTS × NUM_VC` | input | `noc_input_port.va_req_single` → VA tier select | The packet is a single flit (HEAD_TAIL); VA gives it the higher priority tier. |
| `va_gnt` | `NUM_PORTS × NUM_VC` | **output** | VA → `noc_input_port.req_va` handshake / `assignment_valid` set | One bit per **requester** (flattened port,vc). |
| `va_gnt_out_vc` | `NUM_PORTS × NUM_VC × 2` | **output** | VA → `noc_input_port.out_vc[v]` | Which downstream VC was assigned; latched for the packet's life. |
| `sa_req` | `NUM_PORTS × NUM_VC` | input | `noc_input_port.req_sa` → SA stage 1 | This VC holds a flit **and** owns a downstream VC. |
| `sa_req_out_port` | `NUM_PORTS × NUM_VC × 4` | input | `noc_input_port.sa_req_out_port` → `dir_to_idx` | Output direction it wants (stage-2 target), one-hot code. |
| `sa_req_out_vc` | `NUM_PORTS × NUM_VC × 2` | input | `noc_input_port.sa_req_out_vc` → credit mask index | Which downstream VC it targets — indexes `credit_count`. |
| `sa_req_last` | `NUM_PORTS × NUM_VC` | input | `noc_input_port.sa_req_last` → `s1_last` → `cr_release` | The active flit is the packet's last. A level; the arbiter ANDs it with its own grant before releasing the row. |
| `sa_gnt` | `NUM_PORTS × NUM_VC` | **output** | SA stage 2 → `noc_input_port` (fetch rule, assignment release), `router_top.a_sa_gnt` | Stage 2 granted this VC; its flit crosses this cycle. |
| `sa_pick` | `NUM_PORTS × NUM_VC` | **output** | SA stage 1 → `noc_input_port` OR-mux, `router_top.a_sa_pick` | Stage-1 pick. One-hot per port *regardless* of whether stage 2 later grants it. `sa_gnt` implies `sa_pick`. |
| `xbar_sel` | `NUM_PORTS × 3` | **output** | SA stage 2 → `crossbar.xbar_sel` | `xbar_sel[o]` = **input port index** leaving through output `o`. Driven `0` when nobody asks — always a legal index; `st_valid` masks it all the way to the link register. |
| `st_valid` | `NUM_PORTS` | **output** | SA stage 2 → crossbar, output ports, credit decrement, `router_top` seam assertion | `st_valid[o]` = some input port won output `o` this cycle. |
| `st_out_vc` | `NUM_PORTS × 2` | **output** | SA results → `noc_output_port.st_out_vc` (the `vc_id` sideband) | The winning flit's downstream VC. Cleared when `!st_valid` rather than left stale, so a future bug in that gating cannot silently corrupt credit accounting. |
| `ds_credit_valid` | `NUM_PORTS × NUM_VC` | input | downstream router's `credit_return_valid` (or the NI) → `cr_inc` | `ds_credit_valid[o][k]` = a free slot appeared downstream in output `o`, VC `k`. Per-VC vector rather than one pulse plus a tag, because two VCs can fetch in the same cycle (assumption D1). |

### 1.3 Registers and state

| Name | Width | Kind | Reset | Working / description |
|---|---|---|---|---|
| `alloc_busy` | `NUM_PORTS × NUM_VC` | register | `'0` | A row `(output o, output VC k)` is reserved once VA grants it, and stays reserved until the **last** flit of that packet wins SA — so no second packet can be handed the same downstream VC while the first is still draining into it. |
| `credit_count` | `NUM_PORTS × NUM_VC × CRED_W` | register | `credit_init(o)` — `LOCAL_CREDITS` for `o == LOCAL_IDX`, else `DIR_CREDITS` | Free slots downstream. The whole credit loop (spec §6) exists to keep this in `[0, credit_max(o)]`. |
| `rr_va[o][k]` | `RIDX_W` each (`[NUM_PORTS][NUM_VC]`) | register | `'0` | Which **requester** a row considers first. Indexed over the flattened (port, VC) space, because fairness has to be across *requesters*, not ports — otherwise a port with two busy VCs gets twice the service of one with a single VC. Advanced to `(winner + 1) % NREQ` when the row is granted. |
| `rr1[p]` | `VIDX_W` each (`[NUM_PORTS]`) | register | `'0` | Which VC of input port `p` SA stage 1 considers first. |
| `rr2[o]` | `OIDX_W` each (`[NUM_PORTS]`) | register | `'0` | Which input port output `o` considers first in stage 2. |
| `row_ridx`, `row_val` | `RIDX_W` / 1 each (`[NUM_PORTS][NUM_VC]`) | wire (combinational) | n/a | VA row-stage output: winning requester (or `NREQ` = nobody) and whether the row produced a winner. |
| `keep` | `NUM_PORTS × NUM_VC` | wire (combinational) | n/a | VA column-stage output: this row survived. Feeds `va_gnt`, `alloc_busy` set, and the VA assertions. |
| `va_kept` | `NUM_PORTS × NUM_VC` (`int unsigned`) | wire (combinational) | n/a | **Assertion-only.** Rows kept *per requester*, counted from `keep[]` (§2.6). Folds away entirely when assertions are compiled out. |
| `s1_valid`, `s1_idx`, `s1_vc`, `s1_oport`, `s1_last` | `NUM_PORTS` each (widths `1`/`VIDX_W`/`2`/`3`/`1`) | wire (combinational) | n/a | SA stage-1 results: a candidate exists, which VC, its downstream VC, its **output port index** (direction converted here, once), and whether it is the packet's last flit. |
| `s2_sel`, `s2_any` | `NUM_PORTS × 3` / `NUM_PORTS` | wire (combinational) | n/a | SA stage-2 results; drive `xbar_sel` and `st_valid` directly. |
| `cr_dec`, `cr_inc`, `cr_release` | `NUM_PORTS × NUM_VC` each | wire (combinational) | n/a | Credit direction flags and the row-release condition, factored out so the sequential block and the assertions talk about **one shared signal** (§2.7). |

---

## 2. RTL explanation

### 2.1 Helpers

- **`dir_to_idx`** — one-hot direction → port index (`0000→0 … 1000→4`),
  "set-bit position plus one, with all-zero mapping to LOCAL". An illegal
  code falls back to LOCAL as a *defined* fallback; a separate assertion
  catches the code being illegal in the first place, so the fallback can
  never mask a real bug by quietly routing to the wrong port.
- **`rr_pick_req` / `rr_pick_vc` / `rr_pick_port`** — round-robin over a
  mask, starting the search **at** `start` and wrapping. Returns the selected
  index, or the **mask width itself** ("nobody") when the mask is empty.
  Returning an out-of-range value rather than a sentinel of 0 keeps "no
  winner" distinguishable from "port 0 won" — which matters because stage 2
  must not grant anything when there are no requesters. Three small copies
  beat one function taking an over-wide mask: the caller would otherwise
  zero-extend and re-truncate at every call site, exactly where index bugs
  hide.
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

### 2.2 VA — row stage

For every `(o, k)` row: gather the requesters asking for output `o`, keep
only rows that are not already `alloc_busy`, then pick one candidate —
`HEAD_TAIL` ("single") requesters first, round-robin within that tier.

```systemverilog
mask   = '0; single = '0; win = NREQ;
for (int r = 0; r < NREQ; r++) begin
  p = r / NUM_VC; v = r % NUM_VC;
  if (!alloc_busy[o][k] && va_req[p][v] &&
      (dir_to_idx(va_req_out_port[p][v]) == 3'(o))) begin
    mask[r] = 1'b1;
    if (va_req_single[p][v]) single[r] = 1'b1;
  end
end
if (!alloc_busy[o][k] && (|single)) mask = single;
win = rr_pick_req(mask, int'(rr_va[o][k]));
```

The **single tier** lets a one-flit packet preempt the queue without any
deadlock risk: a long packet's row is either free (so a single competes
normally) or reserved (so the row is disabled for *everyone*, tier included —
so a single cannot starve it either).

The candidate scan runs **unconditionally** so that `p` and `v` are assigned
on every path; the row's reservation status belongs on the eligibility test,
not wrapped around the loop. Putting the test around it instead leaves
`p`/`v` unassigned on the reserved path, which the tool correctly reads as a
latch. Same reason for declaring `mask`/`single`/`win`/`p`/`v` inside the
innermost scope.

### 2.3 VA — column stage

A requester that won several rows may only keep one: a downstream VC is a
resource it now owns exclusively, and holding two would mean sending
interleaved packets into a single VC slot. It keeps the **lowest `k`**, and
ties within the same `k` break to the **lowest `o`**, so the result is
deterministic and identical on every simulator. The dropped rows grant nobody
at all this cycle.

```systemverilog
if (ki) begin
  for (o2, k2) if ((o2 != o || k2 != k) && row_val[o2][k2] && (row_ridx[o2][k2] == r))
    if ((k2 < k) || ((k2 == k) && (o2 < o))) ki = 1'b0;
end
keep[o][k] = ki;
```

A row that lost its column vote is simply wasted even though some *other*
requester was waiting for it. The spec accepts this (§4.3 step 3) and says to
revisit it only if the performance model says so — a back-to-back column
re-arbitration would cost another combinational level on the VA path for a
case the model has not yet shown to matter.

### 2.4 SA — stage 1: pick one VC within an input port

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

### 2.5 SA — stage 2 and results

```systemverilog
req2[p] = s1_valid[p] && (s1_oport[p] == o);
s2_any[o] = |req2;
w = OIDX_W'(rr_pick_port(req2, rr2[o]));
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

### 2.6 VA — `va_kept` (the assertion-support counter)

```systemverilog
va_kept[p][v] = count of keep[o][k] with row_ridx[o][k] == (p*NUM_VC + v);
```

A count, per (port, VC), of how many rows survived the column stage **for
that requester**. It exists so the column stage's contract can be asserted
directly: `va_gnt` is a *single bit per requester*, so "the same requester won
twice" is invisible in the grant vector — the second write just overwrites the
first and `va_gnt_out_vc` silently reports the losing row's partner. Counting
`keep[]` sees the event.

This matters because the earlier, wrong form of that assertion counted
**ports** (`$countones(va_gnt[gp]) <= 1`). Spec §4.3 counts `5*NUM_VC`
requesters — the flattened `(port, vc)` pairs. Two VCs of one input port are
two independent requesters: each has its own `assignment_valid` and `out_vc`
in the input port, each asks with its own `va_req`, and a separable allocator
is expected to hand them two different rows in the same cycle. A port-wide
count calls a legal, and necessary, outcome a bug — the first run of T11's
mixed-VC random traffic tripped it for exactly that reason.

Not synthesizable-significant: it feeds assertions only.

### 2.7 Credits and the sequential block

```systemverilog
cr_dec[o][k]    = st_valid[o] && (st_out_vc[o] == k);
cr_inc[o][k]    = ds_credit_valid[o][k];
cr_release[o][k]= st_valid[o] && s1_last[xbar_sel[o]] && (st_out_vc[o] == k);
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
- `rr_va[o][k]` advances when the row is granted.

`alloc_busy` is **release-then-reserve**, so if both ever targeted the same
row the reservation would win (the row ends up owned by the new packet — the
safe answer). They cannot in fact co-occur: VA only grants a row when
`!alloc_busy`, and `alloc_busy` stays high until the tail has switched out.
There is an assertion for exactly that.

### 2.8 Assertions

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
| `!(cr_release && keep)` | Reserve and release in the same cycle would leave the row owned by nobody and everybody at once. |

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
| `va_gnt \|-> va_req` | A grant always answers a request. Structural rather than stateful — the row stage only ever considers `va_req` candidates — but it is the only check on the decode back out of `row_ridx`, which is a **division by `NUM_VC`** that a re-indexing refactor could get wrong while leaving every other property intact. |
| `(va_gnt && va_gnt_out_vc == gk) \|-> keep[dir_to_idx(va_req_out_port)][gk]` | A grant must name a row the column stage actually kept. Checked in the same cycle rather than one edge later: `alloc_busy` only becomes 1 at the following posedge, and reaching across that edge would also have to re-read `va_req_out_port` in the later cycle, where the requester may already have moved on. Iterating over possible output VCs rather than indexing with `va_gnt_out_vc` directly, because that field is 2 bits while a row index is only `clog2(NUM_VC)` wide — indexing with it would silently **truncate (2 → 0)** and check the wrong row instead of failing. |

---

## 3. Testing explanation

**Bench:** `tb/tb_arbiter.sv`, top module `tb_arbiter` (**83** checks).
**Run:** `make TOP=arbiter sim` → `ALL 83 CHECKS PASSED`.

### 3.1 Why 83 checks and not 800

Everything here is a small, enumerable structure: 5 ports × 2 VCs, 10
requesters, 16 legal turns out of 25, two credit pools of two different
sizes. The bench therefore targets the *interesting* transitions rather than
sweeping:

- **VA allocation and exclusivity** — two requesters asking for the same
  `(o, k)` row: exactly one wins, and it is the one whose `va_gnt_out_vc`
  names that row. Several rows won by one requester: exactly one survives
  (the column stage), and it is the lowest `k`.
- **The single-flit tier** — a `va_req_single` requester beats a multi-flit
  requester on the same row; a reserved row disables *both* tiers.
- **Round-robin fairness** — the pointers walk: repeated grants rotate the
  winner rather than sticking to index 0, and a **non-winning** pick does not
  advance `rr1` (the case that would strand the only pending requester, §2.7).
- **SA stage 1 credit masking** — with `credit_count == 0` for a VC's target,
  that VC is not eligible and its sibling is picked instead; with credit
  restored it becomes eligible again. This is the check that most directly
  pins "credits gate SA and nothing else".
- **SA stage 2 per-output exclusivity** — two input ports wanting the same
  output: one grant, `xbar_sel` names it, `st_valid` high. No requesters:
  `st_valid` low and `xbar_sel` still a legal index.
- **`xy_legal` exhaustively** — all 25 (in, out) pairs driven, the 16 legal
  ones accepted and the 9 illegal ones rejected at the function level.
- **Credit counter arithmetic** — init value per port type (`LOCAL_CREDITS`
  for LOCAL, `DIR_CREDITS` elsewhere), decrement on switch, increment on
  return, and the simultaneous +1/−1 case netting to zero; plus the boundary
  values 0 and `credit_max`.
- **`alloc_busy` set / hold / release** — a reservation persists across
  non-tail grants and clears only when the tail switches out of that row.

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

`tools/assert_neg.sh` proves one of them actually fires, with `--assert`
**on**:

```
%Error: arbiter.sv:663: Assertion failed in ... gen_cr_bound[4]. gen_cr_bound_vc[0]:
        arbiter: switched out on [4][0] with no credit
```

That case removes the credit term from the stage-1 mask (§2.4), so stage 1
becomes eligible with an empty pool and the grant happens anyway. Note it
hits the *credit* assertion first rather than the "granted with zero credit"
one — both are true, and the tool stops at the first violation.

### 3.4 Mutation sanity

Two mutations in `tools/mutate_all.sh` target this file; both are killed by
`tb_router_top` (built **without** `--assert`, so these prove the *bench*
side):

| Mutation | Result |
|---|---|
| stage-2 round-robin ignores its pointer (`idx = (start+i) % NUM_PORTS` → `idx = i`) | 1/108 CHECKS FAILED |
| stage-1 ignores the credit pool (`mask[v] = sa_req && credit != 0` → `mask[v] = sa_req`) | 2/108 CHECKS FAILED |

The first is a fairness-only bug, so it produces exactly one failed check —
the fairness assertion — rather than a systemic failure. That is the correct
outcome: the design still works, it is just unfair.

### 3.5 What this bench cannot show

It cannot show the VA/SA halves working *together* under real traffic — for
that the mock arbiter is replaced by the real one in `tb_router_top`, and then
by three real arbiters in `tb_router_chain`. The mixed-VC random traffic in
T11 of the chain bench is also what originally exposed the per-port VA
uniqueness assertion as wrong (§2.6), which no single-module test could have
done.
