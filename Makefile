# ---- Config ----
TOP ?=
RTL_DIR := rtl
TB_DIR  := tb
SIM_DIR := sim

IVERILOG_FLAGS := -g2012 -Wall

RTL := $(wildcard $(RTL_DIR)/*.sv)
TB  := $(TB_DIR)/tb_$(TOP).sv

.PHONY: sim lint wave clean

sim: $(SIM_DIR)/$(TOP).vvp
	vvp $(SIM_DIR)/$(TOP).vvp

$(SIM_DIR)/$(TOP).vvp: $(RTL) $(TB)
	@mkdir -p $(SIM_DIR)
	iverilog $(IVERILOG_FLAGS) -o $@ $(RTL) $(TB)

lint:
	verilator --lint-only --timing -Wall -sv $(RTL_DIR)/$(TOP).sv

wave:
	gtkwave $(SIM_DIR)/$(TOP).vcd &

clean:
	rm -rf $(SIM_DIR)/*.vvp $(SIM_DIR)/*.vcd