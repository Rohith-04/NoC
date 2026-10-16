# `noc_mesh` — `rtl/noc_mesh.sv`

A `ROWS`×`COLS` array of `router_top` with every inter-router link resolved in
this file: flit, valid and VC sideband one way, the credit return that pays for
them the other. Nothing but the LOCAL ports reaches the outside — the module
boundary is a *flat packed boundary*, one packed array indexed `[row][col]` per
signal, so the bench driving it never learns how many tiles there are, which
way they face, or how a NORTH output and a SOUTH input relate.

The file is pure SystemVerilog: no generated wrapper, no script, nothing to
regenerate when the geometry changes. The shape that makes that possible is
§2.2–§2.3 — generate-scope locals at the instance endpoints, a fold into
mesh-wide link arrays at constant genvar indices, and an elaboration-time
`generate if` per direction so a boundary tile never even elaborates the index
of a neighbour it does not have. Nothing here makes a decision: routing,
buffering and credit accounting all live inside the tiles
(`docs/rtl/router_top.md`), and what is left in this file is the wiring plus
one assertion block (§2.4, §3.2).

---

## 1. Ports and state

### 1.1 Parameters

| Name | Type | Default | Constraint | Meaning |
|---|---|---|---|---|
| `ROWS` | `int` | 2 | `1..8` (§2.1) | Rows in the array. The row index is the Y coordinate (`CUR_Y = 3'(r)`), and Y grows downward per spec §1. |
| `COLS` | `int` | 2 | `1..8` (§2.1) | Columns; the column index is the X coordinate (`CUR_X = 3'(c)`). |
| `NUM_PORTS` | `int` | 5 | fixed by the 5×5 crossbar | Width of every per-tile port bus, and of the `port` axis on the mesh-wide link arrays. Not a knob, and not checked. |
| `FLIT_W` | `int` | 40 | `>= 16` (§2.1) | Flit width, passed to every tile so the array cannot be built at one width and wired at another. Runs at 40 only (linnea_v2 §1's recorded deviation) but stays a parameter. |
| `NUM_VC` | `int` | 4 | `2`, `4` or `8` (§2.1) | Virtual channels per port; drives `VC_W` everywhere, including the boundary sidebands below. |
| `FIFO_DEPTH` | `int` | 4 | power of two `>= 2` (§2.1) | Neighbour input FIFO depth — also the arbiter's `DIR_CREDITS`, so one number is the buffer and the credit pool that fills it. |
| `LOCAL_CREDITS` | `int` | 4 | not checked | The NI receive buffer depth per VC: the init value of each tile's LOCAL credit counter, i.e. how many flits the bench may have in flight into one tile at once. |

Derived, and declared in the body so the port list above can use it:

```systemverilog
localparam int VC_W = (NUM_VC > 1) ? $clog2(NUM_VC) : 1;
```

That forward reference is the same one `router_top.sv` relies on, and it is
derived rather than stated independently so the boundary sideband can never be
narrower than the index it carries.

Four of the seven parameters are checked, each by an immediate `assert` with a
`$fatal(1, …)` whose message names the parameter and prints the offending
value:

| Check | What it fatals with |
|---|---|
| `ROWS`, `COLS` each in `1..8` | `noc_mesh: ROWS and COLS must each be 1..8 -- the header's DEST_Y/DEST_X are 3 bits, so 8x8 is the largest addressable mesh -- got %0dx%0d` |
| `NUM_VC` in `{2, 4, 8}` | `noc_mesh: NUM_VC must be 2, 4 or 8 so that VC_W = clog2(NUM_VC) addresses it exactly, got %0d` |
| `FLIT_W >= 16` | `noc_mesh: FLIT_W must be at least 16, got %0d` |
| `FIFO_DEPTH` a power of two `>= 2` | `noc_mesh: FIFO_DEPTH must be a power of two >= 2, got %0d` |

The `1..8` bound is not a taste choice: `DEST_Y`/`DEST_X` are three bits wide
(linnea_v2 §3), so a destination further than 7 cannot be named in the header
at all, and a mesh 9 wide or 9 tall would contain a row and a column that no
flit could ever be addressed to. `NUM_VC` is restricted to the three values
whose `$clog2` addresses them exactly. `FIFO_DEPTH` is the bound `fifo`
enforces on itself — restated here so an illegal depth is reported against the
mesh parameter rather than against a FIFO buried four tiles deep.

### 1.2 Port declaration

Direction is from the DUT's point of view. The three boundary groups are flat
packed arrays indexed `[row][col]`; the exact shapes are given verbatim,
because the shape *is* the interface. `VC_W` is 2 at the default `NUM_VC = 4`,
`FLIT_W` is 40.

| Signal | Width | Direction | Source → Destination | Working / description |
|---|---|---|---|---|
| `clk` | 1 | input | bench oscillator → every `router_top`, and → the `walls` block | Single mesh-wide clock. |
| `rst_n` | 1 | input | bench reset → every `router_top`, and → the `walls` guard | Synchronous, active low — matches `router_top.sv`. |
| `inj_data` | `[ROWS-1:0][COLS-1:0][FLIT_W-1:0]` | input | bench → tile `[r][c]`'s LOCAL input | One flit per tile per cycle. This is the source of every tile's LOCAL input: the bench is the network interface on this side of the boundary. |
| `inj_valid` | `[ROWS-1:0][COLS-1:0]` | input | bench → tile `[r][c]`'s LOCAL input | "The flit and VC beside me are real this cycle." |
| `inj_vc` | `[ROWS-1:0][COLS-1:0][VC_W-1:0]` | input | bench → tile `[r][c]`'s LOCAL input | Which of the tile's `NUM_VC` input FIFOs the flit buffers into — link sideband, not a header field. |
| `ej_data` | `[ROWS-1:0][COLS-1:0][FLIT_W-1:0]` | output | tile `[r][c]`'s LOCAL output → bench | Each tile's LOCAL output, verbatim. Which `[row][col]` a flit comes out on **is** the answer to "where did it go", which is why the self-test needs no routing model of its own. |
| `ej_valid` | `[ROWS-1:0][COLS-1:0]` | output | tile → bench | A flit is leaving that tile's network interface this cycle. |
| `ej_vc` | `[ROWS-1:0][COLS-1:0][VC_W-1:0]` | output | tile → bench | The VC the flit was switched onto on the last hop; the bench returns its ejection credit on this VC. |
| `lc_credit` | `[ROWS-1:0][COLS-1:0][NUM_VC-1:0]` | output | tile → bench | The tile freed a slot in its LOCAL input FIFO. This is the bench's injection budget: one per flit it pushed in. |
| `lc_ds_credit` | `[ROWS-1:0][COLS-1:0][NUM_VC-1:0]` | input | bench → tile | The bench is finished with an ejected flit, so the tile's arbiter may spend that LOCAL output slot again. |

The last two are separate ports because they are separate links, in exactly the
same sense as every other direction: credits for what went **in** come back
**from** the tile (`lc_credit`), credits for what came **out** go back **to**
the tile (`lc_ds_credit`). LOCAL is not a special case with one combined wire;
it is the two-link structure of §2.1 with the neighbour replaced by the bench
(§2.5).

### 1.3 Registers and state

**This module holds no datapath registers.** It is pure structural wiring —
continuous assigns, generate-scope locals and one instance array — plus a
single `always_ff` block that writes nothing and only asserts (§3.2). If a flit
is ever stored anywhere in this file's hierarchy, it is inside a `router_top`,
not here. What the module *does* declare:

| Name | Width | Kind | Reset | Working / description |
|---|---|---|---|---|
| `L_out_data` | `[ROWS-1:0][COLS-1:0][NUM_PORTS-1:0][FLIT_W-1:0]` | wire (continuous assign) | follows the tiles | The mesh-wide link arrays: the outward face of every tile, folded from the generate-scope locals below. A neighbour reads these; the bench never does, which is the point of the boundary. |
| `L_out_valid` | `[ROWS-1:0][COLS-1:0][NUM_PORTS-1:0]` | wire (continuous assign) | follows the tiles | Per-port "a flit is on this link this cycle". |
| `L_out_vc` | `[ROWS-1:0][COLS-1:0][NUM_PORTS-1:0][VC_W-1:0]` | wire (continuous assign) | follows the tiles | The VC sideband travelling with each flit. |
| `L_cred_ret` | `[ROWS-1:0][COLS-1:0][NUM_PORTS-1:0][NUM_VC-1:0]` | wire (continuous assign) | follows the tiles | Credit returns produced by each tile's *input* ports, indexed by the port they came in on. |
| `t_in_data`, `t_in_valid`, `t_in_vc`, `t_out_data`, `t_out_valid`, `t_out_vc`, `t_cred_ret`, `t_ds_cred` | `[NUM_PORTS-1:0]…` each, one set per tile | wire (generate-scope local) | follows its drivers | Each tile's five port buses, declared inside `g_row`/`g_col` so the instance endpoints are whole arrays (README "Testbench Wiring Rules"). Listed in §2.2. |
| `PORT_LOCAL` … `PORT_SOUTH` | 1 each (`int`) | localparam | elaboration | 0, 1, 2, 3, 4 — the port indices, matching `router_top`'s table. |
| `walls` | — | `always_ff` (assertion-only) | n/a (gated by `rst_n`) | The only sequential process in the file. It assigns to nothing; it sweeps every tile each posedge and asserts the boundary faces are silent (§3.2). |

---

## 2. RTL explanation

### 2.1 The one rule every link obeys (lines 26–45)

If tile X's output port `o` feeds tile Y's input port `p`, then exactly two
wires join them:

```systemverilog
X.out_flit_*[o]               ->  Y.in_flit_*[p]
Y.credit_return_valid[p]      ->  X.ds_credit_valid[o]
```

The second line is the one that gets inverted by hand: a credit for a slot in
Y's input FIFO travels *back* along the same link, and it is Y — the receiver —
that produces it. Written out for the north direction:

```
tile X (r,c)                             tile Y (r-1,c)

  out_flit_data/valid/vc [NORTH]  ──────────▶  in_flit_data/valid/vc [SOUTH]
  ds_credit_valid        [NORTH]  ◀──────────  credit_return_valid   [SOUTH]
```

Applied uniformly, "the neighbour of this tile through direction D, and that
neighbour's port for this link" gives both halves from one expression, which is
why the four blocks in §2.3 are line-for-line identical apart from the indices:

| D | neighbour | neighbour's port for this link |
|---|---|---|
| NORTH | `(r-1,c)` | SOUTH |
| SOUTH | `(r+1,c)` | NORTH |
| WEST | `(r,c-1)` | EAST |
| EAST | `(r,c+1)` | WEST |

Note that "output port" and "input port" are separate namespaces that share
these five numbers: an EAST output of one tile feeds the WEST input of the next
(spec §1), which is exactly the asymmetry the second line above has to respect.
The indices themselves are the `localparam`s at lines 130–134, identical to
`router_top`'s.

### 2.2 Tile locals, link arrays and the fold (lines 165–188, 303–312)

Three sets of signals, in the order they are built:

1. **Generate-scope tile locals** (lines 181–188) — `t_in_*`, `t_out_*`,
   `t_cred_ret`, `t_ds_cred`, one five-port set per tile, declared inside the
   `g_row`/`g_col` generate scope. They exist because a module instance may
   only be connected to a plain signal or a whole array: an element select used
   as a port endpoint freezes at time 0 and silently drops the stimulus (README
   "Testbench Wiring Rules", and §2.3 of `docs/rtl/router_top.md` for the same
   rule applied five times over).
2. **Mesh-wide link arrays** (lines 165–168) — `L_out_data`, `L_out_valid`,
   `L_out_vc`, `L_cred_ret`, each `[row][col][port]`-indexed. These are the
   outward face of every tile; a neighbour reads them, and the bench never
   does, which is what keeps the boundary flat.
3. **The fold** (lines 303–312) — four continuous assigns per tile, at constant
   genvar indices:

   ```systemverilog
   assign L_out_data[r][c]  = t_out_data;
   assign L_out_valid[r][c] = t_out_valid;
   assign L_out_vc[r][c]    = t_out_vc;
   assign L_cred_ret[r][c]  = t_cred_ret;
   ```

   The whole five-port bus goes in; the LOCAL slice is read by the boundary
   assigns of §2.4 and the four network slices by whichever neighbour exists.

Both endpoints of every assign above are constants fixed at elaboration, so
none of this is a run-time index anywhere.

### 2.3 The four directional links: one rule, elaboration-time `generate if` (lines 205–269)

Each of the four directions is a `generate if`, not a run-time one:

```systemverilog
if (r > 0) begin : g_n
  assign t_in_data[PORT_NORTH]  = L_out_data[r-1][c][PORT_SOUTH];
  assign t_in_valid[PORT_NORTH] = L_out_valid[r-1][c][PORT_SOUTH];
  assign t_in_vc[PORT_NORTH]    = L_out_vc[r-1][c][PORT_SOUTH];
  assign t_ds_cred[PORT_NORTH]  = L_cred_ret[r-1][c][PORT_SOUTH];
end else begin : g_n_tie
  assign t_in_data[PORT_NORTH]  = '0;
  assign t_in_valid[PORT_NORTH] = 1'b0;
  assign t_in_vc[PORT_NORTH]    = '0;
  assign t_ds_cred[PORT_NORTH]  = '0;
end
```

Because the guard is elaboration-time, a boundary tile never elaborates the
index of the neighbour it does not have: `r-1` for `r == 0` is not an
out-of-range constant that later has to be folded away, it is code that does
not exist in the design. The south/west/east blocks (lines 233–243, 246–256,
259–269) are the same four lines with the indices swapped, which is the payoff
of the uniform rule in §2.1.

The `else` arm is the tie, and it is spec §4.6 ("edge-of-mesh ports: tie
incoming `flit_valid` and `ds_credit_valid` to 0") applied at the mesh seam
rather than inside the router: `flit_valid` to `1'b0`, and the data, VC and
credit sidebands to `'0`. The tie is on the **incoming** side only.

### 2.4 What is deliberately *not* tied (lines 48–53, 318–336)

The **outward** link of a boundary tile stays live. Gating it would hide a
routing bug — a `route_compute` that decided a tile at the top edge should go
north would silently produce nothing instead of producing a visible flit on a
link that leads nowhere. Spec §4.6 says the same thing from inside
`router_top`, where the crossbar's selection of an absent port is asserted
rather than prevented (`docs/rtl/router_top.md` §2.4).

That is precisely why something has to be watching the outward face, and it
cannot be the router: the wire only exists up here, at the seam. That watcher
is the `walls` block, §3.2.

### 2.5 LOCAL: the flat boundary is the network interface (lines 190–203)

There is no link arithmetic on the LOCAL direction at all — only the two
credit halves described on the ports:

```systemverilog
assign t_in_data[PORT_LOCAL]  = inj_data[r][c];
assign t_in_valid[PORT_LOCAL] = inj_valid[r][c];
assign t_in_vc[PORT_LOCAL]    = inj_vc[r][c];
assign t_ds_cred[PORT_LOCAL]  = lc_ds_credit[r][c];

assign ej_data[r][c]   = t_out_data[PORT_LOCAL];
assign ej_valid[r][c]  = t_out_valid[PORT_LOCAL];
assign ej_vc[r][c]     = t_out_vc[PORT_LOCAL];
assign lc_credit[r][c] = t_cred_ret[PORT_LOCAL];
```

The bench is this tile's network interface: it injects on `inj_*`, ejects on
`ej_*`, takes the tile's LOCAL input credits out on `lc_credit` and pays for
ejected flits on `lc_ds_credit`. Four wires per tile, in and out, and no
neighbour to index — which is why LOCAL needs no `generate if`.

### 2.6 The tile instance: coordinates and `HAS_*` (lines 271–301)

```systemverilog
router_top #(
    .FLIT_W        (FLIT_W),
    .NUM_VC        (NUM_VC),
    .FIFO_DEPTH    (FIFO_DEPTH),
    .LOCAL_CREDITS (LOCAL_CREDITS),
    .CUR_X         (3'(c)),
    .CUR_Y         (3'(r)),
    .HAS_LOCAL     (1'b1),             // every tile has an NI
    .HAS_NORTH     (r > 0),
    .HAS_EAST      (c < COLS-1),
    .HAS_WEST      (c > 0),
    .HAS_SOUTH     (r < ROWS-1)
) u_tile ( ... );
```

`HAS_*` is the tile's position, folded to a generate constant — and the guards
in §2.3 are the *same expressions*, so the tie-off inside `router_top` and the
tie-off at the mesh seam cannot disagree: they are both functions of the same
`r` and `c`. `HAS_LOCAL` is `1'b1` everywhere because every tile has an NI.

The four data/VC/credit parameters are passed straight through rather than
restated, so the array cannot be built at one depth and wired at another;
`CUR_X`/`CUR_Y` are narrowed to the header's 3-bit coordinate fields, matching
the `1..8` bound in §1.1.

---

## 3. Testing explanation

**Bench:** `tb/tb_noc_mesh.sv`, top module `tb_noc_mesh` (all-to-all
self-test, see `docs/tb/tb_noc_mesh.md`).

### 3.1 How to run it

```
make TOP=noc_mesh sim                    # default 2x2 -> ALL 236 CHECKS PASSED
make TOP=noc_mesh sim ROWS=4 COLS=4      # any geometry; the make variables
                                         # land in GFLAGS as -GROWS/-GCOLS
make TOP=noc_mesh lint                   # clean, full -Wall over rtl/*.sv
```

`make regress` phase 4 repeats the self-test at four more geometries —
`1:2`, `2:1`, `3:3`, `2:3` (Makefile `MESH_GEOMS`) — using the same
`ROWS=`/`COLS=` form so the documented command is the one exercised. 1x1 is
deliberately absent: see §2.3 of the bench doc.

The sim build carries `--assert`, so every `assert property` in `rtl/` is live
for the run, as are this file's own two assertion families: the `walls` block
(§3.2) and the parameter checks (§3.3).

### 3.2 What the `walls` block asserts (lines 337–371)

An `always_ff @(posedge clk)`, guarded by `if (rst_n)`, that loops over every
tile at run time with variable `r`/`c` — which is what lets one block cover
every edge tile of any geometry — and checks the **outward face** of each
absent link (§2.4). Four checks, one per direction, each legal only where the
wall actually is:

| Guard | Property, for every `(r,c)` where it holds | `$error` on failure |
|---|---|---|
| `r == 0` | `!L_out_valid[r][c][PORT_NORTH] && L_out_data[r][c][PORT_NORTH] == '0 && L_out_vc[r][c][PORT_NORTH] == '0 && L_cred_ret[r][c][PORT_NORTH] == '0` | `noc_mesh: tile (%0d,%0d) has no north neighbour but drove or credited its north link` |
| `r == ROWS-1` | the same four terms on `PORT_SOUTH` | `… has no south neighbour but drove or credited its south link` |
| `c == 0` | the same four terms on `PORT_WEST` | `… has no west neighbour but drove or credited its west link` |
| `c == COLS-1` | the same four terms on `PORT_EAST` | `… has no east neighbour but drove or credited its east link` |

Two things about the shape are deliberate:

- **It is the whole wire, not just `valid`.** "There is no link" has to mean
  no flit, no VC sideband and no credit either, or the tie in §2.3 is quietly
  load-bearing somewhere — a `'0` data term with `valid` low looks idle, and a
  credit appearing on a link that does not exist is exactly the phantom the
  seam assertion inside `router_top` (`!HAS_P[p] |-> !(|credit_return_valid[p])`)
  is looking for from the other side.
- **The guards are equality tests against the edges, not `r > 0`-style
  ranges.** On a one-row mesh `r == 0` and `r == ROWS-1` are both true of the
  single row, so both its walls are checked; no special case for the degenerate
  geometries, which `make regress` runs.

### 3.3 The elaboration parameter checks (lines 144–156)

The four `assert`/`$fatal` pairs in §1.1. The file's own comment calls them
elaboration-time, and in a simulation they are immediate assertions in an
`initial` block, so they fire at time 0 — before the first clock edge and
before any tile has run a cycle. Without them a geometry that cannot be
addressed surfaces much later as an index quietly landing outside its array
instead of as the configuration error it is, with the parameter named.

Nothing in `tools/` targets this file: `assert_neg.sh`'s seven cases cover
`fifo`, `noc_input_port`, `arbiter`, `crossbar`, `noc_output_port` and
`router_top`, and the mutation suites do not touch `noc_mesh` either. These
checks are therefore exercised only by building the mesh with a bad parameter,
which is the normal way they are meant to fail: the message is the diagnosis.

### 3.4 What the bench proves about this module

The mesh bench judges the run on exactly two properties — packet integrity and
the correct ejection tile — with deliberately no routing oracle, plus a
per-tile coverage check that every tile ejected something (otherwise a row that
was simply never wired would pass, because the scoreboard only follows packets
that arrive). It also drives a `FIFO_DEPTH + 1`-flit packet per ordered pair,
which is what forces every link in the mesh to round-trip a credit. Full
detail, including where the check count comes from, is in
`docs/tb/tb_noc_mesh.md`.
