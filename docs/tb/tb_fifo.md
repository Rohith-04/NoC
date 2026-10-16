# `tb_fifo` — `tb/tb_fifo.sv`

Self-checking bench for the FIFO: a clocked, reference-model bench that drives
one operation per cycle, keeps a golden queue in lockstep with the DUT, and
compares the DUT's flags and read data against that queue after every single
edge. It is deliberately exhaustive over the small state space a FIFO has —
*(occupancy, wr, rd)* — rather than sampling it, because a pointer bug that
only shows up on one specific occupancy will not be caught by a couple of
directed writes. It produces **879 checks**.

---

## 1. Ports and state

### 1.1 Port declaration

The bench top has no ports of its own; the table below is the interface it
presents to the single `fifo` instance named `dut`. Direction is from the
FIFO's point of view: `input` means the bench drives it into the DUT,
`output` means the DUT drives it out to the bench.

| Signal | Width | Direction | Source → Destination | Working / description |
|---|---|---|---|---|
| `clk` | 1 | input | bench clock generator → `dut.clk` | Free-running 10 ns clock, toggled every `CLK_PERIOD/2`. Every DUT update happens on `posedge clk`. |
| `rst_n` | 1 | input | `reset_dut()` → `dut.rst_n` | Active-low **synchronous** reset; held low for four full periods, then released. The bench also zeroes its own model when it releases. |
| `wr_enable` | 1 | input | `drive_write()` / `drive_read_write()` → `dut.wr_enable` | Driven high on a negedge and dropped on the next negedge, so it spans exactly one posedge. |
| `rd_enable` | 1 | input | `drive_read()` / `drive_read_write()` → `dut.rd_enable` | Same one-cycle-at-a-time cadence; high together with `wr_enable` for the simultaneous cases. |
| `data_in` | `WIDTH` (40) | input | driver tasks → `dut.data_in` | Payload for the write half of a transaction: `$urandom` in most tests, `0..FIFO_DEPTH-1` when `test_full_read_write` fills the queue so the model's expected pop is a known value, and `32'hDEAD_BEEF` for the write that is supposed to be rejected. |
| `data_out` | `WIDTH` (40) | output | `dut.data_out` → `drive_read()` / `drive_read_write()` checks | Sampled 1 ns *after* the posedge; compared to the queue's `pop_front()` value, or to its own previous value on a rejected read. |
| `empty` | 1 | output | `dut.empty` → driver / test-level checks | Sampled after every edge and compared to `ref_model.size() == 0`; also asserted directly by `test_reset` and `test_empty`. |
| `full` | 1 | output | `dut.full` → driver / test-level checks | Compared to `ref_model.size() == FIFO_DEPTH` after every edge; `test_full` and `test_protocol_violation` assert it explicitly. |
| `err` | 1 | output | `dut.err` → driver checks | **Combinational**, so it is sampled *before* the edge (after a `#0` settle at the negedge) against the error the model predicts for this cycle's enables. |

### 1.2 Parameters, variables and state

| Name | Width | Kind | Reset | Working / description |
|---|---|---|---|---|
| `WIDTH` | 40 | `localparam int` | — | Element width: one flit, the width the rest of the design runs at (`linnea_v2` section 1). Passed to the DUT as `.WIDTH(WIDTH)` so bench and DUT can never disagree. |
| `FIFO_DEPTH` | 4 | `parameter int` | — | Queue depth; passed as `.DEPTH(FIFO_DEPTH)`. It is also the loop bound for every fill/drain loop and the occupancy value every `full` check compares against. Declared `parameter` (not `localparam`) under the suite-wide knob name `FIFO_DEPTH`, so a `-GFIFO_DEPTH=` override reaches this bench too. |
| `CLK_PERIOD` | 10 ns | `localparam realtime` | — | Clock period; `CLK_PERIOD/2` is the toggle delay, and reset length is `4 * CLK_PERIOD`. |
| `clk` | 1 | `logic` (bench-driven) | `0` at time 0 | `initial clk = 0;` plus `always #(CLK_PERIOD/2) clk = ~clk;`. |
| `rst_n` | 1 | `logic` (bench-driven) | 0 while in reset | Written only by `reset_dut()`. |
| `wr_enable`, `rd_enable` | 1 | `logic` (bench-driven) | 0 | Written only by the three driver tasks (and parked at 0 by `reset_dut()`). |
| `data_in` | `WIDTH` | `logic` (bench-driven) | `'0` | Written only by the driver tasks. |
| `data_out`, `empty`, `full`, `err` | `WIDTH` / 1 | `logic` (DUT-driven) | DUT-defined | Pure observations; the bench never assigns them. |
| `ref_model` | `WIDTH` | queue (`logic [WIDTH-1:0] [$]`) | `delete()` in `reset_dut()` | The golden FIFO. `push_back` on an accepted write, `pop_front` on an accepted read, untouched by the empty-bypass and by a rejected write. Its `size()` *is* the expected occupancy. |
| `checks` | 32-bit `int` | counter | 0 | Incremented once per `check()` call — the denominator of the final report. |
| `errors` | 32-bit `int` | counter | 0 | Incremented once per failed `check()`; the final `errors == 0` decides the pass banner. |

The driver tasks additionally hold short-lived locals (`was_full`,
`was_empty`, `exp_err`, `exp_data`, `prev_data_out`) that exist for the
duration of one transaction only; they are described in §2.4 because their
lifetime is what makes the ordering of *sample → commit → update → compare*
correct.

---

## 2. RTL explanation

### 2.1 Clock and reset (lines 43–60)

The clock is the universal idiom — `initial clk = 0;` followed by
`always #(CLK_PERIOD / 2) clk = ~clk;` — giving a 10 ns period with edges on
5 ns boundaries. `reset_dut()` parks the three driven inputs at 0, drops
`rst_n`, waits four full periods (so several posedges see the reset active,
which matters because the FIFO's reset is synchronous), releases it, and then
calls `ref_model.delete()` so the model and the DUT start every test from the
same known-empty state. Because `reset_dut()` is invoked at the top of every
test, no test inherits state from the previous one.

### 2.2 The drive/sample cadence, and why it is shaped that way

Every driver task follows the same four-step rhythm:

```systemverilog
@(negedge clk);            // 1. change inputs, half a cycle before the commit edge
  wr_enable = 1'b1; ...    //    compute expectations from the model's CURRENT size
  #0;                      // 2. settle, then check combinational outputs (err)
check("...", err == exp_err);
@(posedge clk);            // 3. the DUT commits the transaction
  #1;                      //    1 ns past the edge: nonblocking updates are done
  ... update ref_model ... //    model now reflects what WAS accepted
  check("...", ...);        //    compare registered outputs against the new model
@(negedge clk);            // 4. drop the enables
  wr_enable = 1'b0;
```

Driving on the negedge means the inputs are stable a full half-cycle before
the posedge samples them, so there is never a race between a testbench
assignment and the DUT's clocked block. Sampling combinationally at step 2
after `#0` catches `err` in the very cycle that caused it — one cycle later
`wr_enable` is already gone and the flag would say nothing. Sampling at step 3
after `#1` avoids reading `data_out`/`empty`/`full` while their nonblocking
updates are still in flight. Step 4 guarantees the enable was high across
exactly one posedge, so "one call = one transaction" and consecutive calls
tile back-to-back with no idle cycle between them.

### 2.3 The check task (lines 83–91)

```systemverilog
task automatic check(string name, bit cond);
  checks++;
  if (cond) $display("[PASS] %s", name);
  else begin
    $display("[FAIL] %s", name);
    errors++;
  end
endtask
```

This is the *only* scoring mechanism in the bench: a name and a boolean. It
always increments `checks`, prints a greppable `[PASS]`/`[FAIL]` line with
the human-readable case name (the names double as the per-test breakdown in
§3.1), and bumps `errors` on failure. It never aborts — a failing test keeps
running so the log shows how far the corruption propagated — and the final
banner is decided purely by `errors`.

The bench deliberately does **not** import `noc_tb_pkg`. That package owns a
shared `checks`/`errors` pair and a `check()` that compares two `FLIT_W`-wide
values and prints them as hex — a reporter shaped for flits, where a test
hands it an actual and an expected word. This bench has the other shape: a
narrow `(name, bit)` predicate evaluated at the call site, with the comparison
already done by the caller, so it keeps its own counters and its own task.
Importing the package while declaring a local `check` would hide the imported
name outright (Verilator reports `VARHIDDEN`), so the split is a decision
rather than an oversight — the same reasoning the package's own header gives.

### 2.4 The reference model and the three driver tasks (lines 109–305)

`ref_model` is a SystemVerilog queue acting as a golden copy of the FIFO
contents. All expected values derive from it, which is why the drivers are
careful about *when* they read it:

- **`drive_write(data)`** — captures `was_full = (ref_model.size() == FIFO_DEPTH)`
  *before* the edge, derives `exp_err = was_full`, checks `err` pre-edge, then
  after the edge pushes the data only `if (!was_full)` and checks `empty` and
  `full` against the new size. A write while full therefore both raises `err`
  and leaves occupancy alone, exactly as §2.3 of `docs/rtl/fifo.md` specifies.
- **`drive_read()`** — captures `was_empty` and `prev_data_out` before the
  edge. After the edge it either pops and checks `data_out == exp_data`
  (`"Read: data_out"`) or, on a rejected read, checks `data_out ==
  prev_data_out` (`"Read: data_out held"`). Then `empty`/`full` against the
  post-pop size. The held-data check is the one that would catch a read path
  that clears `data_out` instead of leaving it stale.
- **`drive_read_write(data)`** — the three-way case. It latches `was_empty`
  and `was_full` from the model *before* the edge, picks the matching
  pre-edge `err` expectation (`"R/W empty bypass"`, `"R/W full"`,
  `"R/W normal"`), and then post-edge takes exactly one of three model
  actions: nothing (bypass), `pop_front()` only (full: read wins, write
  rejected), or `pop_front()` + `push_back()` (normal). The checks that
  follow — `empty`, `full`, `data_out`, and for the bypass the *unchanged*
  occupancy — are what distinguish "bypassed" from "stored", since checking
  `data_out` alone would pass even if the flit had also been written to
  `mem`.

The model never guesses: it applies the DUT's documented acceptance rules to
its own state, then demands the DUT agree.

### 2.5 Test sequencing, report and waveform (lines 497–531)

The main `initial` block runs the ten tests of §3.1 in a fixed order, each of
which begins with its own `reset_dut()`. It then prints a separator, the two
counters, and exactly one of `ALL TESTS PASSED` (when `errors == 0`) or
`TEST FAILED`, before `$finish`. A second, independent `initial` block dumps
`sim/fifo.vcd` for the whole hierarchy (`$dumpvars(0, tb_fifo)`), so
`make TOP=fifo wave` can open it. There is no global timeout in this bench —
it cannot hang, because every driver task blocks only on clock edges and the
clock never stops.

---

## 3. Testing explanation

**Bench:** `tb/tb_fifo.sv`, top module `tb_fifo`.
**Run:** `make TOP=fifo sim` — final report:

```
Checks : 879
Errors : 0
ALL TESTS PASSED
```

### 3.1 The tests, in source order

| # | Test (banner) | Property it targets | Checks |
|---|---|---|---|
| 1 | `test_reset` | Idle state out of reset: `empty==1`, `full==0`, `err==0`. | 3 |
| 2 | `test_write_only` | Four consecutive random writes accepted; `err` low, `empty` dropping, `full` rising exactly at occupancy 4 (`FIFO_DEPTH`). | 12 |
| 3 | `test_read_only` | Fill then drain: every read returns the oldest element (FIFO order) and the flags track the model down to empty. | 28 |
| 4 | `test_full` | The explicit `full` corner — after `FIFO_DEPTH` writes `full==1` and `empty==0`. | 14 |
| 5 | `test_empty` | The explicit read-while-empty violation: `err==1`, `empty` still set, `full` still clear. | 7 |
| 6 | `test_simultaneous_read_write` | Normal-occupancy R/W: both operations succeed, occupancy unchanged, `err==0`, five times from occupancy 2. | 26 |
| 7 | `test_empty_bypass` | R/W on an empty FIFO: `data_out == data_in` on the next edge **and** the model stays empty (nothing was stored). | 5 |
| 8 | `test_full_read_write` | R/W while full — read accepted, `32'hDEAD_BEEF` write rejected, `err==1`, `full` drops, occupancy falls to `FIFO_DEPTH-1`. | 19 |
| 9 | `test_protocol_violation` | The fifth write into a full FIFO: rejected, `full` stays high, occupancy pinned at `FIFO_DEPTH`. | 17 |
| 10 | `test_random(200)` | Soak: 200 transactions drawn uniformly from `{write, read, read+write}` (`$urandom_range(0,2)`), every one checked against the queue. Random data (`$urandom`) makes ordering bugs visible in `data_out`. | 748 |
| | | **Total** | **879** |

Together the directed tests pin down every row of the *(occupancy, wr, rd)*
truth table — including the two corner combinations where one enable is legal
and the other is not — while the soak supplies the pointer wrap-arounds that
no single fill/drain pass reaches (a test that resets before its second lap
never wraps the index bits back to slot 0; 200 random transactions do, many
times over).

### 3.2 What the bench does not check

`mem` contents after reset (the array is intentionally unreset, §1.3 of
`docs/rtl/fifo.md`), and anything about 4-state values: Verilator is 2-state,
so the bench makes no X-propagation claims. It also does not police *when*
the bench itself drives illegal sequences — protocol violations are provoked
deliberately, and only the DUT's reaction (`err`, occupancy, held data) is
scored.

### 3.3 Assertion coverage

`rtl/fifo.sv` contains **no clocking SVA** — its only assertions are the two
time-0 parameter checks (`WIDTH > 0`, `DEPTH` a power of two ≥ 2). Those run
in this build because the Makefile compiles every bench with `--assert`, and
they are proven to *fire* by `tools/assert_neg.sh` case 1, which rewrites the
bound from `DEPTH >= 2` to `DEPTH >= 9`, so the depth this build is configured
with — 4 — no longer satisfies it and `$fatal`s at time 0, before a single
cycle runs:

```
%Fatal: fifo.sv:67: Assertion failed ... fifo: DEPTH must be a power of two >= 2, got 4
```

So for this module the bench is the checker: `err`, occupancy and data order
are all scored by `check()`, not by SVA. (Once the FIFO is embedded in
`noc_input_port`, its `err` output *is* watched by that module's `!fifo_err`
assertion — see `docs/tb/tb_noc_input_port.md` §3.3.)

### 3.4 Mutation sanity

`tools/mutate_all.sh` deliberately does not target this file: it builds
without `--assert` against `tb_router_top`, where a FIFO mutation would be
caught by a higher-level bench anyway, and the parameter check would be lost
in that configuration. The FIFO's own mutation coverage is this bench's 879
checks.
