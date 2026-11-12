# `tb_arbiter` - `tb/tb_arbiter.sv`

Self-checking leaf testbench for dynamic VA, two-stage SA, and credit counters.
The old VC-matched T6 expectation (free same-class rows cannot be used by a
VC0 requester) is superseded. Its reservation and priority coverage is retained
and extended by D1–D6.

## 1. Ports and state

The bench has no external ports. `NUM_VC` (2/4/8) and `FIFO_DEPTH` are bench
parameters passed to the DUT; LOCAL credits remain four.

| Signal | Width | Direction | Source → Destination | Working / description |
|---|---|---|---|---|
| `clk`, `rst_n` | 1 each | input | bench → DUT | Falling-edge stimulus, rising-edge commit, synchronous reset. |
| `va_req`, `va_req_single` | ports × VCs | input | directed tests → VA | Requests and HEAD_TAIL priority. |
| `va_req_out_port` | ports × VCs × 4 | input | tests → VA | Required physical output. |
| `va_gnt` | ports × VCs | output | VA → checks | Input requester grants, possibly multiple per physical input. |
| `va_gnt_out_vc` | ports × VCs × VC_W | output | VA → checks | Actual dynamically assigned downstream VC. |
| `sa_req`, `sa_req_last` | ports × VCs | input | tests → SA | Independent SA stimulus and last-flit levels. |
| `sa_req_out_port`, `sa_req_out_vc` | ports × VCs × 4 / VC_W | input | tests → SA | Assigned resource, independently driven for leaf tests. |
| `sa_pick`, `sa_gnt` | ports × VCs | output | SA → checks | Stage-1 selection and final traversal. |
| `xbar_sel`, `st_valid`, `st_out_vc` | ports × 3 / 1 / VC_W | output | SA → checks | Physical switch selection and allocated VC sideband. |
| `ds_credit_valid` | ports × VCs | input | tests → counters | Downstream returns indexed by actual VC. |

| Name | Width | Kind | Reset | Working / description |
|---|---|---|---|---|
| `accepted` | ports × VCs | task variable | n/a | Removes requests accepted at the preceding VA edge. |
| `gnt_to_out` | ports × ports × VCs | combinational | n/a | Per-output SA uniqueness assertion view. |
| `checks`, `errors` | integer | shared package counters | 0 | Every check contributes to the final report. |
| DUT `alloc_busy`, `credit_count` | per output VC | observed RTL state | RTL reset | Read directly by this leaf bench for exact accounting checks. |

## 2. RTL explanation

`next_cycle()` advances to the falling edge after a state commit;
`settle()` allows two ns for combinational results. `reset_arb()` separates
independent scenarios so SA round-robin expectations retain known reset state.
`gmask(p,v)` encodes the input requester's grant bit without hard-coded widths.

The test drives SA independently of VA when testing SA/credits in isolation,
as the original bench did. Integrated packet ownership is checked with the
real input ports in `tb_router_top` and `tb_router_chain`.

Continuous assertions check that SA grants answer requests, one input sends
at most one VC, and one output receives at most one input. RTL assertions add
VA matching/class/reservation and exact credit-transition invariants.

## 3. Testing explanation

| Scenario | Checks |
|---|---|
| R0 | Credit initialization, no grants or reservations after reset. |
| D1 | Two ports at input VC0, HEAD_TAIL first, concurrent response class; two same-class grants when NUM_VC > 2. |
| D2 | Oversubscribed matching, sibling VCs on each input, priority, full-class backpressure, untouched response resources. |
| D3 | Exactly one free row; one grant per requester; HEAD/BODY retain reservation; TAIL selected at stage 1 but denied stage 2; successful release and next-cycle reuse. |
| D4 | Zero-credit ownership stall on assigned VC; stalled TAIL retains reservation; return unblocks; mapped sideband; simultaneous return/transmit. |
| D5 | VA succeeds on a zero-credit resource; HEAD_TAIL stalls until return, then releases on traversal. |
| D6 | Equal-tier round-robin advances past the previous owner when a row becomes free. |
| T4 | Two VCs on one physical input, distinct/same outputs, stage-1 rotation and one-input bandwidth. |
| T5 | Two physical inputs to one output, exact stage-2 fair sequence with both SA stages active. |
| T7 | Credit exhaustion, no zero-credit grant, recovery, simultaneous increment/decrement, repeated exhaustion. |

Run `make TOP=arbiter sim`; parameter sweeps use `GFLAGS='-GNUM_VC=2'`, `8`,
and `-GFIFO_DEPTH=8`. The new architecture's [validation record](../dynamic_va_validation.md)
lists executed results. Older numerical results and mutation results do not
apply automatically to the modified allocator.
