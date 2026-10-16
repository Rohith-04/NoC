# `fifo` — `rtl/fifo.sv`

Synchronous, power-of-two, pointer-based FIFO with simultaneous read and
write, an empty-bypass path that removes a cycle of latency, and explicit
protocol-violation reporting. It is the storage element behind every
virtual-channel buffer in `noc_input_port`, and it is the module the rest of
the design is written against when it talks about "credits" — a credit is
simply a free slot here.

---

## 1. Ports and state

### 1.1 Parameters

| Name | Type | Default | Constraint | Meaning |
|---|---|---|---|---|
| `WIDTH` | `int` | 40 | `WIDTH > 0` | Width of one stored element. The NoC stores whole flits, so this is 40 — the design's `FLIT_W`. The FIFO itself is width-agnostic and never looks inside the word. |
| `DEPTH` | `int` | 4 | power of two, `>= 2` | Number of elements. The wrap-bit pointer scheme needs a power of two so the index is just the low `ADDRWIDTH` bits. |

Derived: `ADDRWIDTH = $clog2(DEPTH)` — the pointer is `ADDRWIDTH+1` bits
wide; the extra bit is the wrap bit.

Both constraints are enforced by immediate assertions in an `initial` block
(§2.1).

### 1.2 Port declaration

| Signal | Width | Direction | Source → Destination | Working / description |
|---|---|---|---|---|
| `clk` | 1 | input | clock generator → all sequential logic | Single write-and-advance edge. Everything (memory write, both pointers, `data_out`) updates on `posedge clk`. |
| `rst_n` | 1 | input | reset generator → `always_ff` | Active-low synchronous reset. Clears both pointers and `data_out`; it does **not** clear `mem`, which is deliberately unreset (resetting a memory is not synthesizable for FPGAs and buys nothing here — `empty` gates every read). |
| `wr_enable` | 1 | input | producer (the input port's write side) → write path | Asserted for exactly one cycle with `data_in` valid. A write while `full` is rejected and raises `err`. |
| `rd_enable` | 1 | input | consumer (the input port's fetch side) → read path | Asserted for exactly one cycle to pop the oldest element. A read while `empty` is rejected and raises `err`, *unless* `wr_enable` is also high — that combination is the bypass case. |
| `data_in` | `WIDTH` | input | producer → memory / bypass path | Element to store. On an empty FIFO with both enables it goes straight to `data_out` without entering `mem`. |
| `data_out` | `WIDTH` | output | FIFO → consumer | Registered. Holds the element popped on the most recent read edge; the bypass path writes it too, so it is never a stale value after a read. |
| `empty` | 1 | output | FIFO → producer / arbiter | `w_ptr == r_ptr`. Combinational, so a producer can decide in the same cycle whether there is room. |
| `full` | 1 | output | FIFO → producer / credit logic | Wrap bits differ **and** index bits equal: the queue has wrapped completely onto itself. Combinational. |
| `err` | 1 | output | FIFO → testbench / protocol checker | `(wr_enable && full) \|\| (rd_enable && empty && !wr_enable)`. A purely observational flag — nothing in the design consumes it at runtime, it exists so that a bookkeeping bug is reported rather than silently corrupting the queue. |

There is no read-data "valid" output: the consumer knows a pop happened
because it asserted `rd_enable` and `!empty`.

### 1.3 Registers and state

| Name | Width | Kind | Reset | Working / description |
|---|---|---|---|---|
| `mem[DEPTH]` | `WIDTH` each | array (not reset) | `x` → written before read | Storage. Indexed by `w_ptr[ADDRWIDTH-1:0]` on write and `r_ptr[ADDRWIDTH-1:0]` on read. |
| `w_ptr` | `ADDRWIDTH+1` | register | `0` | Write pointer. Bit `ADDRWIDTH` is the wrap bit; bits `ADDRWIDTH-1:0` are the memory index. |
| `r_ptr` | `ADDRWIDTH+1` | register | `0` | Read pointer, same encoding. |
| `data_out` | `WIDTH` | register | `0` | Output register, written by both the read path and the empty-bypass path. |

Status signals `empty`, `full` and `err` are combinational functions of the
pointers and the enables — they are **not** registers and hold no state.

---

## 2. RTL explanation

### 2.1 Parameter checks (lines 62–68)

```systemverilog
initial begin
  assert (WIDTH > 0) else $fatal(...);
  assert ((DEPTH >= 2) && ((DEPTH & (DEPTH - 1)) == 0)) else $fatal(...);
end
```

These fire at time 0, before the first clock edge, so an illegal
instantiation fails immediately and by name instead of producing a
mysterious pointer aliasing later. `DEPTH & (DEPTH-1) == 0` is the standard
power-of-two test and is the only reason the wrap-bit scheme below is legal.
`DEPTH >= 2` is required because `full` compares `w_ptr[ADDRWIDTH-1:0]` —
with `DEPTH == 1`, `ADDRWIDTH` would be 0 and that slice would be empty.

This is the one assertion family in the design that is *not* clocking SVA;
`tools/assert_neg.sh` case 1 exercises it by widening the bound to 9 so the
default `DEPTH = 4` becomes illegal.

### 2.2 Pointers and status (lines 70–97)

The pointers are one bit wider than the address. Comparing the wrap bits
gives the classic two-case status:

- **empty** — the pointers are bit-identical. Cheap and exact.
- **full** — the wrap bits differ but the index bits match, i.e. `w_ptr` has
  travelled exactly one full lap past `r_ptr`.

Because `DEPTH` is a power of two, "advance by one" wraps the index
automatically: the low `ADDRWIDTH` bits of `w_ptr + 1` are the next slot. No
separate wrap compare is needed, which is the entire reason for the
parameter constraint in §2.1.

### 2.3 Protocol error (line 106)

```systemverilog
assign err = (wr_enable && full) || (rd_enable && empty && !wr_enable);
```

Three of the four illegal cases are visible combinationally. The fourth —
read and write together while empty — is *not* an error, it is the bypass
(§2.4), hence the `&& !wr_enable` term. Keeping `err` purely combinational
means it names the offending cycle exactly rather than one cycle later.

### 2.4 The sequential block (lines 112–178)

The block has three mutually exclusive cases, checked in this order:

1. **Reset** — pointers and `data_out` to zero.

2. **Empty bypass** (`empty && wr_enable && rd_enable`) — `data_in` is
   written straight into `data_out` and *neither pointer moves*. Occupancy
   is unchanged: nothing entered storage, nothing left it. This removes a
   cycle of latency when the consumer asks for data at the exact cycle the
   producer supplies it, which on a link that runs one flit per cycle is the
   difference between full rate and half rate. It is explicitly **not**
   First-Word Fall-Through — `data_out` does not show the head of the queue
   without a `rd_enable`; it forwards only in this one simultaneous case.

3. **Normal operation** — two independent `if` statements, not `if/else`:

   ```systemverilog
   if (rd_enable && !empty) begin data_out <= mem[r_ptr[...]]; r_ptr <= r_ptr + 1; end
   if (wr_enable && !full)  begin mem[w_ptr[...]] <= data_in;  w_ptr <= w_ptr + 1; end
   ```

   The independence is the point. Reading and writing the same cycle must
   both proceed even when the FIFO is full — the read frees a slot in that
   same edge, so rejecting the write would lose a cycle for no reason. The
   asymmetry in the guards reflects the exact illegal conditions from §2.3:
   a read only needs `!empty`, a write only needs `!full`, and neither
   considers the other enable.

   Note that when the FIFO is full and both enables are high, the read
   advances `r_ptr` and the write is still rejected. That is a deliberate
   consequence of the protocol statement in the header: *"the write is
   rejected, `err` is asserted, the read proceeds normally."* The producer
   is required to have observed `full` before it asserted `wr_enable`.

### 2.5 What this module does not do

Credit accounting lives above this FIFO, in `noc_input_port`. `full` and
`empty` are instantaneous occupancy status; a credit is a *reserved* slot,
and the difference matters — see the `credit_count` discussion in
`rtl/arbiter.md`. The header says so explicitly so that nobody "helpfully"
adds a credit counter here.

---

## 3. Testing explanation

**Bench:** `tb/tb_fifo.sv`, top module `tb_fifo` (879 checks).
**Run:** `make TOP=fifo sim` — reports `Checks : 879 / Errors : 0`.

### 3.1 Why 879 checks and not a handful

A FIFO's correct behaviour is a function of *(occupancy, wr, rd)*. The bench
exercises that space systematically rather than sampling it:

- **Directed protocol cases.** Write-while-full, read-while-empty, and both
  illegal corners with both enables high — each asserting `err` and,
  critically, asserting that the *other* operation still happened. The
  full-plus-read case must pop; the empty-plus-write case must not store.
  These are the behaviours §2.3 and §2.4 spell out in prose, and they are
  exactly the ones that are easy to invert when editing the two `if`
  statements.
- **Bypass.** The empty-plus-both case is checked for `data_out == data_in`
  on the very next edge *and* for unchanged occupancy — `empty` still high,
  `full` still low. Checking only `data_out` would pass even if the data had
  also been stored, corrupting the queue.
- **Fill-to-full and drain-to-empty sweeps.** Repeated writes until `full`
  (exactly `DEPTH` of them), then repeated reads until `empty` (exactly
  `DEPTH`), verifying data order at every step. This is what proves the wrap
  bit: a pointer that forgot to wrap would read back a wrong value at slot
  0 on the second lap.
- **Simultaneous read+write at every occupancy**, including the boundary
  cases where it converts a full FIFO into a not-full one in the same edge.
- **Randomised soak.** Thousands of cycles of random `wr_enable`/`rd_enable`
  with a reference model tracking expected occupancy and a data-integrity
  pattern, so an ordering bug that needs a specific pointer coincidence has
  a chance to show up.

### 3.2 What the bench deliberately does not check

`mem` contents at reset. The array is intentionally unreset (§1.3); a bench
that demanded known data before the first write would be asserting a
behaviour the design does not promise and that no synthesizer would
preserve.

### 3.3 Assertion coverage

The parameter assertions in §2.1 are the only SVA in this file, and they are
proven to fire by `tools/assert_neg.sh` case *"fifo: DEPTH parameter check"*,
which rebuilds the FIFO with the `DEPTH >= 2` bound widened to 9 — with that
bound the default `DEPTH = 4` is itself illegal — and requires:

```
%Fatal: fifo.sv:67: Assertion failed ... fifo: DEPTH must be a power of two >= 2, got 4
```

The build for that case runs with `--assert`, which is mandatory in this
flow — without the flag the tool parses the `assert` and silently drops it.

### 3.4 Mutation sanity

`tools/mutate_all.sh` does not target this file: a mutation here would be
caught by the FIFO bench rather than by one of the higher-level benches it
is built around, and the `--assert`-off builds those scripts use would lose
the parameter check anyway.
