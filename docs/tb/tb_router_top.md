# `tb_router_top` - `tb/tb_router_top.sv`

The T5 SA-contention test now injects both competing packets at input VC0
when NUM_VC=4/8. They must acquire distinct request-class output VCs to contend
at SA. NUM_VC=2 retains separate classes because each class has only one VC.
The existing packet-order, backpressure, route, and credit tests remain.
The router's seam assertions independently check live output ownership,
stored allocation mapping, and transmitted sidebands.

Executed results for this change: [validation](../dynamic_va_validation.md).

Router-level verification bench: one assembled `router_top`, placed at mesh
coordinate (1,1) with all five links present, driven by the three models a
stand-alone router is missing - an upstream TX driver that obeys the router's
own credits, a downstream credit-return pipe, and a receiver that logs every
flit that leaves. Ten directed tests (T1..T9 plus one edge-of-mesh case) make
104 checks against hand-derived expected values, and every SVA family in the
router and its children runs underneath them because the build passes
`--assert`.

---

## 1. Ports and state

### 1.1 The device under test

The bench top (`module tb_router_top`) has no ports of its own. It declares
exactly one DUT instance, `dut`, in the corresponding source block:

```systemverilog
router_top #(
    .NUM_PORTS(NUM_PORTS), .NUM_VC(NUM_VC), .LOCAL_IDX(LOCAL_IDX),
    .FIFO_DEPTH(FIFO_DEPTH), .LOCAL_CREDITS(LOCAL_CRED),
    .CUR_X(CUR_X), .CUR_Y(CUR_Y),
    .HAS_LOCAL(1'b1), .HAS_NORTH(1'b1), .HAS_EAST(1'b1),
    .HAS_WEST(1'b1), .HAS_SOUTH(1'b1)
) dut ( ... );
```

With `CUR_X = 1`, `CUR_Y = 1` the mesh around it is

```
       (1,0) NORTH
(0,1) WEST   LOCAL(1,1)   EAST(2,1)
       (1,2) SOUTH
```

so a LOCAL-injected flit is routed by `compute_dir` against real coordinates,
while a flit arriving on a directional port carries its exit direction in the
header's ROUTE field - the lookahead the upstream router wrote. All five
`HAS_*` parameters are `1'b1`, i.e. this is an **interior** router; the
absent-port tie-off of spec 4.6 is therefore inert here (§3.11).

Every port connection is a plain scalar or a whole packed array, never an
element select - the existing whole-signal connection convention,
because an element-select endpoint freezes at its initial value.

### 1.2 Port table (the `dut` interface)

The Direction column is from the **DUT's point of view**: `input` = the bench
drives it, `output` = the DUT drives it. The scope is the single `dut`
instance above; every signal wired into or out of it appears exactly once.

| Signal | Width | Direction | Source → Destination | Working / description |
|---|---|---|---|---|
| `clk` | 1 | input | bench clock generator → `dut`, RX logger, credit pipe, TX driver | Free-running 100 MHz timebase (`CLK_PERIOD = 10ns`). Every DUT register and every bench sampler moves on `posedge clk`; the stimulus driver moves on `negedge clk`. |
| `rst_n` | 1 | input | `reset_dut()` → `dut` (and tested by the logger, the TX driver and the credit pipe) | Active-low synchronous reset, held for 5 posedges and released on a negedge. While low, the logger stops recording, the driver holds all `in_flit_valid` low and zeroes `inflight`, and the credit pipe/`held_credits` clear. |
| `in_flit_data` | `[NUM_PORTS-1:0][FLIT_W-1:0]` (5×40) | input | `tx_driver` → DUT input ports | The five incoming links. Index `p` is the link *into* the router from that side (index 0 is the network interface). Loaded by the driver from the oldest `tx_q` entry owed to port `p`, held for exactly one cycle. |
| `in_flit_valid` | `[NUM_PORTS-1:0]` (5) | input | `tx_driver` → DUT input ports | One valid bit per incoming link, asserted for a single cycle per flit, back to back when `tx_q` has more and the credit model allows. Held at 0 during reset. |
| `in_vc_id` | `[NUM_PORTS-1:0][VC_W-1:0]` (5×VC_W) | input | `tx_driver` → DUT input ports | Sideband VC selector riding with `in_flit_data` - the thing that actually picks the receiving FIFO, so it is authoritative on every flit, not just headers. The header's own KIND field is payload as far as routers are concerned (assumption D3). Range-checked by the driver before it indexes `inflight`. |
| `out_flit_data` | `[NUM_PORTS-1:0][FLIT_W-1:0]` (5×40) | output | DUT output ports → RX logger, T8 direct samples | The five outgoing links, registered by `noc_output_port`. Read by the logger at every posedge; T8 also samples `out_flit_data[WEST_IDX]` directly to check type and tag on consecutive cycles. |
| `out_flit_valid` | `[NUM_PORTS-1:0]` (5) | output | DUT output ports → RX logger, credit pipe, T8/T9 | "A flit is on this link during this cycle." Drives the RX log, seeds the credit pipe, and is the signal T8 walks cycle-by-cycle and T9 times against `in_flit_valid`. |
| `out_vc_id` | `[NUM_PORTS-1:0][VC_W-1:0]` (5×VC_W) | output | DUT output ports → RX logger, credit pipe | Downstream VC of the flit on `out_flit_data[o]`. The logger stores it per entry; the credit pipe decodes it to select the VC row it credits. |
| `credit_return_valid` | `[NUM_PORTS-1:0][NUM_VC-1:0]` (5×NUM_VC) | output | DUT input ports → `tx_driver`'s `inflight` model | The DUT telling the bench that a FIFO slot in *its* input port `p`, VC `k` was freed by a fetch. The bench decrements `inflight[p][k]` on it - this is the router flow-controlling its own upstream neighbour. |
| `ds_credit_valid` | `[NUM_PORTS-1:0][NUM_VC-1:0]` (5×NUM_VC) | input | bench `credit_gate` → DUT arbiter | The downstream consumer handing a credit back for each outgoing link: `ds_credit_valid[o][k]` is a free slot in the neighbour's input port `o`, VC `k`. Produced by the credit-return pipe (§2.4) and gated by `credit_en`. |

### 1.3 Registers and state

The bench declares exactly two `parameter`s - `NUM_VC` and `FIFO_DEPTH`, the
two knobs `make regress` overrides - and imports the flit vocabulary it used
to declare for itself (widths, type encodings, the reporter's counters) from
`noc_tb_pkg`; everything else relied on is a `localparam`, a queue, an array
or a plain variable. Task-local temporaries
inside the tests (`n0`, `n1`, `lat`, `w_pos`, `n_east`, …) are deliberately
not listed - they live and die with one call.

| Name | Width | Kind | Reset | Working / description |
|---|---|---|---|---|
| `NUM_PORTS` | 32 | localparam | - | `5`. Port count fixed by the 5×5 crossbar; passed to the DUT and used to size every port-indexed declaration in the bench. |
| `NUM_VC` | 32 | parameter | - | `4`. VCs per port, passed to the DUT; sizes `inflight`, `held_credits` and `cr_pipe`. A `make regress` knob: `-GNUM_VC` with 2, 4 or 8. |
| `VC_W` | 32 | localparam | - | `(NUM_VC > 1) ? $clog2(NUM_VC) : 1`, i.e. `2` at the default. Width of every VC sideband and of the `VC_W'(k)` casts that compare one against a row index. |
| `LOCAL_IDX` | 32 | localparam | - | `0`. Index of the LOCAL (network interface) port; also passed as the DUT's `LOCAL_IDX`. |
| `NORTH_IDX` | 32 | localparam | - | `1`. Index of the link coming in from / going out to the north neighbour. |
| `EAST_IDX` | 32 | localparam | - | `2`. Used as an expected value throughout T1, T7, T9, E1. |
| `WEST_IDX` | 32 | localparam | - | `3`. The output T2, T3 and T8 watch. |
| `SOUTH_IDX` | 32 | localparam | - | `4`. The exit port T1c expects. |
| `FIFO_DEPTH` | 32 | parameter | - | `4`. Passed to the DUT (and from there to the arbiter's `DIR_CREDITS`). Doubles as the bench's own per-(port, VC) `inflight` cap and, in T7, as the credit-pool width the test exhausts. A `make regress` knob: `-GFIFO_DEPTH` with 4 or 8. |
| `LOCAL_CRED` | 32 | localparam | - | `4`, passed as `LOCAL_CREDITS`: the NI receive-buffer depth per VC that seeds `credit_count[LOCAL][*]`. |
| `CLK_PERIOD` | 64 (real) | localparam (`realtime`) | - | `10ns`. Halved by the clock generator, giving a 5ns half period. |
| `CRED_LAT` | 32 | localparam | - | `2`. Downstream credit-return latency in cycles, per spec section 6. Sizes `cr_pipe` to `CRED_LAT+1` stages. |
| `CUR_X` | 3 | localparam (`logic [2:0]`) | - | `3'd1`. This router's X coordinate, given to `route_compute` inside every input port. |
| `CUR_Y` | 3 | localparam (`logic [2:0]`) | - | `3'd1`. Y coordinate; together with `CUR_X` fixes the mesh neighbourhood in §1.1. |
| `FLIT_W` | 32 | localparam (imported) | - | `40`. Flit width, owned by `noc_tb_pkg` and deliberately *not* redeclared here (a second copy would hide the package's and the two could drift apart). Every port array and both record payloads are this wide. |
| `TAG_W` | 32 | localparam (imported) | - | `26` (`FLIT_W - 14`). The tag region the constructors plant and `rx_tag` reads back; the tests write 18-bit tags into it. |
| `FLIT_BODY` | 2 | localparam (imported) | - | `2'b00`. Flit type code, spec section 2; also asserted against the RTL's own constants by `noc_input_port`. |
| `FLIT_HEAD` | 2 | localparam (imported) | - | `2'b01`. Type of a multi-flit packet's first flit. |
| `FLIT_TAIL` | 2 | localparam (imported) | - | `2'b10`. Type of a multi-flit packet's last flit. |
| `FLIT_HEAD_TAIL` | 2 | localparam (imported) | - | `2'b11`. Single-flit packet; the only type that both opens and closes a packet. |
| `DIR_LOCAL` | 4 | localparam (`logic [3:0]`) | - | `4'b0000`. One-hot direction codes, spec section 2. Expected value of the merged route field in T1a/T1c. |
| `DIR_NORTH` | 4 | localparam | - | `4'b0001`. |
| `DIR_EAST` | 4 | localparam | - | `4'b0010`. Also the accidental payload value baked into `mk_body`. |
| `DIR_WEST` | 4 | localparam | - | `4'b0100`. Also the accidental payload value baked into `mk_tail`. |
| `DIR_SOUTH` | 4 | localparam | - | `4'b1000`. Expected outgoing route in T2. |
| `clk` | 1 | variable | starts `0` | `initial clk = 0; always #(CLK_PERIOD/2) clk = ~clk;` - the only clock source; no gate, no reset. |
| `rst_n` | 1 | variable | `X` → 0 by `reset_dut()` | Driven low for 5 posedges, released on a negedge, then one more negedge before stimulus begins. |
| `checks` | 32 | counter (imported) | `0` | Declared in `noc_tb_pkg`, so every bench reports from the same number. Incremented once by every `check`/`check_true` call; the denominator of the final result line. |
| `errors` | 32 | counter (imported) | `0` | Declared in `noc_tb_pkg`. Incremented on every mismatch; its value at `$finish` selects between the pass and fail summary lines. |
| `rx[$]` | variable (queue of `rx_t`) | queue | starts empty; `clear_rx()` between sub-cases | The receiver log: one entry per flit the router emitted, in arrival order, each `{port, vc, data}`. All expectations are read back out of this queue. |
| `tx_q[$]` | variable (queue of `tx_t`) | queue | starts empty | The stimulus queue: one shared queue of `{port, vc, data}` pushed by `send()` and consumed by the negedge driver. Deliberately *not* an array of per-port queues (an array of queues indexed by a variable corrupts silently in this simulator). |
| `inflight[NUM_PORTS][NUM_VC]` | 32 each | array (counter) | `0` at declaration, `0` on `rst_n` | The upstream flow-control model: flits the bench has put on link `p` that the router has not credited back. Incremented on drive, decremented on `credit_return_valid`, capped at `FIFO_DEPTH`. |
| `held_credits[NUM_PORTS][NUM_VC]` | 32 each | array (counter) | `0` on `rst_n` | Credits the neighbour owes while the return loop is shut (`credit_en = 0`). Collected instead of discarded, then paid back one per cycle when the loop reopens. |
| `cr_pipe[CRED_LAT:0][NUM_PORTS-1:0][NUM_VC-1:0]` | 60 at the default (3×5×NUM_VC) | array (shift register) | `0` on `rst_n` | The downstream credit-return pipe: stage 0 is loaded from `out_flit_valid`/`out_vc_id` each posedge, stages shift every cycle, stage `CRED_LAT` is the credited event. |
| `credit_en` | 1 | variable (switch) | `1'b1` | Opens/closes the downstream credit-return loop. Set to `0` and back to `1` only by T7. |
| `drv_vc` | 32 | variable | - | Driver temporaries, persistent across negedges by declaration but re-assigned each pass: the VC and queue index chosen for the port currently being driven. |
| `drv_idx` | 32 | variable | - | Index in `tx_q` of the oldest entry owed to the port under drive; `-1` means nothing to send. |
| `rx_t` | 3 fields (`int port`, `int vc`, `logic [FLIT_W-1:0] data`) | typedef | - | Element type of `rx`. Built field by field by the logger because this toolchain rejects `'{...}` as an argument. |
| `tx_t` | 3 fields (`int port`, `logic [VC_W-1:0] vc`, `logic [FLIT_W-1:0] data`) | typedef | - | Element type of `tx_q`; carries the destination port alongside the flit so one shared queue can serve five links. |

---

## 2. RTL explanation

*(For a bench this section is "how the bench works", not what the DUT does.)*

### 2.1 Clock and reset

The clock is the universal idiom - `initial clk = 0;` plus a half-period
toggle - so every cycle is 10ns and the *posedge closes a cycle*. Reset is a
task, not a generator:

```systemverilog
task automatic reset_dut();
  rst_n = 1'b0;
  repeat (5) @(posedge clk);
  @(negedge clk);
  rst_n = 1'b1;
  @(negedge clk);
  clear_rx();
endtask
```

Releasing on a negedge matters: the DUT's registers then see a `rst_n` that
has been stable for half a cycle when the first live posedge arrives, and the
negedge `tx_driver` - which also tests `rst_n` - cannot sample a mid-transition
value. `clear_rx()` at the end guarantees each test starts from an empty log
even if reset itself produced output. During reset the three bench models
behave differently on purpose: the logger is gated by `if (rst_n)` so nothing
is recorded, the TX driver zeroes `inflight` and every `in_flit_valid`, and
the credit pipe clears `cr_pipe` and `held_credits`.

### 2.2 The cycle convention: drive at negedge, sample at posedge

Everything the bench *puts on a wire* is written at `negedge clk`; everything
the DUT (and the RX logger) *decides on* happens at `posedge clk`. The TX
driver therefore presents `in_flit_data/in_flit_valid/in_vc_id` half a cycle
before the edge that consumes them, using plain blocking assignments - which
is safe precisely because no other process reads those signals at the
negedge, so there is no race to lose.

Sampling follows the same split, and the tests are explicit about which edge
they use:

- The **RX logger** samples at `posedge clk`, so an entry means "the value
  this wire carried during the cycle that just ended". That is why T8 waits
  one extra negedge before counting: the third flit is only in the log after
  the posedge following the negedge on which it was observed on the wire.
- Most **waits** (`drain`, T8's poll of `out_flit_valid[WEST_IDX]`) sample at
  `negedge clk`, half a cycle after the posedge that produced the value, when
  the signal is settled and will not change again before the logger reads it.
- **T9 samples both ends at posedge** and says why: it is the same edge the
  logger uses, so both readings are "the value this cycle carried". Watching
  negedges instead would make the answer depend on whether the T9 process or
  the driver gets to run first at the negedge where the flit is presented -
  and that single cycle of slack *is* the quantity being measured (3 cycles).
- The **TX driver reads `credit_return_valid` at the negedge**, before it
  decides whether to drive: a credit returned during this cycle frees a slot
  writable at the posedge ending this same cycle, so reading it there keeps
  `inflight` exact rather than one cycle conservative.

### 2.3 Stimulus: `send`, `tx_q` and the upstream flow-control model

Tests never touch the DUT ports directly; they call

```systemverilog
send(port, data, vc);
```

which range-checks the port (a bad index becomes a reported failure, not a
silently mis-indexed queue) and pushes a `tx_t` onto the single shared
`tx_q`. A linear scan in the driver then finds the **oldest** entry for each
port, which is both the "oldest packet first" order a real link needs and a
way of keeping every queue index a plain variable read.

The `always @(negedge clk) tx_driver` block is the upstream neighbour:

1. if `!rst_n`, hold all `in_flit_valid` low and zero `inflight`;
2. otherwise first settle the credit account - for every `(p,k)`,
   `credit_return_valid[p][k] && inflight[p][k] > 0` decrements `inflight[p][k]`;
3. clear `in_flit_valid[p]`, scan for the oldest entry owed to `p`, and drive
   it **only if `inflight[p][drv_vc] < FIFO_DEPTH`**, then increment
   `inflight` and `tx_q.delete(drv_idx)`.

The cap is the whole point of the model, as the file header argues: a bench
that ignored credits would push more than `FIFO_DEPTH` flits into a VC the
router cannot store, and every resulting overflow would look like a design
failure that never happened. `drv_vc` is range-checked against `NUM_VC`
before it indexes `inflight` - the sideband is `VC_W` bits wide, and the
explicit test keeps a malformed selector from selecting past the end of
`inflight`.

### 2.4 The downstream credit-return model

The other half of the loop is a pipe, not a combinational wire. Spec section
6 defines the round trip as: grant at `g`, flit on the wire at `g+1`,
downstream fetch at `g+1`, credit visible at `g+2`, usable at `g+3` - and
`CRED_LAT = 2` reproduces exactly that.

```systemverilog
logic [CRED_LAT:0][NUM_PORTS-1:0][NUM_VC-1:0] cr_pipe;
```

At each posedge, stage 0 is loaded with a 1 for every `(o,k)` where
`out_flit_valid[o] && (out_vc_id[o] == VC_W'(k))` - the sideband is compared
explicitly rather than used as an index, because the row index is
`clog2(NUM_VC)` wide and an out-of-range value would select past the end.
The pipeline then shifts, and
`cr_pipe[CRED_LAT]` is the credit-producing event.

`credit_en` closes or opens the loop, and the two states are asymmetric:

- **closed** (`credit_en = 0`): credits emerging from the pipe are *collected*
  into `held_credits[o][k]`, one per event;
- **open**: the backlog is paid down at one credit per cycle - a cycle that
  already carries a fresh credit spends that one instead, so the backlog
  simply follows behind.

Discarding held credits instead of queueing them would leave the router's
pool short for ever: the neighbour really did consume the flit, so the flits
still parked upstream would never be re-granted after recovery. The DUT-facing
signal is assembled in one `always_comb` gate:

```systemverilog
ds_credit_valid[o][k] = credit_en & (cr_pipe[CRED_LAT][o][k] | (held_credits[o][k] != 0));
```

so `credit_en` delays credits but never cancels one. This is the only dynamic
reference model in the bench, and T7 is built entirely on it.

### 2.5 The receiver: how the DUT's response is observed

```systemverilog
always @(posedge clk) begin : rx_logger
  if (rst_n)
    for (int o = 0; o < NUM_PORTS; o++)
      if (out_flit_valid[o]) begin e.port = o; e.vc = int'(out_vc_id[o]);
                                   e.data = out_flit_data[o]; rx.push_back(e); end
end
```

Everything that leaves the router - port, downstream VC, the whole `FLIT_W`-bit
flit -
is appended to `rx`, so tests assert on counts, order, port assignment and
payload identity rather than on individual signal samples. Six accessors
project an entry back into the field a test cares about, each one a thin
wrapper over the reader of the same name in `noc_tb_pkg`:

| Accessor | Yields | Used for |
|---|---|---|
| `rx_n()` | number of flits logged | count assertions in every test |
| `rx_tag(i)` | `flit_tag(data)` | packet identity (the tag field the constructors plant) |
| `rx_type(i)` | `flit_type(data)` | HEAD / BODY / TAIL / HEAD_TAIL sequence checks |
| `rx_origin(i)` | `flit_burst(data)` | which input port sent it - the BURST slot, i.e. the top two bits of the 18-bit tag the tests plant, and the only way to observe fairness from outside (T5) |
| `rx_port(i)` | the logged output port | exit-port assertions |
| `rx_route(i)` | `flit_route(data)` | the merged lookahead, i.e. what a *downstream* router would read - the only external view of the output-port header merge |

A router never consumes its own outgoing route field, so `rx_route` is how
the bench sees the splice that `noc_output_port` performs.

### 2.6 Flit formats, and what the "expected values" are

There is no golden reference model in this bench - no cycle-accurate copy of
the router predicting `rx`. The expected values are **hand-derived constants**,
recomputed from the spec: flit counts, exit ports, type sequences, tags, the
merged route field (`DIR_LOCAL`, `DIR_SOUTH`), the credit-pool bound
(`FIFO_DEPTH`) and the hop latency (3). The four constructors encode spec
section 2's format - and they now live in `noc_tb_pkg`, one copy for every
bench, in the only file allowed to know bit positions:

```
[1:0] TYPE | [3:2] KIND | [6:4] DEST_X | [9:7] DEST_Y | [13:10] ROUTE | [FLIT_W-1:14] tag
```

`mk_head` and `mk_ht` fill all of it; `mk_body(tag)` and `mk_tail(tag)` fill
only the type and then `{tag, 12'h201}` / `{tag, 12'h401}` across the payload
(`[FLIT_W-1:2]`).
That filler is deliberately non-zero in the route slot - `DIR_EAST` for the
BODY, `DIR_WEST` for the TAIL - because that is exactly the field
the output port
merges into a header. The lookahead for those payload bits is never the value
they already carry, so a merge applied to a non-head changes them and the
bit-for-bit comparisons in T2 fail; a run of zeros would make the same bug
invisible. The tag identifies a packet, and because the tests plant 18-bit
tags the top two of *those* bits land in the BURST slot that `rx_origin`
reads - a field no router ever looks at, which is what makes it free to
borrow for attribution.

### 2.7 Wait helpers and the watchdog

`drain(max_cycles)` blocks at negedges until `tx_q` is empty, then runs 20
more cycles so the router can push whatever is still in its FIFOs onto a link,
and finishes with

```systemverilog
check_true($sformatf("drain completed within %0d cycles", max_cycles), left == 0);
```

so a stalled link becomes a reported failure instead of a hung simulation -
and, incidentally, each `drain` contributes one check to its test's budget.
`settle()` (10 idle negedges) exists for tests that only want a settled
result, but no test in this bench calls it.

### 2.8 Pass/fail: `check` and `check_true`

Both tasks live in `noc_tb_pkg` - the bench's section 6 banner is all that
remains of its local copies, so that every bench reports in one format - both
are `automatic`, both increment `checks` unconditionally, and both
print one aligned line:

```systemverilog
task automatic check(input string what, input logic [FLIT_W-1:0] actual,
                     input logic [FLIT_W-1:0] expected);
  checks++;
  if (actual !== expected) begin
    errors++;
    $display("[FAIL] %-62s got %h exp %h", what, actual, expected);
  end else begin
    $display("[PASS] %-62s %h", what, actual);
  end
endtask

task automatic check_true(input string what, input bit cond);
  checks++;
  if (cond) $display("[PASS] %-62s", what);
  else begin
    $display("[FAIL] %-62s", what);
    errors++;
  end
endtask
```

`check` compares full-flit values with `!==` (4-state, so an `X` never passes
by luck) after every actual and expected - however narrow - has been zero-
extended into `logic [FLIT_W-1:0]`, which is why the build waives `-Wno-WIDTHEXPAND`.
`check_true` is the same accounting for a boolean with no printable value.
Neither aborts: the run always continues to the end, and `main` prints the
result line from the two counters:

```systemverilog
if (errors == 0) $display("ALL %0d CHECKS PASSED", checks);
else             $display("%0d/%0d CHECKS FAILED", errors, checks);
```

One consequence worth knowing when reading a failing log: most per-flit checks
sit inside guards like `if (rx_n() >= 5)`, so when a count assertion fails the
dependent checks are skipped and the run reports *fewer* than 104 checks as
well as a non-zero error count.

---

## 3. Testing explanation

### 3.1 Running it, and the check budget

```bash
make TOP=router_top sim
```

builds `rtl/*.sv`, `tb/noc_tb_pkg.sv` (first - a package has to exist before
anything can import it) and `tb/tb_router_top.sv` with Verilator
(`--binary --timing --trace --assert ... --top-module tb_router_top`) and runs
the result. The observed closing line is

```
ALL 104 CHECKS PASSED
```

`--assert` is mandatory: without it Verilator parses `assert property` and
silently drops it, so the SVA described in §3.12 would not run at all. To get a
waveform, run the binary as `./obj_dir/v_router_top/run +vcd` (the bench
dumps `sim/router_top.vcd` when it sees the `vcd` plusarg) and then
`make TOP=router_top wave`.

The 104 checks break down by test; the `drain` helper's own check is counted
in the test that called it:

| Test | Task | Checks | Property it targets |
|---|---|---|---|
| T1 | `t1_single_head_tail` | 17 | both paths through `route_compute` + the header merge |
| T2 | `t2_three_flit_packet` | 11 | the section 3 reference timeline: order, route, merge selectivity |
| T3 | `t3_back_to_back_packets` | 12 | output-VC reuse across a packet boundary (seam 8) |
| T4 | `t4_two_vcs_one_port` | 5 | one VC picked per cycle; streams never cross |
| T5 | `t5_two_inputs_one_output` | 17 | stage-2 round-robin fairness under sustained contention |
| T6 | `t6_va_contention` | 8 | VA tier bit with 3 requesters contending for one row |
| T7 | `t7_credit_exhaustion` | 14 | credit exhaustion, block, recovery, same-cycle +1/−1 |
| T8 | `t8_fetch_grant_collision` | 9 | fetch must win over grant: no bubble in a packet |
| T9 | `t9_empty_fifo_bypass` | 7 | empty-FIFO bypass: exactly 3-cycle hop latency |
| E1 | `t_edge_ports` | 4 | in-range destinations never need an absent direction |
| **total** | | **104** | |

### 3.2 T1 - a single HEAD_TAIL, three turns (17 checks)

The simplest complete packet, sent three ways so that **both mutually
exclusive paths through `route_compute`** are exercised: (a) LOCAL → EAST,
where `IS_LOCAL_PORT` forces the direction to be computed from the destination
coordinates (dest (2,1) is east of (1,1)); (b) EAST → WEST, where the flit
arrived on a directional port and the direction comes out of the header's
ROUTE field as an upstream lookahead; (c) NORTH → SOUTH, a straight
pass-through so the exit is the port opposite the input. Each sub-case asserts
flit count 1, exit port, type `FLIT_HEAD_TAIL` and payload survival by tag;
(a) and (c) additionally assert `rx_route(0) == DIR_LOCAL`, because the
outgoing header must carry the **next** hop's route - for a destination one
link away, the neighbour's own decision is LOCAL. Nothing inside a single
router ever reads the route field it just wrote, so this is the only outside
observation of the output-port merge.

### 3.3 T2 - the section 3 three-flit packet (11 checks)

H, B, T sent back to back on EAST/VC0 for the WEST output, with the
destination deliberately one hop **beyond** the exit port ((0,2), not (0,1))
so the merged route must read `DIR_SOUTH` - and so a merge applied to every
flit would rewrite the BODY and TAIL with something other than the value they
already carry. Asserts: output appears within 60 cycles; exactly 3 flits; the
type sequence HEAD, BODY, TAIL; all three exit WEST; the outgoing route is
`DIR_SOUTH`; and `rx[1].data` / `rx[2].data` are **bit-for-bit identical** to
`mk_body`/`mk_tail`. That last pair is what catches a merge that lost its
`is_head` gate - a count or a type check would pass while the payload was
being silently corrupted. The other two promises of the section 3 timeline
(3-cycle hop latency, grants on consecutive cycles) are measured properly by
T9 and T8 rather than inferred here.

### 3.4 T3 - two packets back to back in the same VC (12 checks)

A 3-flit packet immediately followed by a 2-flit packet on the same input VC
and the same output. The second HEAD must be accepted into a VC whose
`assignment_valid` only cleared at the previous TAIL's grant - release one
cycle late and the packet stalls; one cycle early and it is routed while the
first is still in flight. Asserts 5 flits in order (packet 2's HEAD sits at
index 3, its TAIL at 4), types on the right slots, and all five exit WEST.
This is output-VC reuse, seam 8.

### 3.5 T4 - two VCs on one input port, different outputs (5 checks)

VC0 heads EAST, VC1 heads NORTH, both from the WEST input. An input port has a
single flit-wide datapath, so stage 1 must pick **at most one VC per cycle** even
though both have a right to go. Asserts 6 flits total, exactly 3 via EAST and
3 via NORTH, and then a per-tag stream check: each packet must appear as
exactly HEAD, BODY, TAIL in order on a **single** downstream VC. Stage 1 is
allowed to interleave the streams, so neither property can be read off arrival
order - a crossed payload shows up as the wrong type, and a mid-packet VC
change (how head-of-line blocking turns into reordering) fails the `vc_a`
comparison. The downstream VC is deliberately *not* required to equal the
input VC: the two streams leave through different output ports, each of which
allocates VC rows from its own free list.

### 3.6 T5 - two inputs competing for one output (17 checks)

NORTH and EAST each send one **six-flit** packet to LOCAL, started in the same
cycle. The length is the point: single-flit packets pace themselves, the two
sides drift into opposite phases, stage 2 never sees two requesters at once,
and an arbiter that simply latched the lowest requesting port would look
perfectly fair. Inside a packet fetch and grant share a cycle (spec section 9),
so `sa_req` stays asserted on every cycle of the packet - both ports then ask
on the same cycles, over and over, and only the round-robin pointer can keep
them interleaved.

The two sides are also deliberately on **different input VCs** - NORTH on VC0,
EAST on VC1 - because the allocator is VC-matched (linnea_v2 section 4.4):
input VC *v* can only ever be reserved as output VC *v*, so a second packet
arriving on VC0 while VC0's row is held would simply wait for the first to
finish, one stream after the other, and stage 2 would never see two requesters
at once. Putting the second on VC1 is what lets both be allocated in the same
cycle and genuinely contend from here down. (Before section 4.4 the separable
VA did that remapping for us, which is why this used to read VC0.) Asserts 12 flits, 6 from each origin (read out of the tag's
top two bits via `rx_origin`), **at least 2 of each inside the first 6
arrivals** (a fixed-priority stage 2 would hand all six leading flits to one
side), and all 12 exit LOCAL.

### 3.7 T6 - VA contention: three requesters, one row (8 checks)

NORTH and EAST each offer a multi-flit HEAD+TAIL, WEST offers a single-flit
HEAD_TAIL: all three arrive on input VC0 and all three want LOCAL, so under the
VC-matched allocator they all name the **same** row - (LOCAL, VC0) - and two of
the three must lose it. Spec section 4.3 says the
single-flit request wins the tier in every row, and the row pointers start at
0 - without the tier, row 0 would go to NORTH (lowest port index at or after
0). Asserts 5 flits total; WEST's flit was served **and** left in the first
two out (`w_pos` ∈ {0,1}), which is a direct observation of the tier bit;
WEST's flit exits LOCAL; and all three requesters are eventually served
(2 NORTH, 2 EAST, 1 WEST) - the last group stops a tier that starved its
losers entirely from passing the first two.

### 3.8 T7 - credit exhaustion, recovery, same-cycle ±1 (14 checks)

The heaviest test. It closes the return loop (`credit_en = 0`), pushes
`FIFO_DEPTH + 4 = 8` single-flit packets from LOCAL toward EAST, and lets the
router run. Asserts:

- exactly `FIFO_DEPTH` (4) flits left - the router must stop granting rather
  than overrun the neighbour whose credit pool is `FIFO_DEPTH` wide;
- 40 further cycles with **no** escape - the block must be a block, not a
  slowdown, or a merely slow router would pass the count above by luck of when
  we looked;
- after reopening the loop, all 8 leave, with tag `18'h7_0000` first and
  `18'h7_0007` last (order preserved), and every flit exits EAST.

Reopening is also where the same-cycle increment and decrement meet: a credit
arriving in the cycle a flit leaves must net to zero, not to −1 or +2. This is
the test that exercises the arbiter's credit-bound assertions (§3.12) and the
`held_credits` pay-down in §2.4.

### 3.9 T8 - fetch and grant in the same cycle (9 checks)

Spec section 9 says `fetch` must **win** the collision with `sa_gnt`: the grant
retires `head_valid` for the flit on `data_out` while the fetch pulls the next
one out of the FIFO. Under the old ordering the grant overwrote the fetch,
`head_valid` dropped, and the packet advanced one flit every three cycles. The
observable is therefore a **bubble**, so the test watches the output cycle by
cycle instead of counting: queue the whole packet at once so the driver puts
it on the link back to back, wait (at negedges) for `out_flit_valid[WEST]`,
then sample the next two cycles and assert a valid, correctly-typed BODY with
the same tag and then a valid TAIL - an idle cycle anywhere in there is the
bug. It finally asserts exactly 3 flits in the log (no duplicate from a double
fetch) and that the head appeared within 80 cycles.

### 3.10 T9 - empty-FIFO bypass, the only latency measurement (7 checks)

A flit landing on an empty VC goes through the FIFO's write bypass onto
`data_out` on the very next cycle rather than being written to RAM and read
back; getting that wrong costs one cycle of per-hop latency and is invisible
to every count-based test. The test samples **both ends at the posedge** (the
logger's edge, §2.2): the cycle `in_flit_valid[LOCAL_IDX]` carries the flit
and the cycle `out_flit_valid[EAST_IDX]` carries it, and asserts
`c_out - c_in == 3` - c0 fetch/bypass, c1 `data_out` + VA grant, c2 SA grant +
crossbar + link register, c3 on the wire. It then asserts one flit arrived
with the right tag, type and exit port, reading the log one negedge after the
observed output so the logger cannot still be mid-race.

### 3.11 E1 - edge-of-mesh cases (4 checks)

Two LOCAL packets with in-range destinations, (2,1) and (1,0), asserted to
leave via EAST and NORTH respectively, after a `drain(300)`. What it targets is
the behavioural half of spec 4.6: XY routing with an in-range destination
never *needs* an absent direction. What it does **not** do is build an edge
router - this bench's DUT is instantiated with all five `HAS_* = 1'b1`, so the
tie-off and the two `!HAS_P[p] |-> …` properties in `router_top` are inert
here (§1.1). The tie itself, and those two properties, are covered by
`tb_router_chain`, whose three routers have `HAS_NORTH/HAS_SOUTH = 0` and
whose leftmost router has `HAS_WEST = 0`; `tools/assert_neg.sh` runs its
router_top seam case against that chain for exactly this reason.

### 3.12 Assertion coverage

The build's `--assert` flag means every SVA family in the design runs under
this traffic, in addition to (and independently of) the 104 bench checks - an
SVA failure prints its own `$error` text in the log rather than a `[FAIL]`
line. What is live:

- **`rtl/router_top.sv`** - 3 immediate parameter assertions at time 0
  (`NUM_VC` is 2, 4 or 8; `FLIT_W >= 16`; `FIFO_DEPTH` is a power of two of at
  least 2), plus 4 property templates in `gen_top_assert`, one instance per
  port (5 each):
  1. a stage-2 grant implies a stage-1 pick, `a_sa_gnt[p] == (a_sa_gnt[p] & a_sa_pick[p])` (seam 6);
  2. no credit may come back on a link that does not exist, `!HAS_P[p] |-> !(|credit_return_valid[p])` - **vacuous under this bench** (all five ports present);
  3. nothing may be routed to a port with no neighbour, `!HAS_P[p] |-> !a_st_valid[p]` - likewise **vacuous**;
  4. the arbiter grants only what the port requested, `a_sa_gnt[p] == (a_sa_gnt[p] & a_sa_req[p])`.

  Properties 1 and 4 are exercised constantly by T3–T7; 2 and 3 are proven to
  fire by `tools/assert_neg.sh` case 3, which runs against `tb_router_chain`.
- **`rtl/noc_input_port.sv`** - 13 clocking properties, the time-0 encoding
  check, and 2 immediate parameter assertions (`NUM_VC` is 2, 4 or 8;
  `FLIT_W >= 16`). Traffic-driven here: grant/request consistency
  (`va_gnt|->req_va`, `sa_gnt|->req_sa`, `sa_gnt|->sa_pick`), fetch legality
  (`fetch |-> !head_valid || sa_gnt`, `fetch |-> !fifo_empty || fifo_wr_enable`
  - the bypass case, hit by T9), FIFO protocol
  (`!(fifo_wr_enable && fifo_full)`, `!fifo_err` - the "credit accounting
  broken" family T7 exists to keep honest), assignment integrity
  (`va_gnt |-> !assignment_valid`, hit back-to-back by T3), type encoding,
  legal `out_port`, the HEAD/BODY*/TAIL sequence (T2–T6), and the two
  one-hot-at-most checks (`sa_pick`, `sa_gnt` - the property T4 depends on).
- **`rtl/arbiter.sv`** checks credit bounds and exact updates, reservation
  lifetime, same-class allocation, grant uniqueness for inputs and output VCs,
  SA eligibility, and legal XY turns. `va_gnt_out_vc` is a module output
  carrying the allocated VC, which can differ from the input VC.
- **`rtl/router_top.sv`** checks live ownership across FIFO gaps and verifies
  that SA and transmitted sidebands use each packet's assigned resource.
- **`rtl/crossbar.sv`** - 3 properties: selection in range, idle outputs drive
  zero, and output data/route tracking `xbar_sel` (exercised by every test
  that moves a payload - T2/T4 catch a crossed mux by data, the RTL by
  assertion).
- **`rtl/noc_output_port.sv`** - 8 properties: `route_next` legal while a head
  crosses, head's `[13:10]` replaced by the lookahead, non-head payload
  preserved, KIND field untouched, nothing outside `[13:10]` modified,
  `st_valid |=> flit_valid`, `!st_valid |=> !flit_valid`, and the `vc_id`
  sideband travelling with its flit. T1a/T1c/T2 assert the merge from outside
  via `rx_route`; these assert it from inside on every cycle.
- **`rtl/fifo.sv`** - the two immediate parameter assertions, which fire at
  time 0 regardless of traffic (see `docs/rtl/fifo.md` §3.3).

### 3.13 What this bench deliberately does not prove

Randomised soak - every stimulus here is directed, hand-built from the flit
constructors; the sustained-random coverage lives in the leaf benches (see
`tb_fifo`'s 879 checks). Multi-hop behaviour: one router cannot show
reordering across a path or a neighbour's real credit accounting, which is
what `tb_router_chain` adds. And the edge tie-off itself, per §3.11.

### 3.14 Mutation sanity

`tools/mutate_all.sh` (six mutants) and `tools/mutate_out.sh` (two) both
build against `tb_router_top` and judge by grepping the
`CHECKS (PASSED|FAILED)` line - and they build **without** `--assert`, so in
those runs it is the bench's own 104 checks, not the SVA, that must kill the
mutation. The mutation set is essentially this bench's test list in reverse:
XY direction inverted (T1), stage-2 round-robin ignoring its pointer (T5),
grant-wins-over-fetch (T8), stage-1 ignoring the credit pool (T7), the crossbar
data mux reading the wrong port (T2/T4 payload identity), and the header merge
written wrong / never / always (T1a, T1c, T2's route and bit-identical BODY and
TAIL checks).
