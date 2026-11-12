> Dynamic-VA update: the mock controls grant timing; `tb_noc_input_port`
> supplies the allocated-VC sideband separately. Original tests use an identity
> map; the new assignment test rotates within each traffic class. See [the current allocator](../rtl/arbiter.md) for actual downstream matching.

# `mock_arbiter` - `tb/mock_arbiter.sv`

Testbench support module: stands in for the real `rtl/arbiter.sv` when a single
input port is under test. The arbiter is build step 3 of the design, and even
once it exists a port-level bench needs a grant source it can control *to the
cycle* - the `noc_input_port` header's timeline is a table of exact cycle
numbers ("H on link in c0 → … → grant in c2"), and a real allocator's answer
depends on state in five other input ports that a port-level bench does not
have.

The mock models exactly two behaviours and nothing else: VA accepts
combinationally in the request cycle, and SA picks one VC of this port and
grants it immediately. Everything the real arbiter adds on top - credits, row
reservations, XY legality, stage-2 fairness - is deliberately absent, so that
the input port's own behaviour is the only thing its bench can be failing
about.

It has no bench of its own. `tb/tb_noc_input_port.sv` instantiates it twice and
is the only consumer.

---

## 1. Ports and state

### 1.1 Parameter

| Name | Type | Default | Meaning |
|---|---|---|---|
| `NUM_VC` | `int` | 4 | Number of input VCs this instance serves. Passed down from `tb_noc_input_port`, which declares `parameter int NUM_VC = 4` and overrides it on both instances. The SA scan in §2.2 and the pointer wrap in §2.3 are written over the whole VC range (`VC_W` derived as `(NUM_VC > 1) ? $clog2(NUM_VC) : 1`), so the suite's 2, 4 and 8 all work. |

### 1.2 Port declaration

Direction is from the mock's point of view: `input` = driven by the instantiating
bench / the `noc_input_port` instance it stands beside, `output` = driven by the
mock and fed back into that input port or read out by the bench.

| Signal | Width | Direction | Source → Destination | Working / description |
|---|---|---|---|---|
| `clk` | 1 | input | bench clock → state update block | The only sequential element in the mock; pointers and counters commit on `posedge clk`. |
| `rst_n` | 1 | input | bench reset → `always_ff` | Active-low **synchronous** reset: clears `rr_sa` and both counters. Because every test in `tb_noc_input_port` starts with `do_reset()`, this is also what resets the grant totals between tests. |
| `va_req` | `[NUM_VC-1:0]` | input | input port's `req_va` → VA accept logic | One bit per input VC asking for a downstream VC, combinationally a function of the port's registers only. |
| `va_gnt` | `[NUM_VC-1:0]` | output | VA accept logic → input port's `va_gnt` | `va_gnt = va_req`: accepted in the *request* cycle, no grant register. |
| `sa_req` | `[NUM_VC-1:0]` | input | input port's `req_sa` → SA pick logic | One bit per input VC with a flit ready to switch. |
| `sa_gnt` | `[NUM_VC-1:0]` | output | SA pick logic → input port (the fetch/switch grant) | Always identical to `sa_pick` - grant follows pick in the same cycle. |
| `sa_pick` | `[NUM_VC-1:0]` | output | SA pick logic → input port's datapath mux qualifier | At most one bit set: one datapath per input port, so only one VC may be presented per cycle. |
| `n_va_grants` | 32 (`int unsigned`) | output | `va_cnt` → bench | Running total of VA grants since the last reset; the bench asserts absolute totals against it. |
| `n_sa_grants` | 32 (`int unsigned`) | output | `sa_cnt` → bench | Running total of SA grants since the last reset. |

### 1.3 Registers and state

| Name | Width | Kind | Reset | Working / description |
|---|---|---|---|---|
| `NUM_VC` | int | `parameter` | n/a | See §1.1; also sizes `va_req`, `va_gnt`, `sa_req`, `sa_gnt`, `sa_pick`. |
| `VC_W` | 2 | `localparam int` | n/a | `(NUM_VC > 1) ? $clog2(NUM_VC) : 1` - the width of `rr_sa`, derived in the body because the port list already refers to it. |
| `rr_sa` | `VC_W` (2) | register | `0` on `!rst_n` | Stage-1 pointer across this port's VCs. The SA scan starts *at* it and wraps forward over every VC (§2.2); with two VCs that walk is bit-for-bit the old `~rr_sa` move. |
| `va_cnt` | 32 (`int unsigned`) | register | `0` on `!rst_n` | VA grant counter, exported as `n_va_grants` (§2.4). |
| `sa_cnt` | 32 (`int unsigned`) | register | `0` on `!rst_n` | SA grant counter, exported as `n_sa_grants` (§2.4). |
| `va_gnt`, `sa_gnt`, `sa_pick` | `NUM_VC` each | `wire` (`assign` / `always_comb`) | n/a | Combinational outputs. They hold no state - they are functions of `va_req`, `sa_req` and `rr_sa` - which is the whole point of the mock: no grant is ever registered, so nothing can arrive a cycle later than the spec says. The bench supplies `va_gnt_out_vc` separately (§2.1), so this timing-only mock has no allocation sideband port. |

---

## 2. RTL explanation

### 2.1 VA - accept in the request cycle

```systemverilog
assign va_gnt = va_req;
```

One decision, combinational:

- **Accept everything.** `va_gnt = va_req` means a request is granted in the
  same cycle it is made. That is not laziness: the spec locks this behaviour
  ("the allocator is combinational in the request cycle; the input port latches
  `assignment_valid` at the clock edge"), and the input port's arrival-cycle
  timing - `va_req` in c1, `req_sa` in c2 - depends on it. Making the grant
  registered would shift every cycle number in the port's timeline by one and
  turn a design bug into a bench bug.

The mock does not model downstream matching. The bench drives
`noc_input_port.va_gnt_out_vc` separately: identity mapping for the original
cycle tests, rotated within each traffic class for the dynamic assignment test.
The input port captures that mapping in `out_vc` at the VA-grant edge.

There is no combinational loop risk, and the comment says why: `va_req` is a
function of registers only (`head_valid`, `assignment_valid`, `arrive`, and
`data_out` through `route_compute`), so feeding it straight back combinationally
closes no cycle.

### 2.2 SA - one round-robin pick, granted immediately

```systemverilog
always_comb begin : sa_stage1
  logic [VC_W-1:0] idx;

  sa_pick = '0;

  for (int i = 0; i < NUM_VC; i++) begin
    idx = VC_W'((int'(rr_sa) + i) % NUM_VC);
    // First requester found, wrapping forward from rr_sa.
    if (((|sa_pick) == 1'b0) && sa_req[idx]) sa_pick[idx] = 1'b1;
  end

  sa_gnt = sa_pick;
end
```

The pick searches **at** `rr_sa` first and walks forward, wrapping at
`NUM_VC` - a round-robin over the whole VC set, written as an index loop
rather than a branch pair. For `NUM_VC == 2` that walk is bit-for-bit the old
`sa_req[rr_sa] ? rr_sa : ~rr_sa` form; that older form only ever considered
two VCs (a single `rr_sa` bit and its complement), which would silently ignore
VC2 and VC3 now that the port has four. The result is one-hot by construction -
the `(|sa_pick) == 1'b0` guard takes the first requester found and `sa_pick`
starts at zero - which is the property the input port actually depends on: it
has one datapath to the crossbar, so only one VC's flit can be presented per
cycle.

`sa_gnt = sa_pick` collapses the real arbiter's stage 2. Here that stage has a
single client - one input port - so there is nothing to arbitrate *between*, and
the property that survives the collapse is the one the port cares about: **at
most one VC switched per port per cycle, and `sa_gnt` always implies
`sa_pick`**. A pick without a grant would be harmless at this seam (the crossbar
output is masked by `st_valid`); a grant without a pick would put an unqualified
flit on the wire, so the mock makes the two identical and the port can rely on
it.

### 2.3 State updates

Everything is in one `always_ff @(posedge clk)` with a synchronous `!rst_n`
branch that zeroes `rr_sa`, `va_cnt` and `sa_cnt`. There is no second pointer
any more: the VA side makes no choice (§2.1), so the only rotation left in the
mock is the SA stage-1 pointer.

- **`rr_sa` advances only when `|sa_gnt`** - i.e. only when the picked VC
  actually had a request outstanding (grant always follows pick here, so "was
  granted" and "was picked with a request" are the same event):

  ```systemverilog
  rr_sa <= (rr_sa == VC_W'(NUM_VC - 1)) ? '0 : (rr_sa + VC_W'(1));
  ```

  The guard is what keeps the pointer honest: rotating on a cycle where
  *nothing* was granted would walk it away from the pending VC without having
  switched it. The wrap is the other half - without it a `VC_W`-bit pointer
  would walk off the end of the VC set and the scan in §2.2 would start at an
  index that does not exist. With it, the walk is exactly round-robin over 2, 4
  or 8 entries.

The rotation happens at the edge *after* the combinational grant, so during the
grant cycle the outputs still show the pre-advance value - the pick a test
scores in that cycle is the one that was made there, not the one queued behind
it.

### 2.4 The exported counters

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
over, or dropped - a grant that fired for two cycles where the port expected one
would show up as an inflated total even if every individual cycle looked
plausible, and a dropped grant shows up as a short one. They are exported as
plain `int unsigned` outputs rather than read hierarchically, so the bench sees
them like any other DUT response.

One precision is worth stating: the increments are non-blocking assignments
inside a `for` loop, so if **two** VCs were granted in the same cycle both
iterations would schedule `va_cnt + 1` with the same right-hand side and the
counter would advance by **one**, not two - it counts *cycles with a grant*
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

**Dependent bench:** `tb/tb_noc_input_port.sv` - two instances, `u_relay_mock`
(that file's, beside the directional/relay port `u_relay`) and
`u_local_mock`. Both are wired
with `NUM_VC = 4`.
**Run:** `make TOP=noc_input_port sim` - reports `Checks : 171` / `Errors : 0`
/ `ALL TESTS PASSED` (that bench uses its own `report`/`chk`/`chk4`/`chk_vec`/
`chk_vc`/`chk_bit` family - five width-specific wrappers that widen explicitly
with `FLIT_W'()` casts and funnel into one bookkeeping task - rather than the
single `FLIT_W`-wide `check` that `noc_tb_pkg` exposes).

There is no `make TOP=mock …` and no `tb_mock_arbiter.sv`: the mock's
correctness is established only indirectly, by the expectations the input-port
bench pins against it. The Makefile compiles `tb/mock_arbiter.sv` into *every*
build (any `tb/` file not named `tb_*.sv` is treated as support), `files.f` lists
it for the slang-server/VCS flow, and `tools/assert_neg.sh` adds it to its build
line explicitly - it is never the top module.

### 3.1 How the bench wires it in

The mock's three vector outputs are wired straight back into the DUT with three
whole-signal assignments:

```systemverilog
always_comb begin
  r_va_gnt   = r_m_va_gnt;
  r_sa_gnt   = r_m_sa_gnt;
  r_sa_pick  = r_m_sa_pick;
end
```

The grant vectors identify input FIFOs. A separate packed bench mapping
supplies the DUT's allocated output-VC sideband, also through a whole-signal
endpoint. The mock's
`va_req`/`sa_req` inputs are the port's `req_va`/`req_sa`, so the request →
grant path is a genuine combinational loop *through the DUT's registers*,
exactly as it is in the real router.

### 3.2 What the bench asserts about the mock

- **Combinational VA timing (T9, T2, T8, R1, L1, V1).** Every test's cycle table
  assumes `va_req` in cycle *n* produces `va_gnt` in the same cycle *n* and
  `req_sa` in *n+1*. T9's c1/c2 and T2's c1/c2 are the sharpest expressions of
  it; if the mock registered its grant, those checks fail on the first test.
- **`sa_req_out_vc` equals the requester's own VC (T2, L1).** The check
  `T2 c2 sa_req_out_vc` expects `VC_W'(0)` - the source comment beside it
  still reads *"mock's first pick"*, but in v2 the value is 0 because the
  packet sits on VC0 (§2.1) - and L1 requires `0` on all three of its packets
  (east, south, self), its own comment noting that the reads now land on VC0
  because *"there is no longer anything to remember"*. L1 then closes the
  gap that creates: a constant-zero index would pass all three, so it
  restates the rule over the whole VC range, `sa_req_out_vc[v] == v` for every
  `v < NUM_VC` (four checks inside L1's 36).
- **One pick, one grant (T9, V1).** `V1 c2` requires `sa_gnt[0] == 1` *and*
  `sa_gnt[1] == 0` - one grant per port per cycle - with `sa_pick[0]` high
  beside it, i.e. grant-implies-pick made observable. V1's ordering comment -
  *"the mock's stage-1 pointer alternates, so VC0 switches first and VC1 one
  cycle later"* - is `rr_sa` (§2.3) doing its job across two VCs, not an
  output-VC choice: the VC each packet targets is fixed by its own index.
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

- VA accepts **in the request cycle** - the spec-locked timing the whole port
  timeline rests on.
- The bench's separate sideband supplies the output-VC assignment, including
  nonidentity same-class mappings in the dynamic test.
- **At most one VC picked and granted per port per cycle**, and
  `sa_gnt` always implies `sa_pick`.
- Grants are **immediate and combinational** - nothing is registered between
  request and grant, so grant timing is entirely the bench's to control.
- **Deterministic, cycle-exact behaviour** with no dependence on any other port.
- **Exported totals** (`n_va_grants`, `n_sa_grants`) so "granted twice / granted
  never" is checkable as an arithmetic fact rather than inferred from a single
  observed cycle.

### 3.4 What it deliberately does not model

- **Credits.** There is no `credit_count` and no credit gate: SA grants
  whenever the port asks. The real arbiter masks stage 1 on the credit pool, and
  the exhaustion/recovery behaviour that mask exists for is tested against the
  real thing - `tb_arbiter`'s T7 and `tools/assert_neg.sh`'s
  *"arbiter: stage-1 ignores the credit pool"* case.
- **VA contention and reservation.** No `alloc_busy`, no row/column stages, no
  possibility of a request being *refused*. A port bug that only appears when VA
  says no cannot be seen here; `tb_arbiter`'s T6 covers refusal, column drops and
  pointer discipline against the real allocator.
- **The single-flit tier.** `va_req_single` has no port on the mock - every
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
- **`NUM_VC` outside 2, 4 or 8.** The mock is written for any count - the pick
  computes `(rr_sa + i) % NUM_VC` and the pointer wraps at `VC_W'(NUM_VC - 1)`
  (§2.2, §2.3) - but only the three legal widths get past the port's own
  time-0 parameter check, which `$fatal`s otherwise: the instantiating bench
  declares `parameter int NUM_VC = 4` and passes it to both instances (§3).
  Three VCs or sixteen VCs are never exercised against the mock.

The dividing line is intentional: anything the mock *does* model is a behaviour
the input port's interface fixes (combinational accept and one switched VC
per physical input per cycle), so a mismatch between mock
and port is always a port bug.
Everything the mock omits is behaviour that belongs to the shared allocator and
is covered where that allocator actually exists.
