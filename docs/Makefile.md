# `Makefile` — `Makefile`

The build front end. One tool (Verilator), four targets (`sim`, `lint`,
`wave`, `clean`), and a single knob — `TOP=` — that selects both the bench
and the object directory.

It is small (72 lines) but almost every line encodes a decision that was
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
| `RTL_DIR` | 1 string | input | `Makefile` → `$(RTL)`, `$(TB)` | Fixed at `rtl`. |
| `TB_DIR` | 1 string | input | `Makefile` → `$(TB_SUPPORT)` | Fixed at `tb`. |
| `SIM_DIR` | 1 string | input | `Makefile` → `wave`, `clean` | Fixed at `sim`. |
| `OBJ_DIR` | 1 string | input | `Makefile` → `VFLAGS`, `sim`, `clean` | Fixed at `obj_dir`. Object directories are per-`TOP` (`obj_dir/v_<TOP>`), so switching benches never rebuilds or clobbers the other. |
| `obj_dir/v_<TOP>/run` | 1 path | output | `$(OBJ_DIR)/v_$(TOP)/run` rule → `sim` target | The compiled simulation binary. Named `run` (via `-o run`) so the path is uniform across benches. |
| `sim/<TOP>.vcd` | 1 path | output | `$dumpfile` inside the bench → `wave` target | Written only when the bench is run with `+vcd`. |
| `obj_dir/`, `sim/*.vcd` | 1 path each | output | `clean` target → — | Removed wholesale. |

`TOP` is the only input meant to be set on the command line; the other four
are `:=` constants.

### 1.2 Registers and state

There is no sequential state. These are the variables every rule is written
against — the equivalent of a module's declarations.

| Name | Width | Kind | Reset | Working / description |
|---|---|---|---|---|
| `VFLAGS` | 1 string | `:=` variable | set once, at parse time | `--binary --timing --trace --assert -Wall -Wno-BLKSEQ -Wno-WIDTHEXPAND -sv --top-module tb_$(TOP) -Mdir $(OBJ_DIR)/v_$(TOP) -o run` — the complete Verilator command. Every flag is justified in the block comment above it in the file; see §2.1. |
| `RTL` | 7 files | `:=` variable (list) | `$(wildcard rtl/*.sv)` | **All** RTL, always, for every target. A single-top lint and a bench build see the same file set, so a file that lints can never be missing from a build. Order does not matter to Verilator (it elaborates from the top), but `files.f` records the spec's §10 dependency order for tools that do care. |
| `TB_SUPPORT` | 1 file | `:=` variable (list) | everything in `tb/*.sv` **except** `tb_%.sv` | Support modules (currently `tb/mock_arbiter.sv`). Filtered by pattern rather than listed, so adding a driver or a scoreboard requires no Makefile edit. |
| `TB` | 2 files | `:=` variable (list) | `tb/tb_$(TOP).sv` + `$(TB_SUPPORT)` | Exactly one bench, plus support. Two benches are never compiled together — each declares its own clock, its own `$finish`, and its own `main`. |
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
| `-Wno-WIDTHEXPAND` | The benches pass signals of every width (2, 4, 5, 10 bits) into one 32-bit `check(what, actual, expected)` task. Every one of those is a deliberate zero-extension into the checker, so the warning fires on correct code at every call site. Same waiver policy as `BLKSEQ`. |
| `-sv` | SystemVerilog parsing. |
| `--top-module tb_$(TOP)` | Derives the top from `TOP`, so the bench file name, the top module name and the object directory can never disagree. |
| `-Mdir $(OBJ_DIR)/v_$(TOP)` | Per-bench object directory — switching `TOP` does not trigger a rebuild of anything else. |
| `-o run` | Uniform binary name. |

### 2.2 The four targets

**`sim`** — depends on the binary, then runs it:

```make
sim: $(OBJ_DIR)/v_$(TOP)/run
	./$(OBJ_DIR)/v_$(TOP)/run
```

`$(RTL) $(TB)` are on the binary's prerequisite line, so an edit to *any*
RTL file or to the selected bench (or its support modules) rebuilds. A
change to a *different* bench does not.

**`lint`** — a separate one-liner, not derived from `VFLAGS`:

```make
lint:
	verilator --lint-only --timing --assert -Wall -sv --top-module $(TOP) $(RTL)
```

Two deliberate differences from `sim`:

- `--lint-only` — no code generation, no object directory, much faster.
- **No `-Wno-*` waivers.** Lint runs against the RTL with everything on.
  This is the gate: all seven RTL tops are kept clean under `-Wall`, so the
  waivers above can never hide a real RTL defect.
- `TOP` here names an **RTL module**, not a bench. `make TOP=router_chain
  lint` therefore fails with *"Specified --top-module 'router_chain' was not
  found in design"* — correct behaviour, since `router_chain` is a bench-only
  top with no RTL of that name. Lint targets: `fifo`, `route_compute`,
  `noc_input_port`, `arbiter`, `crossbar`, `noc_output_port`, `router_top`.

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

### 2.3 Why Verilator is the single tool

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

# The whole suite
for t in fifo route_compute noc_input_port arbiter crossbar noc_output_port \
         router_top router_chain; do make TOP=$t sim; done

# Lint every RTL top
for m in fifo route_compute noc_input_port arbiter crossbar \
         noc_output_port router_top; do make TOP=$m lint; done

# Waveform
make TOP=router_top sim        # then re-run with +vcd
make TOP=router_top wave
```

Observed results (all green at time of writing):

| `TOP` | Result line | Checks |
|---|---|---|
| `fifo` | `Checks : 953 / Errors : 0 / ALL TESTS PASSED` | 953 |
| `route_compute` | `ALL 49178 CHECKS PASSED` | 49 178 |
| `noc_input_port` | `Checks : 139 / Errors : 0 / ALL TESTS PASSED` | 139 |
| `arbiter` | `ALL 83 CHECKS PASSED` | 83 |
| `crossbar` | `ALL 286 CHECKS PASSED` | 286 |
| `noc_output_port` | `ALL 139 CHECKS PASSED` | 139 |
| `router_top` | `ALL 108 CHECKS PASSED` | 108 |
| `router_chain` | `ALL 477 CHECKS PASSED` | 477 |

The two report formats differ because the benches were written at different
times; both set `Errors : 0` and both exit non-zero on failure, so a script
can key off either.

### 3.2 What `make` does *not* do

These are all in `tools/` rather than in `make`, deliberately — they mutate
the RTL, so they must never be reachable from a bare `make`:

| Command | Purpose |
|---|---|
| `bash tools/mutate_all.sh` | 6 mutations of the RTL, rebuilt **without** `--assert`, proving the **benches** catch them. Restores its backup after each case. |
| `bash tools/mutate_out.sh` | 2 further mutations of the output-port header merge, same discipline. |
| `bash tools/assert_neg.sh` | 6 mutations, one per assertion family, rebuilt **with** `--assert`, proving the **assertions** actually fire. Also restores, and traps `EXIT` so `git diff rtl/` stays clean even if a case is interrupted. |

Running all three must leave `git diff --stat rtl/` showing only the intended
`noc_input_port.sv` change; that is a checked invariant of the flow.

### 3.3 Gotchas the Makefile encodes

- **Never run the binaries directly through a bare redirect.** stdout to a
  file is block-buffered — always use `stdbuf -oL -eL ./obj_dir/v_<TOP>/run`
  when diagnosing a hang, or `timeout` will kill the process without
  flushing and the log will end mid-thought.
- **`-Mdir` is per-`TOP`.** Two terminals can build different benches
  concurrently; two building the *same* bench share a directory and will
  fight. Remove `obj_dir/v_<TOP>` before a concurrent run of one top.
- **`lint` and `sim` have different warning policies** (§2.2). A bench build
  passing is not evidence that lint passes, and vice versa — run both.
