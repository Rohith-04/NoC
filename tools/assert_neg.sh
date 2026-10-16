#!/usr/bin/env bash
#
# Negative tests for the assertions themselves.
#
# tools/mutate_all.sh and tools/mutate_out.sh prove that the BENCHES catch a
# broken design -- they deliberately build WITHOUT --assert, so nothing in
# those runs exercises the SVA. This script proves the other half: that with
# --assert on, a design that actually violates a property has that property
# reported by the tool, for each family of assertions in the RTL.
#
#   1. static parameter checks      fifo, noc_input_port constant encoding
#   2. leaf-module clocking SVA     noc_input_port, arbiter, crossbar,
#                                   noc_output_port
#   3. top-level seam SVA           router_top
#
# One case per family-member file -- more where a single file carries two
# differently-shaped properties, as the arbiter now does (the credit gate and
# linnea_v2 section 4.5's VC-matched grant). Each case mutates the RTL so
# that the watched behaviour is wrong, builds WITH --assert, runs, and greps
# for the exact $error text of the assertion under test. If the message never
# appears the case reports MISSED, which means either the mutation did not
# reach the property or the property is vacuous -- both are bugs worth
# knowing about.
#
# Every mutation is restored from a backup before the next case, and the
# script restores it again on exit so `git diff rtl/` stays clean.
set -u
cd "$(dirname "$0")/.."
BAK=/tmp/opencode/assert_neg.bak

cleanup () {
  for f in rtl/fifo.sv rtl/noc_input_port.sv rtl/arbiter.sv \
           rtl/crossbar.sv rtl/noc_output_port.sv rtl/router_top.sv; do
    [ -f "$BAK.$(basename "$f")" ] && cp "$BAK.$(basename "$f")" "$f"
  done
}
trap cleanup EXIT

run_neg () {
  local name="$1" file="$2" old="$3" new="$4" bench="$5" needle="$6"

  cp "$file" "$BAK.$(basename "$file")"
  if ! grep -qF -- "$old" "$file"; then
    echo "SKIP    $name (pattern not found)"; return
  fi
  if ! python3 - "$file" "$old" "$new" <<'PY'
import sys
f, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(f).read()
assert s.count(old) == 1, f"pattern occurs {s.count(old)}x"
open(f, 'w').write(s.replace(old, new))
PY
  then
    echo "SKIP    $name (pattern not unique)"; cp "$BAK.$(basename "$file")" "$file"; return
  fi

  rm -rf obj_dir/v_neg
  if ! verilator --binary --timing --trace --assert -Wall -Wno-BLKSEQ \
       -Wno-WIDTHEXPAND -Wno-UNUSEDSIGNAL -sv --top-module tb_$bench \
       -Mdir obj_dir/v_neg -o run rtl/*.sv tb/noc_tb_pkg.sv tb/tb_$bench.sv tb/mock_arbiter.sv \
       > /tmp/opencode/assert_neg.build 2>&1; then
    echo "ERROR   $name (build failed)"; tail -4 /tmp/opencode/assert_neg.build
    cp "$BAK.$(basename "$file")" "$file"; return
  fi

  local out
  out=$(./obj_dir/v_neg/run 2>&1)
  if echo "$out" | grep -qF -- "$needle"; then
    echo "FIRED   $name"
    echo "          $(echo "$out" | grep -m1 -F -- "$needle" | sed 's/^ *//')"
  else
    echo "MISSED  $name   (expected: $needle)"
    echo "$out" | tail -6 | sed 's/^/          /'
  fi
  cp "$BAK.$(basename "$file")" "$file"
}

echo "== 1. static parameter / elaboration checks =="
# The fifo refuses a DEPTH that is not a power of two >= 2. Raising the
# lower bound to 9 makes every legal depth illegal -- 4 (the linnea_v2
# default) and 8 alike -- so the check has to fire before a single cycle is
# simulated, for whichever depth the bench is configured with.
run_neg "fifo: DEPTH parameter check" rtl/fifo.sv \
  'assert ((DEPTH >= 2) && ((DEPTH & (DEPTH - 1)) == 0))' \
  'assert ((DEPTH >= 9) && ((DEPTH & (DEPTH - 1)) == 0))' \
  fifo 'fifo: DEPTH must be a power of two'

echo "== 2. leaf-module clocking SVA =="

# The input port's flit-sequence property: a BODY/TAIL may only arrive while
# the VC is mid-packet. in_pkt is the bookkeeping that says so; closing the
# packet on a HEAD instead of on a TAIL means the BODY of the very first
# multi-flit test packet arrives "while no packet is open".
run_neg "noc_input_port: in_pkt never opens" rtl/noc_input_port.sv \
  '          if (is_head[v]) in_pkt[v] <= !is_last[v];' \
  '          if (is_head[v]) in_pkt[v] <= 1'"'"'b0;' \
  noc_input_port 'flit sequence broken'

# The arbiter must never switch a VC on when the credit pool is empty. Drop
# the credit term from the stage-1 mask and it will.
run_neg "arbiter: stage-1 ignores the credit pool" rtl/arbiter.sv \
  "        if (sa_req[p][v] && (credit_count[o][sa_req_out_vc[p][v]] != '0)) mask[v] = 1'b1;" \
  "        if (sa_req[p][v]) mask[v] = 1'b1;" \
  arbiter 'arbiter:'

# The VC-matched property itself (linnea_v2 section 4.5): a grant on input
# VC gv must reserve output VC gv.
#
# This one is worth its own case precisely because it looks untestable. The
# row stage builds its candidate mask from the row's own index k, so today
# the two indices cannot disagree -- an assertion a reviewer could fairly
# call tautological. Hand the row the NEXT output VC instead and the sideband
# immediately reports a partner one slot along on every grant: the packet
# would be reserved against the wrong downstream VC, and this is the only
# place in the file that can see it, because everything downstream either
# registers the signal once or derives from it. If the message never
# appears here, the property really is only holding by accident.
run_neg "arbiter: grant reserves a neighbouring output VC" rtl/arbiter.sv \
  '          va_gnt_out_vc[row_pidx[o][k]][k] = VC_W'"'"'(k);' \
  '          va_gnt_out_vc[row_pidx[o][k]][k] = VC_W'"'"'((k + 1) % NUM_VC);' \
  arbiter 'reserved output vc'

# The crossbar must drive an output with the data of the input it selected.
run_neg "crossbar: data mux reads the port next to the winner" rtl/crossbar.sv \
  '        d = xbar_in_data[xbar_sel[o]];' \
  "        d = xbar_in_data[3'((int'(xbar_sel[o]) + 1) % NUM_PORTS)];" \
  crossbar 'does not track its selection'

# The header merge must write route_next into [13:10] of a HEAD.
run_neg "noc_output_port: header merge never happens" rtl/noc_output_port.sv \
  '    if (xbar_out_data[0]) begin' "    if (1'b0) begin" \
  noc_output_port 'noc_output_port: HEAD route not updated'

echo "== 3. top-level seam SVA =="

# The two "absent port" seam properties are vacuous under tb_router_top --
# that bench ties all five ports present -- so this case runs against the
# three-router chain, where A has no west link and nobody has a north or
# south link. credit_return_valid[p] is a per-port fold of the input port's
# fetch, and its only consumer is the neighbour that is not there on an edge
# port; replacing the fold with a constant is exactly the "simplify the tie"
# edit the property was written to catch. It fires on the first posedge out
# of reset, long before the phantom credits could reach an arbiter's own
# overflow check.
run_neg "router_top: credits returned on a link that does not exist" rtl/router_top.sv \
  '      assign credit_return_valid[p] = l_credit_return;' \
  "      assign credit_return_valid[p] = '1;" \
  router_chain 'has no link but returned credits'

rm -rf obj_dir/v_neg
