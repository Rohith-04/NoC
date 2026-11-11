# Repository Guidelines

## Project Structure & Module Organization

This repository implements a synthesizable SystemVerilog Network-on-Chip with five-port virtual-channel routers and a configurable XY-routed mesh.

- `rtl/`: FIFO, routing, arbitration, crossbar, port, router, and mesh modules.
- `tb/`: self-checking `tb_<module>.sv` benches, `mock_arbiter.sv`, and shared flit helpers in `noc_tb_pkg.sv`.
- `docs/rtl/` and `docs/tb/`: documentation mirroring source filenames; `docs/images/` contains diagrams.
- `tools/`: assertion-negative and mutation test scripts.
- `files.f`: compilation list for slang-server and future simulator integration.
- `obj_dir/` and `sim/`: generated binaries and waveforms; keep these untracked.

## Build, Test, and Development Commands

Install Verilator, Make, and a C++ build toolchain; GTKWave is needed for waveform viewing. Run commands from the repository root:

- `make TOP=fifo sim`: build and run `tb/tb_fifo.sv` with assertions and VCD tracing.
- `make TOP=router_top lint`: lint the RTL with the selected module as top.
- `make TOP=arbiter sim GFLAGS='-GNUM_VC=2'`: exercise a supported parameter override.
- `make TOP=noc_mesh sim ROWS=3 COLS=3`: test a mesh geometry.
- `make regress`: run all nine benches, RTL lint, parameter sweeps, and additional mesh geometries.
- `make TOP=fifo wave`: open `sim/fifo.vcd` in GTKWave after simulation.
- `make clean`: remove generated build and simulation outputs.

## Coding Style & Naming Conventions

Match surrounding SystemVerilog formatting: two-space module-body indentation, aligned declarations, and named port connections. Use lowercase snake_case for modules and signals, uppercase parameters/constants, and `tb_` prefixes for bench tops. Use `logic`, `always_ff` for sequential logic, and `always_comb` for combinational logic; avoid inferred latches. Verilator provides linting; Verible is listed among development tools.

## Testing Guidelines

Extend the relevant self-checking bench for behavioral changes and run `make regress` before submitting. Preserve `--assert` in simulation and lint commands. Use shared flit-field helpers rather than hard-coded bit slices. Cover reset, backpressure, packet boundaries, and supported parameter extremes where applicable. No numerical coverage threshold is configured. Mutation and assertion-negative scripts modify RTL temporarily; run them separately in a clean working tree.

## Commit & Pull Request Guidelines

History uses short descriptive subjects without a strict prefix convention. State the affected module and concrete change. Pull requests should explain behavior changes, list validation commands and results, and link relevant issues when available. Update matching source documentation; use `docs/rtl/fifo.md` as the documentation exemplar. Include waveforms or diagrams when they clarify timing or architecture changes.
