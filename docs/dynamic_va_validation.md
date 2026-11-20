# Dynamic VC allocation validation

## Current validation — 2026-11-20

The source revision was `328f41eab6347fb01466626cc87de96ac67bc2de`.
`git status --porcelain=v1 --untracked-files=all` was empty before the runs.
The checkout had ignored local files and prior build products. Each suite
started from unmodified source with isolated build outputs. The runs used
Verilator 5.020 (Debian 5.020-1), GNU Make 4.3 and GCC 13.3.0.
[Environment log](../results/2026-11-20/environment.log),
[source comparison](../results/2026-11-20/source-integrity.log)

### Commands and evidence

| Command | Evidence |
|---|---|
| `make regress` | [Summary](../results/2026-11-20/regression.log), [all 45 child command logs](../results/2026-11-20/regression-runs/) |
| `bash tools/mutate_all.sh` | [Summary](../results/2026-11-20/mutate_all.log), [per-case logs and RTL diffs](../results/2026-11-20/mutate_all/) |
| `bash tools/mutate_out.sh` | [Summary](../results/2026-11-20/mutate_out.log), [per-case logs and RTL diffs](../results/2026-11-20/mutate_out/) |
| `bash tools/assert_neg.sh` | [Original-case summary](../results/2026-11-20/assert_neg.log), [per-case logs and RTL diffs](../results/2026-11-20/assert_neg/) |
| `bash tools/assert_neg_repaired.sh` | [Replacement-suite summary](../results/2026-11-20/assert_neg_repaired.log), [per-case logs and RTL diffs](../results/2026-11-20/assert_neg_repaired/) |
| `make TOP=noc_mesh lint GFLAGS='-GROWS=8 -GCOLS=8 -GNUM_VC=8'` | [Strict lint](../results/2026-11-20/mesh-8x8-lint.log) |
| `make TOP=noc_mesh OBJ_DIR=obj_8x8 sim ROWS=8 COLS=8 GFLAGS=-GNUM_VC=8` | [Original build attempt](../results/2026-11-20/mesh-8x8-sim.log) |
| `make -C obj_8x8/v_noc_mesh -f Vtb_noc_mesh.mk -j6` | [Resumed C++ build](../results/2026-11-20/mesh-8x8-build-resume.log) |
| `./obj_8x8/v_noc_mesh/run` | [Simulation](../results/2026-11-20/mesh-8x8-run.log) |

The checked-in regression recipe captures or discards its child output.
A first attempt passed three benches before it was stopped because the
PATH-only wrapper was bypassed by GNU Make's absolute path. The fresh run
set the environment variable `MAKE` to the logging wrapper and
`LINNEA_REGRESSION_LOGS` to its output directory. The wrapper preserved each
recursive command's output and exit status. The Makefile, compiler options
and test sources were unchanged. [Capture wrapper](../results/2026-11-20/capture-make.sh),
[interrupted preflight](../results/2026-11-20/regression-capture-preflight.log)

### Regression

The fresh regression exited **0** in **1,131.90 s**. All **45 runs**
passed, including 9 default simulations, 8 strict RTL lints, 24
parameter-sweep simulations and 4 additional mesh simulations. There were
zero failures or skipped configured runs. The 37 simulation logs contain
the pass banner and normal completion with no checker or assertion failures.
All eight strict lints completed without warnings.
[Log audit](../results/2026-11-20/evidence-audit.log)

| Default bench | Checks |
|---|---:|
| `fifo` | 879 |
| `route_compute` | 49,178 |
| `noc_input_port` | 171 |
| `arbiter` | 103 |
| `crossbar` | 286 |
| `noc_output_port` | 139 |
| `router_top` | 104 |
| `router_chain` | 1,640 |
| `noc_mesh` | 326 |

The FIFO and input-port benches print `Checks :` and `Errors :` separately
from their pass banners. Check counts are the benches' explicit counters.
They exclude the evaluations of HDL assertions.

| Bench | Default | `NUM_VC=2` | `NUM_VC=8` | `FIFO_DEPTH=4` | `FIFO_DEPTH=8` |
|---|---:|---:|---:|---:|---:|
| `fifo` | 879 | — | — | 879 | 953 |
| `route_compute` | 49,178 | — | — | — | — |
| `noc_input_port` | 171 | 155 | 203 | 171 | 171 |
| `arbiter` | 103 | 100 | 105 | 103 | 111 |
| `crossbar` | 286 | — | — | — | — |
| `noc_output_port` | 139 | 139 | 139 | — | — |
| `router_top` | 104 | 104 | 104 | 104 | 108 |
| `router_chain` | 1,640 | 1,248 | 1,640 | 1,640 | 1,760 |
| `noc_mesh` | 326 | 326 | 326 | 326 | 470 |

The sweep holds the other knob at its default (4 where applicable). For
`noc_mesh`, `LOCAL_CREDITS` follows `FIFO_DEPTH`. For `arbiter`,
`router_top` and `router_chain`, the bench holds LOCAL credits at 4, so
the depth sweep varies directional credit depth and, for the router benches,
the input FIFO depth. `tb_arbiter` has no FIFO and sweeps its directional
credit depth. A dash marks a knob outside that bench's sweep. The depth-4
overrides repeat the default configuration.

| Mesh | `NUM_VC` | `FIFO_DEPTH` | Checks | Packets | Flits built / scored |
|---|---:|---:|---:|---:|---:|
| 2×2 | 4 | 4 | 326 | 24 | 90 / 90 |
| 2×2 | 2 | 4 | 326 | 24 | 90 / 90 |
| 2×2 | 8 | 4 | 326 | 24 | 90 / 90 |
| 2×2 | 4 | 8 | 470 | 24 | 138 / 138 |
| 1×2 | 4 | 4 | 59 | 4 | 15 / 15 |
| 2×1 | 4 | 4 | 59 | 4 | 15 / 15 |
| 3×3 | 4 | 4 | 1,933 | 144 | 544 / 544 |
| 2×3 | 4 | 4 | 805 | 60 | 225 / 225 |

The independent sweeps cover `(NUM_VC, FIFO_DEPTH) = (2,4), (4,4),
(8,4), (4,8)` at 2×2. The additional regression geometries use (4,4).
The simulations use 40-bit flits. Each all-to-all workload sends one short
packet and one `FIFO_DEPTH+1`-flit packet per ordered pair of distinct tiles.

The default chain now reports 1,640 checks, up from 1,370 in the
2026-11-12 regression summary. The current 1,248 / 1,640 / 1,640 counts
for 2 / 4 / 8 VCs at depth 4 and 1,760 at 4 VCs, depth 8 match the
historical strengthened reruns. The directed test transfers 12 flits per
target packet at depth 4 and 16 at depth 8. Distinct BODY payloads check
ordering after a forced remap in both classes across the three routers.
The two-VC run bypasses this directed test because each class has a single
VC. Its remaining route, traffic-class, packet-order and credit checks run.
The two-VC allocator bench also bypasses the D1 assertions for the second
same-class grant and remapped index. Its D3 setup loop runs zero iterations.

The other default pass results and additional geometry check counts match
the 2026-11-12 regression summary below. Today's logs record the numeric
FIFO count and the sweep check counts omitted from that summary, and add
the fault-suite and 8×8 results.

### Mutation and assertion-negative suites

Every original case definition was attempted with a safety and logging
harness in an isolated copy. The original reporting code was replaced
because the mutation scripts could report “killed” on empty output. The
runner replaces the hard-coded checkout and `/tmp/opencode` paths with the
copied suite's repository root and a private results path. It creates
per-case build, backup and log directories, requires exactly one source
match, saves the fault diff and restores the source at case exit. It keeps
complete build and run output, times both phases, disables core dumps and
uses an explicit 120-second wall timeout per negative or mutant simulation.
Builds use the original bench, flags and assertions setting for each suite.
The mutation runs omit `--assert` to exercise the functional checkers. The
assertion-negative runs enable `--assert` and require the targeted assertion
diagnostic. The working-tree scripts stayed unchanged.
[Runner](../results/2026-11-20/fault-harness.sh),
[setup](../results/2026-11-20/prepare-fault-suites.py),
[all-case harness diff](../results/2026-11-20/mutate_all-harness.diff),
[output-port harness diff](../results/2026-11-20/mutate_out-harness.diff),
[original assertion harness diff](../results/2026-11-20/assert_neg-harness.diff),
[repaired suite diff](../results/2026-11-20/assert_neg_repaired-harness.diff)

| Mutation suite, original definitions | Attempted | Applied | Detected | Survived | Skipped | Errored |
|---|---:|---:|---:|---:|---:|---:|
| `mutate_all.sh` | 6 | 6 | 6 | 0 | 0 | 0 |
| `mutate_out.sh` | 2 | 2 | 2 | 0 | 0 | 0 |
| Total | 8 | 8 | 8 | 0 | 0 | 0 |

The two scripts define eight mutation cases. Each matched once, built
successfully, ran, and emitted both a failing test check and a nonzero
failed-check summary attributable to the change. The unmodified router
bench passed all 104 checks with the same assertions-off build settings.
All eight mutants returned process status 0 after reporting checker
failures. The fetch/grant fault also hit simulated drain limits, but the bench
finished normally and independently reported the missing flit.
Compared with the older module pages, today's stage-2 and fetch/grant faults
report 2/104 and 19/49 failed checks (earlier 1/104 and 16/49).
[Unmodified control build and run](../results/2026-11-20/mutation-baseline.log)

| Mutated behavior | First relevant failure | Failed / total checks |
|---|---|---:|
| X direction reversed | T1a selected WEST instead of EAST | [13 / 103](../results/2026-11-20/mutate_all/01/run.log) |
| Stage 2 ignores round-robin pointer | T5 failed to alternate competing inputs | [2 / 104](../results/2026-11-20/mutate_all/02/run.log) |
| Grant overrides fetch | T2 received two of three flits | [19 / 49](../results/2026-11-20/mutate_all/03/run.log) |
| Stage 1 bypasses credit check | T7 sent eight flits against four initial credits | [2 / 104](../results/2026-11-20/mutate_all/04/run.log) |
| Crossbar uses adjacent input | T1a HEAD_TAIL type was lost | [30 / 103](../results/2026-11-20/mutate_all/05/run.log) |
| Output uses constant header direction | T1a route field was 4, expected 0 | [3 / 104](../results/2026-11-20/mutate_all/06/run.log) |
| Output skips header update | T1a retained route field 2, expected 0 | [3 / 104](../results/2026-11-20/mutate_out/01/run.log) |
| Output rewrites every flit | T2 BODY payload was modified | [2 / 104](../results/2026-11-20/mutate_out/02/run.log) |

| Assertion-negative suite | Attempted | Applied | Fired as expected | Missed | Skipped | Errored |
|---|---:|---:|---:|---:|---:|---:|
| Original case definitions | 7 | 6 | 6 | 0 | 1 | 0 |
| Replacement suite | 7 | 7 | 7 | 0 | 0 | 0 |

Six cases were repeated in the replacement suite. The totals are per suite.
Each fired case built successfully and stopped with the targeted Verilator
assertion diagnostic and simulation exit status 134. The original credit
case searched for the broad prefix `arbiter:`. Its full log confirms that
the exact failure was a switch on an empty VC credit pool.

| Case | Original | Replacement suite |
|---|---|---|
| FIFO depth guard | [Fired at time 0](../results/2026-11-20/assert_neg/01/run.log) | [Fired](../results/2026-11-20/assert_neg_repaired/01/run.log) |
| Input packet sequence | [Fired on BODY with no packet open](../results/2026-11-20/assert_neg/02/run.log) | [Fired](../results/2026-11-20/assert_neg_repaired/02/run.log) |
| Arbiter credit gate | [Fired on switch with zero credit](../results/2026-11-20/assert_neg/03/run.log) | [Fired](../results/2026-11-20/assert_neg_repaired/03/run.log) |
| Allocator grant | [Skipped, pattern absent](../results/2026-11-20/assert_neg/04/apply.log) | [Cross-class grant assertion fired](../results/2026-11-20/assert_neg_repaired/04/run.log) |
| Crossbar selects wrong data | [Fired on selection mismatch](../results/2026-11-20/assert_neg/05/run.log) | [Fired](../results/2026-11-20/assert_neg_repaired/05/run.log) |
| Header lookahead merge | [Fired on stale header route](../results/2026-11-20/assert_neg/06/run.log) | [Fired](../results/2026-11-20/assert_neg_repaired/06/run.log) |
| Credits on absent link | [Fired on chain boundary](../results/2026-11-20/assert_neg/07/run.log) | [Fired](../results/2026-11-20/assert_neg_repaired/07/run.log) |

The obsolete case targets `va_gnt_out_vc[row_pidx[o][k]][k] = VC_W'(k);`.
The current grant is indexed by the winning requester and the granted
output VC can legally differ from the input index within its class. The
replacement inverts the allocator's same-class eligibility predicate.
It keeps the advertised output VC consistent with the reserved row so
the unchanged class assertion sees the intended violation. At four VCs,
the assertion reported input VC 0 reserved output VC 3. The patch applied
only in the isolated copy. [Injected replacement diff](../results/2026-11-20/assert_neg_repaired/04/injected.diff)

The first launch of the replacement suite stopped during setup, before
the first build. The replacement-suite totals above are from its complete
fresh retry. [Interrupted launcher log](../results/2026-11-20/assert-neg-repaired-preflight.log)

### 8×8 mesh with eight VCs

The 64-router setup used `NUM_VC=8`, `FIFO_DEPTH=4`, four LOCAL credits
per VC, and 40-bit flits.

| Stage | Exit | Elapsed | Observation |
|---|---:|---:|---|
| Strict RTL lint and elaboration | 0 | 56.82 s | `--lint-only --timing --assert -Wall` completed without warnings. |
| Original `make … sim` | 2 | 163.68 s | Verilator generated C++ and started a serial build. Stopped the child build with SIGTERM at `Vtb_noc_mesh___024root__DepSet_h2ea2864e__37.o` (42 object files observed just before the stop) to resume with parallel compilation. Child exit 143. Link and simulation were still pending when stopped. |
| Resumed build, six jobs | 0 | 498.02 s | Reused the same generated C++ and linked the simulator. |
| Direct simulation | 0 | 23.41 s | **106,916 checks passed**, 8,064 packets completed, 30,240 flits built and 30,240 scored. |

The resumed build reused Verilator's generated Makefile and compiler flags.
The bench used its original traffic, assertions, 40,000-cycle wait limit and
500-cycle progress watchdog threshold. No external timeout was added to this
simulation. The all-to-all report covers all 4,032 ordered source/destination
pairs and two packets per pair. [Original phase observations](../results/2026-11-20/mesh-8x8-phases.log),
[build](../results/2026-11-20/mesh-8x8-build-resume.log),
[simulation](../results/2026-11-20/mesh-8x8-run.log)

### Source audit and limits

| Claim | Source evidence |
|---|---|
| Each mesh dimension accepts 1–8 and the mesh and router support 2, 4 or 8 VCs per port | Parameter guards and 3-bit coordinates. [Mesh](../rtl/noc_mesh.sv), [router](../rtl/router_top.sv) |
| Lower-half VCs are designated for requests and upper-half VCs for responses | The documentation names the two classes. RTL derives each class from the VC sideband index divided by half the VC count. Header `KIND` is preserved as payload metadata and can differ from the class carried by the sideband. [Architecture](architecture.md#dynamic-vc-allocation-and-classes), [allocator](../rtl/arbiter.sv), [output bench](../tb/tb_noc_output_port.sv) |
| Per-hop same-class allocation and packet reservation | The allocator searches free same-class output rows and excludes earlier winners. The input port captures the downstream VC on a header grant and retains it across BODY flits and FIFO gaps. A final switch grant releases the reserved row for reuse in a later cycle. [Allocator](../rtl/arbiter.sv), [input port](../rtl/noc_input_port.sv) |
| Deterministic XY, lookahead, wormhole switching and credit flow control | X resolves before Y. Directional inputs consume the prior header's lookahead. Output links update route bits on header flits. BODY and TAIL use the packet's assignment, and each granted flit spends a credit on the mapped VC, returned when the receiver fetches. [Routing](../rtl/route_compute.sv), [output port](../rtl/noc_output_port.sv), [input port](../rtl/noc_input_port.sv), [allocator](../rtl/arbiter.sv) |
| External traffic scoreboard | The mesh scoreboard records each packet's destination, injected VC, length, tag and KIND from stimulus. It reconstructs the expected flit by position and checks ejection payload, class, destination, LOCAL route and total counts. It uses no allocator or routing decision as its oracle. Directed chain remapping checks use precomputed expected VC IDs. [Mesh bench](../tb/tb_noc_mesh.sv), [chain bench](../tb/tb_router_chain.sv) |
| AXI4 network interface is planned | Mesh and router expose flit data, valid, VC sidebands and credit vectors. No AXI4 adapter is implemented in the RTL. [Mesh](../rtl/noc_mesh.sv), [roadmap](../README.md#project-status-and-roadmap) |

The regression omits 1×1 because the mesh bench requires at least two tiles
and the XY table excludes LOCAL-to-LOCAL traffic. The listed rows define the
tested mesh configurations. Other geometries, VC/depth cross-products, flit
widths, credit settings and traffic schedules have no coverage claim here.
The mesh bench uses identical BODY payloads within a packet. The distinct-BODY
ordering evidence comes from the directed chain test.
The simulation runs provide no synthesis, area, STA, timing closure,
gate-level, formal, FPGA, or throughput/latency characterization evidence.
The assertion-negative cases sample seven properties. The flit-type encoding
guard mentioned in the original script's introductory comment has no
corresponding negative case. AXI4 integration remains future work.

### Resume-safe claims

- Implemented a five-port SystemVerilog wormhole router and parameterized XY
  mesh with lookahead, per-hop same-class VC allocation, packet reservations
  and per-VC credit flow control.
- Passed 37 assertion-enabled simulations and eight strict RTL lint runs in
  a 45-run Verilator regression. The directed chain verified same-class
  remapping in both classes with four and eight VCs.
- Detected eight injected RTL faults with functional checkers and exercised
  seven targeted assertions in the suite with the dynamic allocator case.
- Simulated a 64-router mesh with eight VCs per port in the original
  all-to-all workload. Passed 106,916 checks and delivered all 30,240
  flits across 8,064 packets.

## Historical validation — 2026-11-12

The following sections record the original development runs and limitations
from 2026-11-12.

Validation date: 2026-11-12. Tool: Verilator 5.020 (Debian 5.020-1), with
`--assert` enabled in simulation and strict `-Wall` RTL lint.

### Executed results

The standalone development runs executed before the complete regression:

| Command | Result |
|---|---|
| `make TOP=arbiter sim` | PASS, 103 checks |
| `make TOP=noc_input_port sim` | PASS, 171 checks, zero errors |
| `make TOP=router_top sim` | PASS, 104 checks |
| `make TOP=router_chain sim` | PASS, 1,370 checks |
| `make TOP=router_top lint` | PASS, no warnings |

`make regress` completed successfully: **REGRESS: PASSED (45 runs)**,
exit status 0. All nine default benches, eight strict RTL lint tops, 24
parameter sweeps and four additional mesh geometries passed. The NUM_VC
sweeps cover 2 and 8 (default benches cover 4); FIFO_DEPTH sweeps cover 4 and 8.
These are independent knob sweeps, not every NUM_VC/FIFO_DEPTH cross-product.

An earlier development attempt was stopped after finding bench warnings and
cycle-alignment failures; those were corrected before the standalone passes
above. A generated C++ unpacked-array issue was resolved with a packed
allocation sideband. No known functional failures remain in the executed
final tests.

Exact complete-regression summary (`/tmp/linnea-regress-final.log`):

```text
== 1. benches at default parameters ==
  ok   fifo               ALL TESTS PASSED
  ok   route_compute      ALL 49178 CHECKS PASSED
  ok   noc_input_port     ALL TESTS PASSED
  ok   arbiter            ALL 103 CHECKS PASSED
  ok   crossbar           ALL 286 CHECKS PASSED
  ok   noc_output_port    ALL 139 CHECKS PASSED
  ok   router_top         ALL 104 CHECKS PASSED
  ok   router_chain       ALL 1370 CHECKS PASSED
  ok   noc_mesh           ALL 326 CHECKS PASSED
== 2. lint, one RTL module per top ==
  ok   fifo              
  ok   route_compute     
  ok   crossbar          
  ok   arbiter           
  ok   noc_input_port    
  ok   noc_output_port   
  ok   router_top        
  ok   noc_mesh          
== 3. parameter matrix ==
  ok   arbiter            -GNUM_VC=2
  ok   arbiter            -GNUM_VC=8
  ok   noc_input_port     -GNUM_VC=2
  ok   noc_input_port     -GNUM_VC=8
  ok   noc_output_port    -GNUM_VC=2
  ok   noc_output_port    -GNUM_VC=8
  ok   router_chain       -GNUM_VC=2
  ok   router_chain       -GNUM_VC=8
  ok   router_top         -GNUM_VC=2
  ok   router_top         -GNUM_VC=8
  ok   noc_mesh           -GNUM_VC=2
  ok   noc_mesh           -GNUM_VC=8
  ok   arbiter            -GFIFO_DEPTH=4
  ok   arbiter            -GFIFO_DEPTH=8
  ok   fifo               -GFIFO_DEPTH=4
  ok   fifo               -GFIFO_DEPTH=8
  ok   noc_input_port     -GFIFO_DEPTH=4
  ok   noc_input_port     -GFIFO_DEPTH=8
  ok   router_chain       -GFIFO_DEPTH=4
  ok   router_chain       -GFIFO_DEPTH=8
  ok   router_top         -GFIFO_DEPTH=4
  ok   router_top         -GFIFO_DEPTH=8
  ok   noc_mesh           -GFIFO_DEPTH=4
  ok   noc_mesh           -GFIFO_DEPTH=8
== 4. mesh geometry ==
  ok   noc_mesh          ROWS=1 COLS=2  ALL 59 CHECKS PASSED
  ok   noc_mesh          ROWS=2 COLS=1  ALL 59 CHECKS PASSED
  ok   noc_mesh          ROWS=3 COLS=3  ALL 1933 CHECKS PASSED
  ok   noc_mesh          ROWS=2 COLS=3  ALL 805 CHECKS PASSED
---- summary ----
REGRESS: PASSED (45 runs)
```

The chain test was strengthened after the initial three-flit directed passes
(including the regression's default/NUM_VC chain runs). Final reruns below
cover every changed chain configuration; the regression's later FIFO_DEPTH
chain runs also used the final test. The final directed test now uses distinct BODY payloads and `FIFO_DEPTH+8` flits.
Final test-source reruns, all with assertions enabled:

| Configuration | Build / execution | Result |
|---|---|---|
| NUM_VC=2, FIFO_DEPTH=4 | `make TOP=router_chain OBJ_DIR=/tmp/linnea_chain_vc2 GFLAGS=-GNUM_VC=2 /tmp/linnea_chain_vc2/v_router_chain/run`, then execute that binary | PASS, 1,248 checks |
| NUM_VC=4, FIFO_DEPTH=4 | Same command/path with `vc4` and `-GNUM_VC=4` | PASS, 1,640 checks |
| NUM_VC=8, FIFO_DEPTH=4 | Same command/path with `vc8` and `-GNUM_VC=8` | PASS, 1,640 checks |
| NUM_VC=4, FIFO_DEPTH=8 | Regression built with `GFLAGS=-GFIFO_DEPTH=8`; re-executed `./obj_dir/v_router_chain/run` | PASS, 1,760 checks |

The standalone builds used isolated temporary build directories to avoid
conflicting with the running regression. Their first `make ... sim` invocations
compiled successfully but could not launch binaries because Makefile prefixes
its run path with `./`, which does not support an absolute OBJ_DIR. The binaries
were then executed directly; only these observed passing executions are listed
above. The repository Makefile was not changed.

### Coverage and interpretation

The allocator bench D1–D6 covers same-index parallel allocation, one remaining
matching VC, mixed classes, oversubscription, sibling input VCs, HEAD_TAIL
priority, round-robin advancement, ownership through nonfinal transfers,
stage-2-denied TAIL, registered release/reuse, zero-credit allocation/stalls,
HEAD_TAIL release, and simultaneous credit return/transmission. Existing T4,
T5, T7 and reset coverage remain active.

The input-port bench walks HEAD/BODY/TAIL for every input VC using a rotated
same-class map. It changes VA's sideband after the grant and verifies the
captured mapping persists; original FIFO bypass/collision/fetch/credit tests
remain active.

The chain's directed `dynamic_multihop()` creates a specific second-hop
conflict. A packet injected on the first VC of each class uses that VC at A,
then the next VC at B and C because a different unfinished packet holds the
first VC there. The final test uses `FIFO_DEPTH+8` flits, exceeding both
directional and LOCAL credit pools, with distinct BODY payloads to detect
reordering. Every hop checks exact count, payload, order, and assigned VC. Both classes run at NUM_VC=4/8.
NUM_VC=2 has only one VC per class, so a same-class index change is impossible;
it retains the routing, class, credit, backpressure and ordering checks.
Every chain link VC has a packet-tag monitor preventing cross-packet
interleaving. The random chain scoreboard and full-payload mesh scoreboard
also check ejected class against injected class.

RTL assertions check grant uniqueness in both resource spaces, class isolation,
no allocation of reserved VCs, stable packet assignment, reservation lifetime,
exact credit transitions and bounds, and transmitted/link VC sidebands. A
simulation-only router seam scoreboard tracks live owners through FIFO gaps.
These are simulation assertions, not formal proofs.

### Unverified work and remaining trade-offs

No synthesis, area measurement, STA, timing closure, gate-level simulation,
formal proof, FPGA implementation, or mutation/assertion-negative suite was
run for this change. The latter scripts temporarily modify RTL and the
repository requires a clean tree for them; the implementation tree is dirty.
Historical mutation results in older module documents are not current results.

VA's ordered exclusion path and flattened priority scans are larger than
VC-matched arbitration. Round-robin pointers widen, each input VC stores an
output VC, and SA credit lookup now uses that variable index. At the default
five ports/four VCs, output-VC state adds 40 register bits and wider VA pointers
add another 40 bits before synthesis optimization. No additional pipeline
stage was introduced. Timing and area need synthesis/STA confirmation.

HEAD_TAIL retains strict priority, so an unbounded stream of singles can starve
HEADs. Output VC rows are processed in increasing order; low indices are
preferred. VA does not prefer credited VCs, so a free zero-credit row may
be selected before a credited alternative. Physical output bandwidth remains
one flit per cycle. Released VCs
remain unavailable until the next cycle, preserving registered-release behavior.

The historical `linnea_v2_format_and_rtl_changes.md` and
`linnea_router_implementation_spec.md` referenced by README are absent in this
checkout. The change follows the inspected RTL, module documentation, and the
requested dynamic-VA architecture. The old VC-matched rule is superseded.

### Changed files and responsibilities

| Files | Reason |
|---|---|
| `rtl/arbiter.sv` | Dynamic class-constrained matching, flattened requester pointers, returned output-VC grant, and resource/credit assertions. Existing SA and credit-update datapaths remain intact. |
| `rtl/noc_input_port.sv` | Capture allocated output VC per input FIFO; supply it to SA; assert packet assignment stability and class. |
| `rtl/router_top.sv` | Route the grant sideband to input ports; independently check live ownership and transmitted resource mapping. |
| `tb/tb_arbiter.sv` | Replace obsolete VC-match expectations with matching/priority/reservation/credit tests; retain SA tests. |
| `tb/tb_noc_input_port.sv` | Drive allocation sideband and exercise stored remapped state on every input VC. |
| `tb/tb_router_top.sv` | Same-input-VC contention on multiple physical ports when class capacity permits. |
| `tb/tb_router_chain.sv` | Forced multi-hop remapping in both classes, long packets with distinct BODY data, per-link packet serialization, and class scoreboard. |
| `tb/tb_noc_mesh.sv` | Class preservation in the existing full-payload scoreboard. |
| `tb/mock_arbiter.sv` | Correct comments: mock controls grants while bench supplies the VC map. No functional mock change. |
| `README.md`, `docs/rtl/arbiter.md`, `docs/rtl/noc_input_port.md`, `docs/rtl/router_top.md` | Current architecture, state/interfaces, matching policy, pointer updates, credit lookup, reservation lifetime, remapping and limitations. |
| `docs/tb/tb_arbiter.md`, `docs/tb/tb_noc_input_port.md`, `docs/tb/tb_router_top.md`, `docs/tb/tb_router_chain.md`, `docs/tb/tb_noc_mesh.md`, `docs/tb/mock_arbiter.md` | Updated verification interfaces and coverage; supersede obsolete VC-match claims. |
| `docs/dynamic_va_validation.md` | Executed results, remaining validation scope, and change inventory. |

No functional changes were made to FIFO, routing, crossbar, output-port, mesh
wiring, packet format, public router interfaces, or fetch-based credit returns.
