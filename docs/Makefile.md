# `Makefile` — `Makefile`

The build front end. One tool (Verilator), five targets (`sim`, `lint`,
`regress`, `wave`, `clean`), and two knobs — `TOP=` selects the bench (or
the lint top) and the object directory, `GFLAGS=` overrides RTL/bench
parameters, with `ROWS=`/`COLS=` feeding the mesh geometry.

It is small (235 lines) but almost every line encodes a decision that was
paid for during development, so this document explains each one rather than
listing the rules.

---

## 1. Ports and state

A Makefile declares no module ports. "Ports" here means the **build
interface** — what the build accepts and what it emits — and "state" means the
variables the rules are written against.

Direction is from the build's point of view: `input` = supplied by the user
or the repository, `output` = produced by a rule.

### 1.1 Port declaration (build inputs and outputs)

| Signal | Width | Direction | Source → Destination | Working / description |
|---|---|---|---|---|
| `TOP` | 1 string | input | command line → every target | Selects *what* to build. For `sim`/`wave` it must name a bench: `tb/tb_<TOP>.sv` with top module `tb_<TOP>`. For `lint` it must name an RTL top: a module declared in `rtl/*.sv`. Defaults to empty; `sim` with an empty `TOP` fails on `--top-module tb_`, which is deliberate — there is no "build everything" default, because a wrong default silently builds the wrong bench. |
| `GFLAGS` | 1 string | input | command line → `sim`, `lint` → the Verilator line | Optional parameter overrides, e.g. `GFLAGS='-GNUM_VC=2'`. `-G` only reaches parameters of the compilation top, which is why every knob a test wants to sweep is declared `parameter` in the bench (not `localparam`) and passed straight through to the DUT instance. Also carried into the rebuild stamp (§2.3), so changing it forces a rebuild. |
| `ROWS`, `COLS` | 2 strings | input | command line → `override GFLAGS += -GROWS=… / -GCOLS=…` | Mesh geometry: `make TOP=noc_mesh sim ROWS=4 COLS=4`. Appended to `GFLAGS` with `override` rather than a plain `+=`: a variable set on the command line ignores ordinary makefile assignments, and `GFLAGS` is routinely set on the command line for the parameter matrix — without `override`, giving both would silently drop the geometry. Empty by default, and then nothing is appended. |
| `RTL_DIR` | 1 string | input | `Makefile` → `$(RTL)`, `$(TB)` | Fixed at `rtl`. |
| `TB_DIR` | 1 string | input | `Makefile` → `$(TB_SUPPORT)` | Fixed at `tb`. |
| `SIM_DIR` | 1 string | input | `Makefile` → `wave`, `clean` | Fixed at `sim`. |
| `OBJ_DIR` | 1 string | input | `Makefile` → `VFLAGS`, `sim`, `clean` | Fixed at `obj_dir`. Object directories are per-`TOP` (`obj_dir/v_<TOP>`), so switching benches never rebuilds or clobbers the other. |
| `obj_dir/v_<TOP>/run` | 1 path | output | `$(OBJ_DIR)/v_$(TOP)/run` rule → `sim` target | The compiled simulation binary. Named `run` (via `-o run`) so the path is uniform across benches. |
| `obj_dir/v_<TOP>/.cfg` | 1 path | output | `$(CFG_STAMP)` rule → the binary rule's prerequisites | Rebuild stamp: the current `$(GFLAGS)` written to a file, rewritten only when its content actually changes. This is what makes a second run with different `-G` values rebuild instead of linking against the first run's objects (§2.3). |
| `sim/<TOP>.vcd` | 1 path | output | `$dumpfile` inside the bench → `wave` target | Written only when the bench is run with `+vcd`. |
| `obj_dir/`, `sim/*.vcd` | 1 path each | output | `clean` target → — | Removed wholesale. |

`TOP`, `GFLAGS`, `ROWS` and `COLS` are the inputs meant to be set on the
command line; the four directory variables are `:=` constants.

### 1.2 Registers and state

There is no sequential state. These are the variables every rule is written
against — the equivalent of a module's declarations.

| Name | Width | Kind | Reset | Working / description |
|---|---|---|---|---|
| `VFLAGS` | 1 string | `:=` variable | set once, at parse time | `--binary --timing --trace --assert -Wall -Wno-BLKSEQ -Wno-WIDTHEXPAND -sv --top-module tb_$(TOP) -Mdir $(OBJ_DIR)/v_$(TOP) -o run` — the complete Verilator command. Every flag is justified in the block comment above it in the file; see §2.1. |
| `RTL` | 8 files | `:=` variable (list) | `$(wildcard rtl/*.sv)` | **All** RTL, always, for every target. A single-top lint and a bench build see the same file set, so a file that lints can never be missing from a build. Order does not matter to Verilator (it elaborates from the top), but `files.f` records the spec's §10 dependency order for tools that do care. |
| `PKG` | 1 file | `:=` variable (constant) | `tb/noc_tb_pkg.sv` | The flit codec / shared reporter package, forced to the head of `TB`. A package has to exist before anything can import it, and `wildcard` order is filesystem-dependent — see `docs/tb/noc_tb_pkg.md` §2.3, and the `TB` row below. |
| `TB_SUPPORT` | 1 file | `:=` variable (list) | everything in `tb/*.sv` **except** `tb_%.sv` and `$(PKG)` | Support modules (currently `tb/mock_arbiter.sv`). Filtered by pattern rather than listed, so adding a driver or a scoreboard requires no Makefile edit. |
| `TB` | 3 files | `:=` variable (list) | `$(PKG)` + `tb/tb_$(TOP).sv` + `$(TB_SUPPORT)` | The package first, then exactly one bench, then support. Two benches are never compiled together — each declares its own clock, its own `$finish`, and its own `main`. |
| `CFG_STAMP` | 1 path | `:=` variable | `$(OBJ_DIR)/v_$(TOP)/.cfg` | The rebuild stamp's path (§2.3). Written by the `FORCE`-driven `$(CFG_STAMP)` rule, which compares before renaming so an unchanged configuration still rebuilds nothing. |
| `BENCHES` | 9 names | `:=` variable (list) | phase 1 of `regress` | Every bench, in build order: `fifo route_compute noc_input_port arbiter crossbar noc_output_port router_top router_chain noc_mesh`. |
| `RTL_TOPS` | 8 names | `:=` variable (list) | phase 2 of `regress` | Every RTL module usable as a lint top — the eight modules of `rtl/*.sv`, `noc_mesh` included. Bench-only tops (`router_chain`, every `tb_*`) are not here. |
| `NUM_VC_BENCHES` | 6 names | `:=` variable (list) | phase 3 of `regress` | The benches that declare a `NUM_VC` parameter: `arbiter noc_input_port noc_output_port router_chain router_top noc_mesh`. |
| `DEPTH_BENCHES` | 6 names | `:=` variable (list) | phase 3 of `regress` | The benches that declare a `FIFO_DEPTH` parameter: `arbiter fifo noc_input_port router_chain router_top noc_mesh`. Per-bench lists rather than one global `-G` is the point — see §2.3. |
| `MESH_GEOMS` | 4 geometries | `:=` variable (list) | phase 4 of `regress` | `1:2 2:1 3:3 2:3` — the shapes worth running beyond the default 2×2: 1×2 and 2×1 each exercise two of the mesh's four walls and the links the other one ties off; 3×3 is the smallest geometry with an interior tile that has four neighbours; 2×3 is the smallest that is neither square nor a single-tile-wide corridor. 1×1 is deliberately absent — see `tb_noc_mesh`'s `N_TILES` check. |
| `PASS_RE` | 1 regex | `:=` variable | phases 1, 3, 4 of `regress` | `ALL [0-9]+ CHECKS PASSED\|ALL TESTS PASSED` — what a passing run prints. The alternation exists because `tb_fifo` and `tb_noc_input_port` print `ALL TESTS PASSED` rather than a check count (§3.1). |
| `VFLAGS` waivers | — | `make` targets | `sim` wields them, `lint` does not | `BLKSEQ` and `WIDTHEXPAND` are waived for bench compiles only. See §2.2 for why lint deliberately does not inherit them. |

---

## 2. RTL explanation (how the build works)

### 2.1 `VFLAGS` — one command, every decision documented in place

```make
VFLAGS := --binary --timing --trace --assert -Wall -Wno-BLKSEQ -Wno-WIDTHEXPAND -sv \
          --top-module tb_$(TOP) -Mdir $(OBJ_DIR)/v_$(TOP) -o run
```

| Flag | Why |
|---|---|
| `--binary` | Build a directly runnable executable in one step (no separate `--cc` + `--exe` + `make`). |
| `--timing` | Enables timing controls (`#delay`, `@`, `wait`) — mandatory for any testbench. Without it `#5` does not parse. |
| `--trace` | Makes `$dumpfile`/`$dumpvars` actually emit a VCD. The flags are present on *every* build rather than only under `wave`, so a re-run with `+vcd` never needs a rebuild to change behaviour. |
| `--assert` | **The single most important flag here.** Without it Verilator parses `assert property` and then silently drops it — no warning, no error, assertions simply never run. This was verified explicitly rather than assumed, which is why it is also present in the `lint` recipe. |
| `-Wall` | Everything on. |
| `-Wno-BLKSEQ` | BLKSEQ is a *synthesizable RTL* style rule (no blocking assignments in clocked processes). Testbenches are procedural by nature and the universal clock idiom `always #p clk = ~clk` trips it. **Waived for bench compiles only** — `make lint` still runs full `-Wall` against the RTL, which is where the rule matters. |
| `-Wno-WIDTHEXPAND` | The benches pass signals of every width (flit, route, VC index, per-VC vector) into one `FLIT_W`-wide `check(what, actual, expected)` task — the shared checker in `tb/noc_tb_pkg.sv`. Every one of those is a deliberate zero-extension into the checker, so the warning fires on correct code at every call site. Same waiver policy as `BLKSEQ`. |
| `-sv` | SystemVerilog parsing. |
| `--top-module tb_$(TOP)` | Derives the top from `TOP`, so the bench file name, the top module name and the object directory can never disagree. |
| `-Mdir $(OBJ_DIR)/v_$(TOP)` | Per-bench object directory — switching `TOP` does not trigger a rebuild of anything else. |
| `-o run` | Uniform binary name. |

### 2.2 The five targets

**`sim`** — depends on the binary, then runs it:

```make
sim: $(OBJ_DIR)/v_$(TOP)/run
	./$(OBJ_DIR)/v_$(TOP)/run
```

`$(RTL) $(TB)` are on the binary's prerequisite line, so an edit to *any*
RTL file or to the selected bench (or its support modules) rebuilds. A
change to a *different* bench does not. The third prerequisite,
`$(CFG_STAMP)`, is what makes a changed `$(GFLAGS)` rebuild too (§2.3), and
the build line itself now passes `$(GFLAGS)` to Verilator.

**`lint`** — a separate one-liner, not derived from `VFLAGS`:

```make
lint:
	verilator --lint-only --timing --assert -Wall -sv --top-module $(TOP) $(GFLAGS) $(RTL)
```

Two deliberate differences from `sim`:

- `--lint-only` — no code generation, no object directory, much faster.
- **No `-Wno-*` waivers.** Lint runs against the RTL with everything on.
  This is the gate: all eight RTL tops are kept clean under `-Wall`, so the
  waivers above can never hide a real RTL defect. `$(RTL)` is the whole RTL
  set and nothing from `tb/` — the package's `UNUSEDPARAM`/`UNUSEDSIGNAL`
  waiver is scoped to its own file and lint deliberately never sees it.
- `TOP` here names an **RTL module**, not a bench. `make TOP=router_chain
  lint` therefore fails with *"Specified --top-module 'router_chain' was not
  found in design"* — correct behaviour, since `router_chain` is a bench-only
  top with no RTL of that name. Lint targets: `fifo`, `route_compute`,
  `crossbar`, `arbiter`, `noc_input_port`, `noc_output_port`, `router_top`,
  `noc_mesh`.

**`regress`** — the whole suite in one invocation, four phases and 45 runs:

1. every bench in `$(BENCHES)` at its default parameters (9 runs);
2. `lint` with each of the 8 modules in `$(RTL_TOPS)` as the top;
3. the parameter matrix — `NUM_VC` ∈ {2, 8} over `$(NUM_VC_BENCHES)` and
   `FIFO_DEPTH` ∈ {4, 8} over `$(DEPTH_BENCHES)` (24 runs);
4. `noc_mesh` at the four geometries of `$(MESH_GEOMS)`, via the documented
   `ROWS=`/`COLS=` form rather than raw `-G` (4 runs).

Each run's output is grepped against `$(PASS_RE)`; a failure prints the
first `%Error`/`FAIL` lines indented under the run's name, the tally is
summed at the end, and the target **exits non-zero on any failure**, so it
can be wired to CI as-is. The per-bench knob lists of phase 3 are the whole
reason they exist: `-G` only reaches parameters the compilation top
actually declares, and Verilator rejects a `-G` naming one that is not
there — `tb_noc_output_port` declares no `FIFO_DEPTH` (its DUT has no
buffer), `tb_crossbar` and `tb_route_compute` declare neither knob. One
global `GFLAGS` for the suite would fail on three of the nine benches for a
reason that has nothing to do with the RTL. The deeper suites are
deliberately **not** folded in — `tools/assert_neg.sh` and
`tools/mutate_*.sh` mutate RTL source in place, are slow, and touch the
tree, so they stay separate invocations (§3.2).

**`wave`** — opens the VCD for the current `TOP`:

```make
wave:
	gtkwave $(SIM_DIR)/$(TOP).vcd &
```

The bench only writes a VCD when run with `+vcd`, so the normal sequence is
`make TOP=<x> sim` → re-run with `+vcd` → `make TOP=<x> wave`.

**`clean`** — removes `obj_dir` and the VCD/VVP files under `sim`. It does
not remove `sim/` itself (the directory is recreated by the build rule) and
it does not touch sources.

### 2.3 Parameter overrides and the rebuild stamp

Two mechanisms exist so that a parameter sweep cannot report a stale result:

- **`GFLAGS` reaches the tool, and nothing else.** The compiled binary lives
  at `obj_dir/v_$(TOP)/run` — a path that does not depend on `GFLAGS` — so
  without extra care a second run with a different `-G` would link against
  the first run's object directory and report the first configuration's
  result. The fix is `CFG_STAMP`: a `FORCE`-driven rule writes the current
  `$(GFLAGS)` to `obj_dir/v_<TOP>/.cfg`, compares before renaming so the
  file only changes when its content changes, and the binary rule depends on
  it. Changed flags → changed stamp → rebuild; unchanged configuration →
  unchanged stamp → nothing rebuilds.
- **`ROWS=`/`COLS=` land in `GFLAGS` via `override`.** A variable set on the
  command line ignores ordinary makefile assignments, and `GFLAGS` is
  routinely set on the command line (the parameter matrix, ad-hoc sweeps) —
  so a plain `+=` would silently drop the geometry the moment both were
  given. `override GFLAGS += -GROWS=$(ROWS)` cannot be ignored. Because they
  end up in `GFLAGS`, the stamp sees them too: changing the mesh geometry
  rebuilds.

### 2.4 Why Verilator is the single tool

The comment block at the top of the file states the rationale: it parses
full SVA (the RTL uses `assert property`), it *is* the linter, and its
language subset matches what VCS will accept later when this becomes a UVM
environment. One tool, no per-simulator code paths in the RTL.

The corollary is enforced in the repository: there is **no** Icarus/iverilog
support anywhere — no `.sh` wrapper, no `+define`, no alternate target. The
language limits that forced this choice (`|-> ##1` unsupported → `|=>`;
no `##[n:m]`; no `inside {…}` in assertions; no `'{…}` as an argument; no
arrays of queues) are recorded in `README.md` under *Verilator Language
Limits Hit Here*, with the VCS-compatible form of each.

---

## 3. Testing explanation

The Makefile has no testbench of its own; it is the thing that runs them.

### 3.1 How to run everything

```bash
# One bench
make TOP=router_chain sim

# One bench with a parameter override
make TOP=arbiter sim GFLAGS='-GNUM_VC=2'

# The mesh at a different geometry
make TOP=noc_mesh sim ROWS=4 COLS=4

# Everything: nine benches, per-top lint, the parameter matrix, four mesh
# geometries -- 45 runs, non-zero exit on any failure (§2.2)
make regress

# Waveform
make TOP=router_top sim        # then re-run with +vcd
make TOP=router_top wave
```

Observed results (all green at time of writing):

| `TOP` | Result line | Checks |
|---|---|---|
| `fifo` | `Checks : 879 / Errors : 0 / ALL TESTS PASSED` | 879 |
| `route_compute` | `ALL 49178 CHECKS PASSED` | 49 178 |
| `noc_input_port` | `Checks : 143 / Errors : 0 / ALL TESTS PASSED` | 143 |
| `arbiter` | `ALL 84 CHECKS PASSED` | 84 |
| `crossbar` | `ALL 286 CHECKS PASSED` | 286 |
| `noc_output_port` | `ALL 139 CHECKS PASSED` | 139 |
| `router_top` | `ALL 104 CHECKS PASSED` | 104 |
| `router_chain` | `ALL 477 CHECKS PASSED` | 477 |
| `noc_mesh` | `ALL 236 CHECKS PASSED` | 236 |

Seven of the nine report through `tb/noc_tb_pkg`'s shared reporter, which
prints `ALL <n> CHECKS PASSED`. `tb_fifo` and `tb_noc_input_port` do not use
it and print `Checks : <n>` / `Errors : <n>` / `ALL TESTS PASSED` instead —
deliberately, because their checker shapes are different (see
`docs/tb/noc_tb_pkg.md` §3.2). Both formats set `Errors : 0` on success and
both exit non-zero on failure, and `$(PASS_RE)` matches either, so a script
can key off whichever it gets.

### 3.2 What `make` does *not* do

These are all in `tools/` rather than in `make`, deliberately — they mutate
the RTL, so they must never be reachable from a bare `make`:

| Command | Purpose |
|---|---|
| `bash tools/mutate_all.sh` | 6 mutations of the RTL, rebuilt **without** `--assert`, proving the **benches** catch them — all 6 killed. Restores its backup after each case. |
| `bash tools/mutate_out.sh` | 2 further mutations of the output-port header merge, same discipline — both killed. |
| `bash tools/assert_neg.sh` | 7 mutations, one per assertion family, rebuilt **with** `--assert`, proving the **assertions** actually fire — all 7 FIRED. Also restores, and traps `EXIT` so `git diff rtl/` stays clean even if a case is interrupted. |

All three put `tb/noc_tb_pkg.sv` first in their Verilator file list, for the
same reason the Makefile does (§1.2 and the package's own doc): a package
has to exist before anything can import it.

Running all three must leave `git diff --stat rtl/` exactly as it was before
they ran — each script backs up, mutates, restores, and its `EXIT` trap
makes an interrupted case leave the tree clean too. That is a checked
invariant of the flow.

### 3.3 Gotchas the Makefile encodes

- **Never run the binaries directly through a bare redirect.** stdout to a
  file is block-buffered — always use `stdbuf -oL -eL ./obj_dir/v_<TOP>/run`
  when diagnosing a hang, or `timeout` will kill the process without
  flushing and the log will end mid-thought.
- **`-Mdir` is per-`TOP`.** Two terminals can build different benches
  concurrently; two building the *same* bench share a directory and will
  fight. Remove `obj_dir/v_<TOP>` before a concurrent run of one top. The
  rebuild stamp `.cfg` lives in the same directory, so deleting
  `obj_dir/v_<TOP>` drops both the objects and the stamp — the safe reset
  when a build looks inexplicably stale.
- **`lint` and `sim` have different warning policies** (§2.2). A bench build
  passing is not evidence that lint passes, and vice versa — run both.
