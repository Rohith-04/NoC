# `mock_arbiter` — `tb/mock_arbiter.sv`

Testbench support module: stands in for the real `rtl/arbiter.sv` when a single
input port is under test. The arbiter is build step 3 of the design, and even
once it exists a port-level bench needs a grant source it can control *to the
cycle* — the `noc_input_port` header's timeline is a table of exact cycle
numbers ("H on link in c0 → … → grant in c2"), and a real allocator's answer
depends on state in five other input ports that a port-level bench does not
have.

The mock models exactly two behaviours and nothing else: VA accepts
combinationally in the request cycle, and SA picks one VC of this port and
grants it immediately. Everything the real arbiter adds on top — credits, row
reservations, XY legality, stage-2 fairness — is deliberately absent, so that
the input port's own behaviour is the only thing its bench can be failing
about.

It has no bench of its own. `tb/tb_noc_input_port.sv` instantiates it twice and
is the only consumer.

---

## 1. Ports and state

### 1.1 Parameter

| Name | Type | Default | Meaning |
|---|---|---|---|
| `NUM_VC` | `int` | 2 | Number of input VCs this instance serves. The pointer arithmetic in §2.3 and the `~rr_sa` pick in §2.2 are written for `NUM_VC == 2`, which is what the only instantiation uses (`localparam int NUM_VC = 2` in `tb_noc_input_port`). |

### 1.2 Port declaration

Direction is from the mock's point of view: `input` = driven by the instantiating
bench / the `noc_input_port` instance it stands beside, `output` = driven by the
mock and fed back into that input port or read out by the bench.

| Signal | Width | Direction | Source → Destination | Working / description |
|---|---|---|---|---|
| `clk` | 1 | input | bench clock → state update block | The only sequential element in the mock; pointers and counters commit on `posedge clk`. |
| `rst_n` | 1 | input | bench reset → `always_ff` | Active-low **synchronous** reset: clears `rr_sa`, `va_rr[*]` and both counters. Because every test in `tb_noc_input_port` starts with `do_reset()`, this is also what resets the grant totals between tests. |
| `va_req` | `[NUM_VC-1:0]` | input | input port's `req_va` → VA accept logic | One bit per input VC asking for a downstream VC, combinationally a function of the port's registers only. |
| `va_gnt` | `[NUM_VC-1:0]` | output | VA accept logic → input port's `va_gnt` | `va_gnt = va_req`: accepted in the *request* cycle, no grant register. |
| `va_gnt_out_vc` | `[1:0] va_gnt_out_vc [NUM_VC]` (unpacked, `NUM_VC` × 2) | output | per-input-VC pointer → input port's assignment register | The output VC handed to each requesting input VC: the current value of `va_rr[v]`, which advances only *after* the grant (§2.3). |
| `sa_req` | `[NUM_VC-1:0]` | input | input port's `req_sa` → SA pick logic | One bit per input VC with a flit ready to switch. |
| `sa_gnt` | `[NUM_VC-1:0]` | output | SA pick logic → input port (the fetch/switch grant) | Always identical to `sa_pick` — grant follows pick in the same cycle. |
| `sa_pick` | `[NUM_VC-1:0]` | output | SA pick logic → input port's datapath mux qualifier | At most one bit set: one datapath per input port, so only one VC may be presented per cycle. |
| `n_va_grants` | 32 (`int unsigned`) | output | `va_cnt` → bench | Running total of VA grants since the last reset; the bench asserts absolute totals against it. |
| `n_sa_grants` | 32 (`int unsigned`) | output | `sa_cnt` → bench | Running total of SA grants since the last reset. |

### 1.3 Registers and state

| Name | Width | Kind | Reset | Working / description |
|---|---|---|---|---|
| `NUM_VC` | int | `parameter` | n/a | See §1.1; also sizes `va_rr`, `va_req`, `va_gnt`, `sa_req`, `sa_gnt`, `sa_pick`. |
| `va_rr[NUM_VC]` | 2 each | array (unpacked of `logic [1:0]`) | `0` on `!rst_n` | Per-input-VC round-robin pointer **over the output VCs**. Independent per input VC, so `out_vc` capture in the input port gets exercised with more than one value instead of a constant zero. |
| `rr_sa` | 1 | register | `0` on `!rst_n` | Stage-1 pointer across this port's VCs. One bit because there are two VCs; `~rr_sa` is therefore "the other VC" (§2.2). |
| `va_cnt` | 32 (`int unsigned`) | register | `0` on `!rst_n` | VA grant counter, exported as `n_va_grants` (§2.4). |
| `sa_cnt` | 32 (`int unsigned`) | register | `0` on `!rst_n` | SA grant counter, exported as `n_sa_grants` (§2.4). |
| `va_gnt`, `va_gnt_out_vc`, `sa_gnt`, `sa_pick` | `NUM_VC`, `NUM_VC`×2, `NUM_VC`, `NUM_VC` | `wire` (`always_comb`) | n/a | Combinational outputs. They hold no state — they are functions of `va_req`, `sa_req` and the two pointers — which is the whole point of the mock: no grant is ever registered, so nothing can arrive a cycle later than the spec says. |

---

## 2. RTL explanation

### 2.1 VA — accept in the request cycle (lines 56–68)

```systemverilog
always_comb begin
  va_gnt = va_req;
  for (int v = 0; v < NUM_VC; v++) begin
    va_gnt_out_vc[v] = va_rr[v];
  end
end
```

Two decisions, both combinational:

- **Accept everything.** `va_gnt = va_req` means a request is granted in the
  same cycle it is made. That is not laziness: the spec locks this behaviour
  ("the allocator is combinational in the request cycle; the input port latches
  `assignment_valid` at the clock edge"), and the input port's arrival-cycle
  timing — `va_req` in c1, `req_sa` in c2 — depends on it. Making the grant
  registered would shift every cycle number in the port's timeline by one and
  turn a design bug into a bench bug.
- **Hand out `out_vc` from a per-input-VC pointer.** `va_gnt_out_vc[v]` is
  simply `va_rr[v]` *before* it advances, so the value the port captures at the
  edge is the current pointer value and the rotation is visible to the next
  grant. Rotating per input VC (rather than one pointer for the whole port) is
  what lets a test see `out_vc` walk `0, 1, 0, …` instead of always `0`.

There is no combinational loop risk, and the comment says why: `va_req` is a
function of registers only (`head_valid`, `assignment_valid`, `arrive`, and
`data_out` through `route_compute`), so feeding it straight back combinationally
closes no cycle.

### 2.2 SA — one round-robin pick, granted immediately (lines 70–86)

```systemverilog
always_comb begin
  sa_pick = '0;

  if (sa_req[rr_sa]) begin
    sa_pick[rr_sa] = 1'b1;
  end
  else if (sa_req[~rr_sa]) begin
    sa_pick[~rr_sa] = 1'b1;
  end

  sa_gnt = sa_pick;
end
```

The pick searches **at** `rr_sa` first and falls back to the other VC — a
round-robin over a two-element set, written with the branch order rather than
with an index loop. `~rr_sa` works because `rr_sa` is a single bit: for
`NUM_VC == 2` it is exactly `(rr_sa + 1) % NUM_VC`. The result is one-hot by
construction (the two arms are mutually exclusive and `sa_pick` starts at zero),
which is the property the input port actually depends on: it has one datapath to
the crossbar, so only one VC's flit can be presented per cycle.

`sa_gnt = sa_pick` collapses the real arbiter's stage 2. Here that stage has a
single client — one input port — so there is nothing to arbitrate *between*, and
the property that survives the collapse is the one the port cares about: **at
most one VC switched per port per cycle, and `sa_gnt` always implies
`sa_pick`**. A pick without a grant would be harmless at this seam (the crossbar
output is masked by `st_valid`); a grant without a pick would put an unqualified
flit on the wire, so the mock makes the two identical and the port can rely on
it.

### 2.3 State updates (lines 88–124)

Everything is in one `always_ff @(posedge clk)` with a synchronous `!rst_n`
branch that zeroes `rr_sa`, `va_cnt`, `sa_cnt` and every `va_rr[v]`.

After reset, two independent rotations:

- **`va_rr[v]` advances when `va_gnt[v]` is high**, wrapping at `NUM_VC - 1`:

  ```systemverilog
  va_rr[v] <= (va_rr[v] == 2'(NUM_VC - 1)) ? 2'd0 : (va_rr[v] + 2'd1);
  ```

  The wrap is the interesting part, and the comment gives the failure it
  prevents: *"Without the wrap a round-robin pointer on 2 bits walks 0,1,2,3 and
  hands out `out_vc=2` — an index that does not exist for `NUM_VC=2`, which
  would be stored by the input port and then used as a credit-mask index."* In
  other words, a missing `+1`-wrap would not fail inside the mock at all; it
  would produce a plausible-looking VC number that the port stores and the real
  arbiter later indexes with.

- **`rr_sa` advances only when `|sa_gnt`** — i.e. only when the picked VC
  actually had a request outstanding (grant always follows pick here, so "was
  granted" and "was picked with a request" are the same event). A pointer that
  rotated on a pick with no request would walk away from the only pending VC and
  never come back, since with two elements there is no other candidate to fall
  back to.

Both rotations happen at the edge *after* the combinational grant, so during the
grant cycle the outputs still show the pre-advance values — which is what makes
`va_gnt_out_vc` the value the port is supposed to latch.

### 2.4 The exported counters (lines 119–127)

```systemverilog
for (int v = 0; v < NUM_VC; v++) begin
  if (va_gnt[v]) va_cnt <= va_cnt + 1;
  if (sa_gnt[v]) sa_cnt <= sa_cnt + 1;
end
...
assign n_va_grants = va_cnt;
assign n_sa_grants = sa_cnt;
```

Both counters exist so a test can assert that nothing was granted twice, twice
over, or dropped — a grant that fired for two cycles where the port expected one
would show up as an inflated total even if every individual cycle looked
plausible, and a dropped grant shows up as a short one. They are exported as
plain `int unsigned` outputs rather than read hierarchically, so the bench sees
them like any other DUT response.

One precision is worth stating: the increments are non-blocking assignments
inside a `for` loop, so if **two** VCs were granted in the same cycle both
iterations would schedule `va_cnt + 1` with the same right-hand side and the
counter would advance by **one**, not two — it counts *cycles with a grant*
rather than individual grants in that corner. `sa_gnt` cannot hit the corner at
all (it is one-hot), and `tb_noc_input_port` never raises two VA requests in the
same cycle (§3), so every total the bench asserts is exactly the number of
grants.

### 2.5 What the mock is not

There are no assertions in this file, no credit arithmetic and no notion of an
output port: `va_req_out_port`, `sa_req_out_port`, `sa_req_out_vc`,
`sa_req_last`, `va_req_single` and `ds_credit_valid` have no counterpart here at
all. §3 lists what that costs, and which of those gaps the real arbiter's own
bench fills.

---

## 3. Testing explanation

**Dependent bench:** `tb/tb_noc_input_port.sv` — two instances, `u_relay_mock`
(line 233, beside the directional/relay port `u_relay`) and `u_local_mock`
(line 332, beside the LOCAL port `u_local`). Both are wired with `NUM_VC = 2`.
**Run:** `make TOP=noc_input_port sim` — reports `Checks : 139` / `Errors : 0`
/ `ALL TESTS PASSED` (that bench uses its own `report`/`chk`/`chk2`/`chk4`/
`chk_bit` family, which funnels four width-specific wrappers into one
bookkeeping task, rather than the single 32-bit `check` used by the other
benches).

There is no `make TOP=mock …` and no `tb_mock_arbiter.sv`: the mock's
correctness is established only indirectly, by the expectations the input-port
bench pins against it. The Makefile compiles `tb/mock_arbiter.sv` into *every*
build (any `tb/` file not named `tb_*.sv` is treated as support), `files.f` lists
it for the slang-server/VCS flow, and `tools/assert_neg.sh` adds it to its build
line explicitly — it is never the top module.

### 3.1 How the bench wires it in

The mock's outputs are copied back into the DUT element by element rather than
by a whole-array assignment:

```systemverilog
always_comb begin
  r_va_gnt   = r_m_va_gnt;
  r_sa_gnt   = r_m_sa_gnt;
  r_sa_pick  = r_m_sa_pick;
  for (int v = 0; v < NUM_VC; v++) begin
    r_va_gnt_out_vc[v] = r_m_va_out_vc[v];
  end
end
```

— so the per-VC correspondence is explicit instead of hidden behind an array
assignment (and every port endpoint stays a whole signal or a plain scalar, per
the README's wiring rules). The mock's `va_req`/`sa_req` inputs are the port's
`req_va`/`req_sa`, so the request → grant path is a genuine combinational loop
*through the DUT's registers*, exactly as it is in the real router.

### 3.2 What the bench asserts about the mock

- **Combinational VA timing (T9, T2, T8, R1, L1, V1).** Every test's cycle table
  assumes `va_req` in cycle *n* produces `va_gnt` in the same cycle *n* and
  `req_sa` in *n+1*. T9's c1/c2 and T2's c1/c2 are the sharpest expressions of
  it; if the mock registered its grant, those checks fail on the first test.
- **`out_vc` rotation and wrap (T2, L1, V1).** `T2 c2 sa_req_out_vc` is checked
  against `2'd0` with the comment *"mock's first pick"*; L1 requires `0`, then
  `1`, then `0` again across three packets (the `va_rr` wrap of §2.3); V1 relies
  on `rr_sa` alternation, stated in the test comment as *"the mock's stage-1
  pointer alternates, so VC0 switches first and VC1 one cycle later"*.
- **One pick, one grant (T9, V1).** `V1 c2` requires `sa_gnt[0] == 1` *and*
  `sa_gnt[1] == 0` — one grant per port per cycle — with `sa_pick[0]` high
  beside it, i.e. grant-implies-pick made observable.
- **Grant totals (11 checks).** T2 `1 VA / 3 SA`, T8 `1/2`, R1 `2/2`, L1 `3/3`
  (on the local mock's counters), V1 `2/2`, and C1's
  `flits switched = n_sa - n_before = 6`. These totals are per-test because each
  test starts with `do_reset()`, which holds `rst_n` low across four posedges and
  so clears `va_cnt`/`sa_cnt` through the mock's own reset branch. C1 takes a
  baseline (`n_before`) after its reset and compares the delta, which is the same
  number but survives a future change where the counters were not cleared.

The mock is *not* the subject of any assertion: `mock_arbiter.sv` contains zero
`assert property` statements, and the SVA that runs in this build belongs to
`noc_input_port` (its flit-sequence and protocol properties), not to the mock.

### 3.3 What the mock guarantees

- VA accepts **in the request cycle** — the spec-locked timing the whole port
  timeline rests on.
- `out_vc` is chosen **round-robin per input VC**, wrapping at `NUM_VC - 1`, so
  it is never an out-of-range index and never a constant zero.
- **At most one VC picked and granted per port per cycle**, and
  `sa_gnt` always implies `sa_pick`.
- Grants are **immediate and combinational** — nothing is registered between
  request and grant, so grant timing is entirely the bench's to control.
- **Deterministic, cycle-exact behaviour** with no dependence on any other port.
- **Exported totals** (`n_va_grants`, `n_sa_grants`) so "granted twice / granted
  never" is checkable as an arithmetic fact rather than inferred from a single
  observed cycle.

### 3.4 What it deliberately does not model

- **Credits.** There is no `credit_count` and no credit gate: SA grants
  whenever the port asks. The real arbiter masks stage 1 on the credit pool, and
  the exhaustion/recovery behaviour that mask exists for is tested against the
  real thing — `tb_arbiter`'s T7 and `tools/assert_neg.sh`'s
  *"arbiter: stage-1 ignores the credit pool"* case.
- **VA contention and reservation.** No `alloc_busy`, no row/column stages, no
  possibility of a request being *refused*. A port bug that only appears when VA
  says no cannot be seen here; `tb_arbiter`'s T6 covers refusal, column drops and
  pointer discipline against the real allocator.
- **The single-flit tier.** `va_req_single` has no port on the mock — every
  request is treated identically, so HEAD_TAIL preemption is out of scope.
- **Direction / XY legality.** The mock has no `*_req_out_port` inputs at all;
  it never looks at where a packet wants to go. The `xy_legal` property and the
  `$onehot0` direction checks live in the real arbiter.
- **Stage 2 and multi-port fairness.** With one client there is nothing to
  arbitrate between, so `rr2`-style fairness across input ports, `xbar_sel`,
  `st_valid` and `st_out_vc` do not exist here. Those seams are `tb_arbiter`'s
  and `tb_crossbar`'s.
- **`sa_req_last` / tail-driven release.** No packet notion, so no release
  condition.
- **`NUM_VC != 2`.** The `~rr_sa` pick and the single-bit `rr_sa` are correct
  only for two VCs; a wider configuration would need the same `rr_pick_vc`
  search the real arbiter uses. The one instantiation passes `NUM_VC = 2`, and
  `tb_noc_input_port` locks it with `localparam int NUM_VC = 2`.

The dividing line is intentional: anything the mock *does* model is a behaviour
the input port's spec fixes (combinational accept, one VC per cycle, a
well-formed `out_vc`), so a mismatch between mock and port is always a port bug.
Everything the mock omits is behaviour that belongs to the shared allocator and
is covered where that allocator actually exists.
