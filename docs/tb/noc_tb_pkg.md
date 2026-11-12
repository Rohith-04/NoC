# `noc_tb_pkg` - `tb/noc_tb_pkg.sv`

The testbenches' shared namespace: the flit field model, the constructors,
the reference model of the output-port merge, and the pass/fail reporter. Its
own header comment calls it "the one place the testbenches are allowed to know
what a flit *is*", and that is the whole design rule - a test never names a bit
position, never spells a KIND as a literal, and never reimplements the
bookkeeping. Unlike every other file documented under `docs/tb/`, this is a
`package`, not a module: it has no ports, no clock, no DUT, and it is never
elaborated as a top. It exists to be imported.

---

## 1. Ports and state

A package presents no interface and holds no sequential state, so this section
lists everything it declares: the namespace's constants, then its public API.

### 1.1 Constants (the localparams)

The constants define the shared flit layout. `FLIT_W` is a `localparam` here rather than a
parameter because the package is a namespace, not a module - there is nothing
to override it on. The RTL and the benches keep `FLIT_W` as a *parameter*
(linnea_v2 §4 item 1) and pass it down to their DUTs; both sides are 40, and
only ever 40.

| Name | Type | Value | Meaning |
|---|---|---|---|
| `FLIT_W` | `int` | 40 | Width of one flit (linnea_v2 §3). Every function argument and return below is sized from it. |
| `TAG_W` | `int` | 26 (`FLIT_W - 14`) | The tag: the reserved upper region `[FLIT_W-1:14]`, which the routers never read. Benches stamp a packet with it so the scoreboard can tell two in-flight packets apart. When the NI arrives and claims SRC/ID/LEN for real this shrinks - and because there is one definition of it, it shrinks in one place. |
| `PAY_W` | `int` | 38 (`FLIT_W - 2`) | Payload width of a BODY/TAIL for `mk_payload`: everything above the TYPE field. |
| `ROUTE_MASK` | `logic [FLIT_W-1:0]` | `'h00003C00` | Bits `[13:10]`: the header's ROUTE field, and the only field the output port's lookahead merge is allowed to rewrite. |
| `FLIT_BODY` | `logic [1:0]` | `2'b00` | TYPE encoding, field `[1:0]`. The two low bits do double duty as `is_head` (bit 0) and `is_last` (bit 1) - the spelling the RTL uses throughout. |
| `FLIT_HEAD` | `logic [1:0]` | `2'b01` | TYPE: head of a multi-flit packet. |
| `FLIT_TAIL` | `logic [1:0]` | `2'b10` | TYPE: tail, last flit of a packet. |
| `FLIT_HEAD_TAIL` | `logic [1:0]` | `2'b11` | TYPE: single-flit packet (head and tail at once). |
| `KIND_WR_REQ` | `logic [1:0]` | `2'b00` | KIND encoding, field `[3:2]` of a header. Written once by the source NI, never read by a router (assumption D3 - not their consumer, not their business), but the scoreboard checks it survived the trip. Named constants because the field used to be `VC_ID` and the two must never be confused again. |
| `KIND_RD_REQ` | `logic [1:0]` | `2'b01` | KIND: read request. |
| `KIND_WR_RESP` | `logic [1:0]` | `2'b10` | KIND: write response. |
| `KIND_RD_RESP` | `logic [1:0]` | `2'b11` | KIND: read response. |

### 1.2 Functions (the codec API)

Every function is `function automatic`. A reader takes a whole flit and
returns one field; a `with_*` is pure - it returns a copy with one field
replaced; a `mk_*` builds a flit from named fields. Readers, setters, constructors and the reference model share this layout.

| Function | Signature | Purpose |
|---|---|---|
| `flit_type` | `logic [1:0] flit_type(logic [FLIT_W-1:0] f)` | The TYPE field `[1:0]`. |
| `flit_kind` | `logic [1:0] flit_kind(logic [FLIT_W-1:0] f)` | The KIND field `[3:2]` (headers only; routers ignore it). |
| `flit_dst_x` | `logic [2:0] flit_dst_x(logic [FLIT_W-1:0] f)` | Destination X, `[6:4]`. |
| `flit_dst_y` | `logic [2:0] flit_dst_y(logic [FLIT_W-1:0] f)` | Destination Y, `[9:7]`. |
| `flit_route` | `logic [3:0] flit_route(logic [FLIT_W-1:0] f)` | The ROUTE field `[13:10]` - the one-hot direction a router switches on. |
| `flit_burst` | `logic [1:0] flit_burst(logic [FLIT_W-1:0] f)` | BURST, `[31:30]`. Routers never read it, which makes it the cheapest place for a bench to smuggle attribution through the network (see `tb_router_top`'s `rx_origin`). |
| `flit_id` | `logic [7:0] flit_id(logic [FLIT_W-1:0] f)` | ID, `[21:14]`. |
| `flit_tag` | `logic [TAG_W-1:0] flit_tag(logic [FLIT_W-1:0] f)` | The whole reserved upper region `[FLIT_W-1:14]` - the bench-level packet name. |
| `flit_is_head` | `bit flit_is_head(logic [FLIT_W-1:0] f)` | `f[0]` - TYPE bit 0, restated from the encoding rather than re-derived at each call site. |
| `flit_is_last` | `bit flit_is_last(logic [FLIT_W-1:0] f)` | `f[1]` - TYPE bit 1. |
| `with_type` | `logic [FLIT_W-1:0] with_type(f, logic [1:0] t)` | Copy of `f` with TYPE replaced. |
| `with_kind` | `logic [FLIT_W-1:0] with_kind(f, logic [1:0] k)` | Copy of `f` with KIND replaced. |
| `with_dst` | `logic [FLIT_W-1:0] with_dst(f, logic [2:0] dy, logic [2:0] dx)` | Copy of `f` with DEST_Y and DEST_X replaced. |
| `with_route` | `logic [FLIT_W-1:0] with_route(f, logic [3:0] route)` | Copy of `f` with ROUTE replaced - the setter the merge reference model is written with. |
| `with_id` | `logic [FLIT_W-1:0] with_id(f, logic [7:0] id)` | Copy of `f` with ID replaced. |
| `with_tag` | `logic [FLIT_W-1:0] with_tag(f, logic [TAG_W-1:0] tag)` | Copy of `f` with the whole tag region replaced. |
| `mk_hdr` | `logic [FLIT_W-1:0] mk_hdr(logic [1:0] typ, logic [1:0] kind, logic [3:0] route, logic [2:0] dest_y, logic [2:0] dest_x, logic [TAG_W-1:0] tag)` | The whole field map in one call - every named field of a header at once. |
| `mk_head` | `logic [FLIT_W-1:0] mk_head(dx, dy, route, kind, tag)` | `mk_hdr(FLIT_HEAD, …)` - head of a multi-flit packet. |
| `mk_ht` | `logic [FLIT_W-1:0] mk_ht(dx, dy, route, kind, tag)` | `mk_hdr(FLIT_HEAD_TAIL, …)` - a single-flit packet. |
| `mk_payload` | `logic [FLIT_W-1:0] mk_payload(logic [1:0] typ, logic [PAY_W-1:0] payload)` | BODY/TAIL with a free payload: everything above the TYPE field is the caller's. The input-port bench builds its own payloads rather than tagged packets, so it needs this rather than `mk_body`/`mk_tail`. |
| `mk_body` | `logic [FLIT_W-1:0] mk_body(logic [TAG_W-1:0] tag)` | Tagged BODY. Its payload filler is deliberately non-zero in `[13:10]` - see §2.4. |
| `mk_tail` | `logic [FLIT_W-1:0] mk_tail(logic [TAG_W-1:0] tag)` | Tagged TAIL, same filler discipline (`12'h401`, i.e. `[13:10] = DIR_WEST`). |
| `ref_merge` | `logic [FLIT_W-1:0] ref_merge(logic [FLIT_W-1:0] d, logic [3:0] lookahead)` | The reference model of the output-port lookahead merge, written from the spec's wording rather than the DUT's code: a head's route field becomes the lookahead; everything else - including KIND, per D3 - survives byte for byte. |

### 1.3 Tasks and shared state

| Name | Kind | Purpose |
|---|---|---|
| `checks`, `errors` | `int`, initialised to 0 | The shared pass/fail counters. They live here rather than in each bench so that "checks" and "errors" mean the same thing everywhere and a bench cannot quietly grow its own. Each bench runs as its own Verilator binary, so a single static pair has no cross-talk. |
| `check(what, actual, expected)` | task | Counts one comparison of two `FLIT_W`-wide values; on mismatch increments `errors` and prints `[FAIL]` with both values, else `[PASS]`. `what` is a description string, printed in a fixed 62-column field so run logs line up. |
| `check_true(what, cond)` | task | The same bookkeeping for a single bit condition. |
| `report_stats()` | task | The summary line: `ALL <n> CHECKS PASSED` when `errors == 0`, else `<err>/<n> CHECKS FAILED`. |

---

## 2. RTL explanation

### 2.1 One file knows the field map

Before this file existed, every bench restated the section 3.2 field map for
itself: `f[3:2] = kind` here, `data[FLIT_W-1:14]` there, a fifth copy of the
same `check()` task in each of five files, and a KIND write with no name to
write it under. Every one of those is a place where a
field-map change would have to be found and fixed in several files - and
where a change applied to only some of them would pass every test still
green. The rule the package exists to enforce is short:

* a test never names a bit position - it calls `flit_route()`, `flit_tag()`,
  `with_kind()`, `mk_head()`, …;
* a test never spells a KIND as `2'b01` - it writes `KIND_RD_REQ`;
* a test never reimplements the pass/fail bookkeeping - it calls `check()`.

So if the map moves, the compiler moves it: a accessor call cannot quietly
keep reading the old bits the way a slice expression can.

### 2.2 Deliberately the shape of the future UVM environment

The split - a field model, readers and setters by name, constructors, a
reference model, a reporter - is exactly the shape a UVM
environment takes: a sequence item with a field model, a scoreboard that
reads the fields by name, a shared reporter. Nothing in the file is
Verilator-specific, so promoting it later is a move, not a rewrite.

### 2.3 It must be compiled first

A package has to exist before anything can import it, and `wildcard` returns
names in whatever order the filesystem feels like. The Makefile therefore
forces `PKG := tb/noc_tb_pkg.sv` to the head of every bench's file list
(the corresponding declaration of the package header; the `TB` variable in `docs/Makefile.md`
§1.2), and `tools/assert_neg.sh` and `tools/mutate_*.sh` put it first in
their Verilator file lists for the same reason. Left to chance, the build
would fail on a fresh checkout and work on a machine that happened to sort
differently.

### 2.4 The payload filler is a trap for a leaked merge

`mk_body`/`mk_tail` fill `[13:2]` with `12'h201` / `12'h401` rather than
zeros. `[13:10]` is exactly the field the output port
merges into a *header*; a real direction value there (`201` → `DIR_EAST`,
`401` → `DIR_WEST`) is what makes "the merge leaked onto a BODY/TAIL"
observable - the lookahead for those payload bits is never the value they
already carry, so an unwanted overwrite changes them. The two literals are
spelled out rather than assembled from `DIR_EAST`/`DIR_WEST` because the low
two bits must differ too: a filler whose TYPE bits read `00` would make the
flit look like a BODY to anything reading the wrong slice.

### 2.5 One copy of the constructors

`tb_router_chain` and `tb_router_top` each used to carry byte-identical
copies of `mk_head`/`mk_ht`/`mk_body`/`mk_tail`, with a comment in the chain
bench warning that they "must stay identical to tb_router_top's, because the
chain tests compare a received body against the one that was sent". That warning is redundant now: there is one of each, and
the property it guarded holds by construction.

### 2.6 The lint waiver is scoped to this file only

The package opens with `lint_off UNUSEDPARAM` / `lint_off UNUSEDSIGNAL` and closes with the matching `lint_on` before `endpackage`. Both waivers are inherent to what a codec is rather than
signs of a problem: a namespace's members are used by whoever imports it, not
by the namespace itself (`UNUSEDPARAM`), and every field accessor by
construction reads one slice and leaves the rest alone, so `flit_type()`
reporting "[39:2] not used" is describing correct behaviour
(`UNUSEDSIGNAL`). The waiver stops at the end of the file - `make lint`
compiles only `rtl/*.sv` at full `-Wall`, so the RTL is still held to all of
it.

---

## 3. Testing explanation

The package has no bench of its own: it declares no `main`, no clock, and no
DUT, and `make TOP=<x> sim` never selects it directly. It is exercised by
compiling into every bench that imports it - which also means a bench that
*imports* it and calls a deleted function fails to compile, so API drift is
caught at build time.

### 3.1 Who imports it (7 benches)

| Bench | What it uses |
|---|---|
| `tb_arbiter`, `tb_crossbar`, `tb_noc_output_port`, `tb_router_top`, `tb_router_chain` | The full codec: accessors, `with_*`, the `mk_*` constructors, the package's wide `check()` task and the shared `checks`/`errors` counters. |
| `tb_noc_mesh` | The full codec plus `report_stats()` directly - the mesh bench is the one that ends by calling the package's summary task. |
| `tb_noc_input_port` | **Only the counters.** It keeps its own `chk`/`chk4`/`chk_bit`/`chk_vc`/`chk_vec`/`report` helpers (deliberately *not* named `check`) because its checker shape is genuinely different - per-field comparisons against 4-bit expectations - and it prints its own summary. |

The five block benches inline their closing summary (`if (errors == 0)
$display("ALL %0d CHECKS PASSED", checks);`) rather than calling
`report_stats()`, but it reads the same shared counters, so the passing line
is identical either way.

### 3.2 Who does not (2 benches), and why

* **`tb_fifo`** - needs neither the codec nor the reporter: it stores raw
  `WIDTH`-wide words, not formatted flits, and its checker is
  `check(name, bit)`. It keeps its own `check`/`errors`.
* **`tb_route_compute`** - its expectations are 4-bit direction vectors, so
  it keeps a 4-bit local `check`.

This is a deliberate split rather than a shadowed one: a local declaration
would hide the imported name outright, and Verilator says so with `VARHIDDEN`
rather than letting two meanings of `checks` coexist quietly (the corresponding declaration). A bench with a different checker shape does not import this
package; a bench with the standard shape does not get a private copy of
anything.

### 3.3 The two report formats, and how a run is judged

Two summary formats exist on purpose:

* the package's format - `ALL <n> CHECKS PASSED`, or `<err>/<n> CHECKS
  FAILED` - printed by `report_stats()` (`tb_noc_mesh`) or by the five block
  benches' equivalent closing block;
* `tb_fifo` and `tb_noc_input_port`, which do not use the reporter and print
  `Checks : <n>` / `Errors : <n>` / `ALL TESTS PASSED`.

`make regress`'s pass pattern (`PASS_RE := ALL [0-9]+ CHECKS PASSED|ALL TESTS
PASSED`, see `docs/Makefile.md` §3.1) matches both, so a run is judged on
what it prints without the script knowing which bench it is looking at.

Observed final lines of the seven importers (counts are the current suite):

| Bench | Final line |
|---|---|
| `tb_arbiter` | `ALL 84 CHECKS PASSED` |
| `tb_crossbar` | `ALL 286 CHECKS PASSED` |
| `tb_noc_output_port` | `ALL 139 CHECKS PASSED` |
| `tb_router_top` | `ALL 104 CHECKS PASSED` |
| `tb_router_chain` | `ALL 1640 CHECKS PASSED` |
| `tb_noc_mesh` | `ALL 236 CHECKS PASSED` |
| `tb_noc_input_port` | `Checks : 143` / `Errors : 0` / `ALL TESTS PASSED` |
