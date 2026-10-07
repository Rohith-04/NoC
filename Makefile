# ---- Config ----
TOP      ?=
RTL_DIR  := rtl
TB_DIR   := tb
SIM_DIR  := sim
OBJ_DIR  := obj_dir

# ---------------------------------------------------------------------------
# Toolchain: Verilator for everything -- simulation, assertions and lint.
#
#   make TOP=<tb> sim          build + run a testbench
#   make TOP=<rtl-module> lint lint the whole RTL set against one top
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
# -Wno-WIDTHEXPAND: the benches pass signals of every width (2, 4, 5, 10
#   bits) into one 32-bit `check(what, actual, expected)` task. Every one of
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
TB_SUPPORT := $(filter-out $(TB_DIR)/tb_%.sv, $(wildcard $(TB_DIR)/*.sv))
TB         := $(TB_DIR)/tb_$(TOP).sv $(TB_SUPPORT)

.PHONY: sim lint wave clean

# ---- Simulation ----
sim: $(OBJ_DIR)/v_$(TOP)/run
	./$(OBJ_DIR)/v_$(TOP)/run

$(OBJ_DIR)/v_$(TOP)/run: $(RTL) $(TB)
	@mkdir -p $(OBJ_DIR)/v_$(TOP) $(SIM_DIR)
	verilator $(VFLAGS) $(RTL) $(TB)

# ---- Lint the whole RTL set against one top ----
lint:
	verilator --lint-only --timing --assert -Wall -sv --top-module $(TOP) $(RTL)

# ---- Waveforms ----
wave:
	gtkwave $(SIM_DIR)/$(TOP).vcd &

# ---- Cleanup ----
clean:
	rm -rf $(OBJ_DIR) $(SIM_DIR)/*.vvp $(SIM_DIR)/*.vcd
