# Dynamic VC allocation validation

Validation date: 2026-11-12. Tool: Verilator 5.020 (Debian 5.020-1), with
`--assert` enabled in simulation and strict `-Wall` RTL lint.

## Executed results

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

## Coverage and interpretation

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

## Unverified work and remaining trade-offs

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

## Changed files and responsibilities

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
