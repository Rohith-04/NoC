# NoC

> A reusable, synthesizable Network-on-Chip IP written in SystemVerilog for FPGA prototyping and future multicore SoC integration.

## Overview

This project implements a modular Network-on-Chip (NoC) intended to serve as a reusable communication fabric for FPGA and ASIC-oriented designs.

The primary design goals are:

- Clean and readable RTL
- Synthesizable SystemVerilog
- Modular architecture
- Reusable IP design
- Thorough verification
- Straightforward integration into larger SoCs

Although this NoC is being developed as the communication backbone for the **Linnea** multicore processor, it is designed to be completely usable as a standalone IP block.

---

## Current Features

- Synthesizable SystemVerilog RTL
- Verilator lint support
- Icarus Verilog simulation
- GTKWave waveform generation
- VS Code + slang-server development environment

---

## Planned Features

- [ ] Configurable router architecture
- [ ] Packet-based communication
- [ ] AXI4-Stream interface
- [ ] Multiple routing algorithms
- [ ] Extensive verification environment
- [ ] FPGA implementation
- [ ] Performance evaluation

---

## Project Structure

```
.
├── rtl/        # RTL source files
├── tb/         # Testbenches
├── sim/        # Simulation outputs
├── docs/       # Documentation
├── scripts/    # Utility scripts
└── Makefile
```

---

## Toolchain

- SystemVerilog
- Verilator
- Icarus Verilog
- GTKWave
- Make
- Visual Studio Code
- slang-server
- Verible

---

## Building

```bash
make TOP=<module> sim
```

Example:

```bash
make TOP=router sim
```

---

## Linting

```bash
make TOP=<module> lint
```

---

## Waveforms

```bash
make TOP=<module> wave
```

---

## Vision

The goal of this project is to build a reusable Network-on-Chip IP that can be integrated into a wide range of FPGA and ASIC designs.

Long term, this repository will become the communication subsystem of the Linnea multicore SoC while remaining fully usable as an independent project.

---

## License

Released under the MIT License.
