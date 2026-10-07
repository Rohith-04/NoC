# Project Linnea — v2 Format, Packet Layouts, and RTL Change List

Amends `linnea_router_implementation_spec.md` (v1). Where the two disagree, this document wins. Items marked **(proposed)** are my field-level choices that you have not explicitly confirmed.

---

## 1. Decisions in force

| Area | Decision |
|---|---|
| Flit width | `FLIT_W = 40`, parameterized |
| VCs | `NUM_VC` parameterized, default 4, up to 8; `VC_W = $clog2(NUM_VC)` |
| VA | VC-matched: an input VC at index `k` can only request output VC `k`. One 5-input arbiter per (output port, VC), HEAD_TAIL over HEAD, round-robin. No column arbiter. Supersedes the v1 flat separable VA |
| Class | Carried by VC index: MSB is the class. `NUM_VC = 4`: VCs 0-1 requests, 2-3 responses. Routers never read the header for this |
| Mesh | up to 8x8 (coordinates 3 bits each, SRC 6 bits) |
| AXI | AXI4 with bursts, 32-bit data. AXI4-Stream dropped |
| ID width | 4 bits, parameter up to 8 |
| Max burst | `MAX_BURST = 16` beats (`AxLEN <= 15`); longer requests get SLVERR at the master NI and never enter the network |
| Writes / reads | store-and-forward at the master NI (writes) and slave NI (reads); revisit after measuring |
| Dropped fields | LOCK, CACHE, QOS, REGION, USER, and PROT (see 3.3). No exclusive access |
| Address map | 4KB-aligned regions, decoded once on the start address |
| NI VC choice | deterministic function of class and (ID, destination); never load-based |

---

## 2. What stays the same

Type encoding `[1:0]`, `is_head = type[0]`, `is_last = type[1]`; route encoding and port indices; HEAD `ROUTE [13:10]`, `DEST_Y [9:7]`, `DEST_X [6:4]`; the header merge touches `[13:10]` only; SA two-stage; credit return as a per-VC vector; fetch rule (ii); SA+ST fused; link register as LT boundary. Everything the router reads from a flit is in the low 14 bits, which is why the width change is mechanical.

---

## 3. Flit and packet formats (40 bits) **(proposed field map)**

### 3.1 Common to every flit
- `[1:0]` TYPE (`00 BODY, 01 HEAD, 10 TAIL, 11 HEAD_TAIL`)
- `[39]` PAR: reserved for end-to-end parity, **not enforced in v1** (pending your confirm). Routers pass it through unchanged.

### 3.2 HEAD and HEAD_TAIL
```
[39]     PAR (reserved)
[38]     EXT        extension flag: 1 = an extension flit follows the ADDR flit (must be 0 in v1)
[37:35]  SRC_Y
[34:32]  SRC_X
[31:30]  BURST      AXI AxBURST
[29:22]  LEN        AxLEN (slots sized for the maximum, 8 bits; upper bits 0 when MAX_BURST < 256)
[21:14]  ID         AXI ID (slots sized for the maximum, 8 bits; upper bits 0 for a 4-bit ID)
[13:10]  ROUTE      rewritten at every hop (lookahead)
[9:7]    DEST_Y
[6:4]    DEST_X
[3:2]    KIND       packet kind, set by the source NI, ignored by routers (was VC_ID; see D3)
[1:0]    TYPE
```
At the parameter maximum widths (ID 8, LEN 8) the upper field is exactly full: `SRC 6 + BURST 2 + LEN 8 + ID 8 + EXT 1 + PAR 1 = 26 = [39:14]`.

KIND: `00 WR_REQ`, `01 RD_REQ`, `10 WR_RESP`, `11 RD_RESP`.

B response (HEAD_TAIL, KIND = WR_RESP): `ID` as above, `BRESP` in `[23:22]` (the LEN slot's low bits), DEST = the request's SRC.

### 3.3 ADDR flit (second flit of AW and AR packets, type BODY or TAIL)
```
[39]     PAR (reserved)
[38:37]  spare
[36:34]  SIZE       AxSIZE
[33:2]   ADDR       AxADDR (32 bits)
[1:0]    TYPE       BODY for AW (data follows), TAIL for AR (last flit)
```
PROT (3 bits) is not carried in v1: with parity reserved and the HEAD slots sized for the maximum widths, there is no room for 3 bits without a width trade. Slave NI drives a constant PROT. Choose later: shrink ID or LEN slots, or drop the parity reservation.

### 3.4 W BODY/TAIL
```
[39] PAR   [38] spare   [37:34] WSTRB (4)   [33:2] WDATA (32)   [1:0] TYPE   (TAIL = WLAST)
```

### 3.5 R BODY/TAIL
```
[39] PAR   [38:36] spare   [35:34] RRESP (2)   [33:2] RDATA (32)   [1:0] TYPE   (TAIL = RLAST)
```

### 3.6 Packets
| Packet | Flits | Types in order |
|---|---|---|
| Write request, `n` beats (`n = AWLEN + 1`) | `2 + n` | HEAD (KIND WR_REQ), BODY (ADDR), BODY ... , TAIL (last W beat) |
| Read request | 2 | HEAD (KIND RD_REQ), TAIL (ADDR) |
| Read response, `n` beats | `1 + n` | HEAD (KIND RD_RESP, ID), BODY ..., TAIL (last R beat) |
| Write response | 1 | HEAD_TAIL (KIND WR_RESP, ID, BRESP) |

Response DEST fields are copied from the request's SRC. The slave NI echoes the ID. The longest packet is `2 + 16 = 18` flits.

---

## 4. Router RTL change list (do in this order)

1. **`FLIT_W` parameter.** FIFO `WIDTH`, input-port data paths, `st_flit_data`, crossbar data, output-port link register and merge, router_top and link ports. Field slices stay as in section 2. Tie the width-dependent assertions (merge confined to `[13:10]`, `[3:2]` untouched) to the parameter.
2. **`NUM_VC` / `VC_W` parameterization.** Replace every hard-coded 2-bit VC id: sideband `vc_id`, `va_gnt_out_vc`, `sa_req_out_vc`, `st_out_vc`, credit indexing. Credit return is already a `NUM_VC`-wide vector.
3. **HEAD `[3:2]` is KIND, not VC_ID.** No logic change (routers ignore it); update comments, constructors, and assertions.
4. **VA, VC-matched.** For each (output port `o`, VC `k`): requesters are input ports `p` where `va_req[p][k]` and `idx(va_req_out_port[p][k]) == o`. Enabled only if `!alloc_busy[o][k]`. Pick: `va_req_single` first, then round-robin pointer `rr_va[o][k]`. Grant sets `alloc_busy[o][k]`. Delete the column arbiter and the dropped-row case. `va_gnt_out_vc[p][k]` is driven as `k` (delete it and the `out_vc` register after the regression is green). `alloc_busy` clear unchanged (`sa_req_last` grant).
5. **Assertions.** Add `granted output VC == input VC index`; keep `alloc_busy` bookkeeping, one-hot grant, XY-legality, credit bounds.
6. **Benches.** Parameterize the constructors, the tag field (was `[31:14]`, 18 bits; now `[39:14]` minus the used slots, or a smaller tag), and the body/tail constants `{tag, 12'h201}` and `{tag, 12'h401}` (keep `[13:10]` non-zero in BODY/TAIL so an unwanted merge stays observable). Check `rx_*` accessors and the scoreboard's field checks against the section 3.2 map; the scoreboard's `vc[3:2]` check becomes a KIND check.

---

## 5. Test changes

- **T6 changes meaning:** two requesters on the same VC index serialize; different indices never interfere.
- **New: VC isolation.** A long packet occupying VC0 of an output must not delay a packet on VC1 of the same output.
- **New: HEAD_TAIL priority** still applies within one (output, VC) arbiter.
- **Run the whole regression at `NUM_VC = 2` and `4`.** At 2 it is the minimum-AXI configuration (one VC per class).
- **Run at `FLIT_W = 32` and `40`.** The router must be width-agnostic; a failure at one width finds a hard-coded slice.
- **Carried over, still open:** slow-sink backpressure test; FIFO depth sweep (depth 3, 4, 5) to measure the directional credit loop; hop-latency check (3 cycles per router); 2x2 turn cases; T11 unique body payloads and several seeds.

---

## 6. Order of work

1. Apply section 4, rerun everything (section 5).
2. Slow-sink test and depth sweep on the line bench.
3. Reconfigurable mesh (`noc_mesh`, flat packed boundary), 2x2 first, wiring self-test (every tile to every tile, hops = Manhattan distance + 1).
4. NI.

## 7. NI items still to design (not blocking the router)

ID-to-destination lock table; address decode table; store-and-forward buffers (write buffer at least `MAX_BURST` beats, or the NI deadlocks); AXI handshake to internal credit bridge; SLVERR path for oversize bursts; transaction timeout; parity generation and checking (if enabled); response consumption guarantee at the master NI; per-class VC selection policy (hash of ID and destination).
