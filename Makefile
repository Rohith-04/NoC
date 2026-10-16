# ---- Config ----
TOP      ?=
# Optional parameter overrides, e.g.
#   make TOP=arbiter sim   GFLAGS='-GNUM_VC=2'
#   make TOP=router_top sim GFLAGS='-GNUM_VC=8 -GFIFO_DEPTH=4'
# -G only reaches parameters of the compilation top, which is why every
# knob a test wants to sweep is declared `parameter` in the bench (not
# `localparam`) and passed straight through to the DUT instance.
GFLAGS   ?=
# Mesh geometry: `make TOP=noc_mesh sim ROWS=4 COLS=4`.
#
# The mesh is the one bench whose *shape* is a test choice -- 2x2 first, and
# then the same command with different numbers reruns the whole self-test on
# a different array -- so it gets its own make variables rather than being
# spelled as -G by hand. They land in GFLAGS, which is also what the rebuild
# stamp below hashes, so changing the geometry rebuilds.
#
# `override` rather than a plain `+=`: a variable set on the command line
# ignores ordinary makefile assignments, and GFLAGS is routinely set on the
# command line for the parameter matrix -- without this, giving both would
# silently drop the geometry.
ROWS    ?=
COLS    ?=
ifneq ($(strip $(ROWS)),)
override GFLAGS += -GROWS=$(ROWS)
endif
ifneq ($(strip $(COLS)),)
override GFLAGS += -GCOLS=$(COLS)
endif
RTL_DIR  := rtl
TB_DIR   := tb
SIM_DIR  := sim
OBJ_DIR  := obj_dir

# ---------------------------------------------------------------------------
# Toolchain: Verilator for everything -- simulation, assertions and lint.
#
#   make TOP=<tb> sim          build + run a testbench
#   make TOP=<tb> sim GFLAGS=...  same, with RTL/bench parameters overridden
#   make TOP=<rtl-module> lint lint the whole RTL set against one top
#   make regress               every bench + lint + the parameter matrix
#   make TOP=<tb> wave         open the VCD in gtkwave
#   make clean
#
# Verilator is the single flow on purpose: it parses full SVA (the RTL uses
# `assert property`), it is the linter, and its language subset matches what
# VCS will accept later when this becomes a UVM environment. One tool, no
# per-simulator code paths in the RTL.
# ---------------------------------------------------------------------------

# --trace is needed for $dumpfile/$dumpvars to actually emit a VCD.
#
# -Wno-BLKSEQ: BLKSEQ is a *synthesizable RTL* style rule (no blocking
#   assignments in clocked processes). Testbenches are procedural by nature
#   and the universal clock idiom `always #p clk = ~clk` trips it. Waived for
#   bench compiles only -- `make lint` still runs full -Wall against the RTL,
#   which is where the rule matters.
#
# --assert: without this flag Verilator parses `assert property` and then
#   silently drops it -- no warning, no error, assertions simply never run.
#   Verified explicitly rather than assumed. Enables every SVA block in the
#   RTL and in the benches.
#
# -Wno-WIDTHEXPAND: the benches pass signals of every width (flit, route,
#   VC index, per-VC vector) into one FLIT_W-wide `check(what, actual,
#   expected)` task. Every one of
#   those is a deliberate zero-extension into the checker, so the warning
#   fires on correct code at every call site. Waived for bench compiles only,
#   for the same reason as BLKSEQ: `make lint` still runs full -Wall on the
#   RTL, where an unexpected expansion is a real defect.
VFLAGS := --binary --timing --trace --assert -Wall -Wno-BLKSEQ -Wno-WIDTHEXPAND -sv \
          --top-module tb_$(TOP) -Mdir $(OBJ_DIR)/v_$(TOP) -o run

RTL := $(wildcard $(RTL_DIR)/*.sv)

# Everything in tb/ that is NOT a testbench top (tb_*.sv) is a support
# module -- mock arbiter, scoreboards, drivers -- and is compiled alongside
# whichever bench is selected.
#
# The package is forced to the head of the list. A package has to exist
# before anything can import it, and `wildcard` returns names in whatever
# order the filesystem feels like, so leaving it to chance would fail on a
# fresh checkout and work on a machine that happened to sort differently.
PKG        := $(TB_DIR)/noc_tb_pkg.sv
TB_SUPPORT := $(filter-out $(TB_DIR)/tb_%.sv $(PKG), $(wildcard $(TB_DIR)/*.sv))
TB         := $(PKG) $(TB_DIR)/tb_$(TOP).sv $(TB_SUPPORT)

.PHONY: sim lint regress wave clean

# ---- Simulation ----
sim: $(OBJ_DIR)/v_$(TOP)/run
	./$(OBJ_DIR)/v_$(TOP)/run

# Rebuild when the parameter overrides change.
#
# The compiled binary lives at a path that does not depend on GFLAGS, so
# without this a second run with a different -G would link against the first
# run's object directory and report the old configuration's result -- the
# exact failure a parameter sweep must not have. The stamp is rewritten only
# when its content actually changes, so an unchanged configuration still
# rebuilds nothing.
.PHONY: FORCE
FORCE:

CFG_STAMP := $(OBJ_DIR)/v_$(TOP)/.cfg

$(CFG_STAMP): FORCE
	@mkdir -p $(OBJ_DIR)/v_$(TOP)
	@echo '$(GFLAGS)' > $(CFG_STAMP).tmp
	@if ! cmp -s $(CFG_STAMP).tmp $(CFG_STAMP); then \
	   mv $(CFG_STAMP).tmp $(CFG_STAMP); \
	 else \
	   rm -f $(CFG_STAMP).tmp; \
	 fi

$(OBJ_DIR)/v_$(TOP)/run: $(RTL) $(TB) $(CFG_STAMP)
	@mkdir -p $(OBJ_DIR)/v_$(TOP) $(SIM_DIR)
	verilator $(VFLAGS) $(GFLAGS) $(RTL) $(TB)

# ---- Lint the whole RTL set against one top ----
lint:
	verilator --lint-only --timing --assert -Wall -sv --top-module $(TOP) $(GFLAGS) $(RTL)

# ---- Regression ------------------------------------------------------------
#   make regress
#
# Four phases, all deterministic, and none of them rewrites a source file:
#
#   1. every bench at its default parameters
#   2. `lint` with each RTL module as the top
#   3. the parameter matrix -- NUM_VC in {2,8} and FIFO_DEPTH in {4,8}
#   4. the mesh at four geometries beyond the default 2x2
#
# Phase 3's knob lists are PER BENCH, and that is the whole reason they exist.
# -G only reaches parameters the compilation top actually declares, and
# Verilator rejects a -G naming one that is not there: tb_noc_output_port
# declares no FIFO_DEPTH (its DUT has no buffer), tb_crossbar and
# tb_route_compute declare neither knob. A single global -GFLAGS for the suite
# would fail on three of the nine benches for a reason that has nothing to do
# with the RTL. Phase 4 uses the ROWS=/COLS= make variables rather than -G so
# that the documented `make TOP=noc_mesh sim ROWS=4 COLS=4` form is what gets
# exercised.
#
# The deeper suites are deliberately NOT folded in here. tools/assert_neg.sh
# and tools/mutate_*.sh mutate RTL source in place to prove an assertion can
# fire; they restore it, but they are slow and they touch the tree, so they
# stay separate invocations.
#
# Exits non-zero on any failure, so this can be wired to CI as-is.
BENCHES        := fifo route_compute noc_input_port arbiter crossbar noc_output_port router_top router_chain noc_mesh
RTL_TOPS       := fifo route_compute crossbar arbiter noc_input_port noc_output_port router_top noc_mesh
NUM_VC_BENCHES := arbiter noc_input_port noc_output_port router_chain router_top noc_mesh
DEPTH_BENCHES  := arbiter fifo noc_input_port router_chain router_top noc_mesh
# Mesh geometries worth running beyond the default 2x2 in phase 1. 1x2 and
# 2x1 are not the same test: one leaves every tile without north/south
# links, the other without east/west, so each exercises two of noc_mesh's
# four walls and the links the other one ties off. 3x3 is the smallest
# geometry with an interior tile that has four neighbours, and 2x3 is the
# smallest that is neither square nor a single-tile-wide corridor.
# 1x1 is deliberately absent -- see tb_noc_mesh's N_TILES check.
MESH_GEOMS     := 1:2 2:1 3:3 2:3

# What a passing run prints. tb_fifo and tb_noc_input_port report "ALL TESTS
# PASSED" rather than a check count, hence the alternation.
PASS_RE := ALL [0-9]+ CHECKS PASSED|ALL TESTS PASSED

regress:
	@fail=0; ok=0; \
	echo "== 1. benches at default parameters =="; \
	for t in $(BENCHES); do \
	  out=$$($(MAKE) --no-print-directory TOP=$$t sim 2>&1); \
	  if echo "$$out" | grep -qE '$(PASS_RE)'; then \
	    res=$$(echo "$$out" | grep -oE '$(PASS_RE)' | tail -1); \
	    printf '  ok   %-18s %s\n' "$$t" "$$res"; ok=$$((ok+1)); \
	  else \
	    printf '  FAIL %-18s\n' "$$t"; \
	    echo "$$out" | grep -E '%Error|FAIL' | head -5 | sed 's/^/         /'; \
	    fail=$$((fail+1)); \
	  fi; \
	done; \
	echo "== 2. lint, one RTL module per top =="; \
	for t in $(RTL_TOPS); do \
	  if $(MAKE) --no-print-directory TOP=$$t lint >/dev/null 2>&1; then \
	    printf '  ok   %-18s\n' "$$t"; ok=$$((ok+1)); \
	  else \
	    printf '  FAIL %-18s\n' "$$t"; \
	    $(MAKE) --no-print-directory TOP=$$t lint 2>&1 | grep -E '%Error|%Warning' | head -5 | sed 's/^/         /'; \
	    fail=$$((fail+1)); \
	  fi; \
	done; \
	echo "== 3. parameter matrix =="; \
	for knob in NUM_VC FIFO_DEPTH; do \
	  case $$knob in \
	    NUM_VC)     bl='$(NUM_VC_BENCHES)'; vals='2 8' ;; \
	    FIFO_DEPTH) bl='$(DEPTH_BENCHES)';  vals='4 8' ;; \
	  esac; \
	  for t in $$bl; do \
	    for v in $$vals; do \
	      out=$$($(MAKE) --no-print-directory TOP=$$t sim GFLAGS="-G$$knob=$$v" 2>&1); \
	      if echo "$$out" | grep -qE '$(PASS_RE)'; then \
	        printf '  ok   %-18s -G%s=%s\n' "$$t" "$$knob" "$$v"; ok=$$((ok+1)); \
	      else \
	        printf '  FAIL %-18s -G%s=%s\n' "$$t" "$$knob" "$$v"; \
	        echo "$$out" | grep -E '%Error|FAIL' | head -5 | sed 's/^/         /'; \
	        fail=$$((fail+1)); \
	      fi; \
	    done; \
	  done; \
	done; \
	echo "== 4. mesh geometry =="; \
	for g in $(MESH_GEOMS); do \
	  rr=$${g%%:*}; cc=$${g##*:}; \
	  out=$$($(MAKE) --no-print-directory TOP=noc_mesh sim ROWS=$$rr COLS=$$cc 2>&1); \
	  if echo "$$out" | grep -qE '$(PASS_RE)'; then \
	    res=$$(echo "$$out" | grep -oE '$(PASS_RE)' | tail -1); \
	    printf '  ok   noc_mesh          ROWS=%s COLS=%s  %s\n' "$$rr" "$$cc" "$$res"; ok=$$((ok+1)); \
	  else \
	    printf '  FAIL noc_mesh          ROWS=%s COLS=%s\n' "$$rr" "$$cc"; \
	    echo "$$out" | grep -E '%Error|%Fatal|FAIL' | head -5 | sed 's/^/         /'; \
	    fail=$$((fail+1)); \
	  fi; \
	done; \
	echo "---- summary ----"; \
	if [ $$fail -ne 0 ]; then \
	  echo "REGRESS: FAILED ($$fail of $$((ok+fail)) runs)"; exit 1; \
	fi; \
	echo "REGRESS: PASSED ($$ok runs)"

# ---- Waveforms ----
wave:
	gtkwave $(SIM_DIR)/$(TOP).vcd &

# ---- Cleanup ----
clean:
	rm -rf $(OBJ_DIR) $(SIM_DIR)/*.vvp $(SIM_DIR)/*.vcd
