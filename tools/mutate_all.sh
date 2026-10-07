#!/usr/bin/env bash
set -u
cd /home/rohith/Projects/NoC
run_mut () {
  local name="$1" file="$2" old="$3" new="$4"
  cp "$file" /tmp/opencode/mut.bak
  if ! grep -qF -- "$old" "$file"; then echo "SKIP  $name (pattern not found)"; cp /tmp/opencode/mut.bak "$file"; return; fi
  if ! python3 - "$file" "$old" "$new" <<'PY'
import sys
f, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(f).read()
assert s.count(old) == 1, f"pattern occurs {s.count(old)}x"
open(f, 'w').write(s.replace(old, new))
PY
  then echo "SKIP  $name (pattern not unique)"; cp /tmp/opencode/mut.bak "$file"; return; fi

  rm -rf obj_dir/v_mut
  if ! verilator --binary --timing --trace -Wall -Wno-BLKSEQ -Wno-WIDTHEXPAND \
       -Wno-UNUSEDSIGNAL -sv --top-module tb_router_top -Mdir obj_dir/v_mut -o run \
       rtl/*.sv tb/tb_router_top.sv > /tmp/opencode/mut.build 2>&1; then
    echo "ERROR $name (build failed)"; tail -4 /tmp/opencode/mut.build
    cp /tmp/opencode/mut.bak "$file"; return
  fi
  local out
  out=$(./obj_dir/v_mut/run 2>&1 | grep -E "CHECKS (PASSED|FAILED)" | tail -1)
  if echo "$out" | grep -q "PASSED"; then echo "SURVIVED  $name   ($out)"
  else echo "killed    $name   ($out)"; fi
  cp /tmp/opencode/mut.bak "$file"
}

run_mut "route_compute: XY direction inverted" rtl/route_compute.sv \
  'compute_dir = (tgt_x > cur_x) ? DIR_EAST : DIR_WEST;' \
  'compute_dir = (tgt_x > cur_x) ? DIR_WEST : DIR_EAST;'
run_mut "arbiter: stage-2 round-robin ignores its pointer" rtl/arbiter.sv \
  '      int unsigned idx = (start + i) % NUM_PORTS;' \
  '      int unsigned idx = i;'
run_mut "noc_input_port: grant wins over fetch (section 9)" rtl/noc_input_port.sv \
"        if (fetch[v]) begin
          head_valid[v] <= 1'b1;
        end
        else if (sa_gnt[v]) begin
          head_valid[v] <= 1'b0;
        end" \
"        if (sa_gnt[v]) begin
          head_valid[v] <= 1'b0;
        end
        else if (fetch[v]) begin
          head_valid[v] <= 1'b1;
        end"
run_mut "arbiter: stage-1 ignores the credit pool" rtl/arbiter.sv \
  "        if (sa_req[p][v] && (credit_count[o][sa_req_out_vc[p][v]] != '0)) mask[v] = 1'b1;" \
  "        if (sa_req[p][v]) mask[v] = 1'b1;"
run_mut "crossbar: data mux reads the port next to the winner" rtl/crossbar.sv \
  '        d = xbar_in_data[xbar_sel[o]];' \
  "        d = xbar_in_data[3'((int'(xbar_sel[o]) + 1) % NUM_PORTS)];"
# The merge writes a constant direction instead of route_next. Only headers
# may be touched and only [13:10], so this has to be caught by the bench:
# builds here run WITHOUT --assert, the property that says
# `merged[13:10] == xbar_out_route_next` is not what is being tested.
run_mut "noc_output_port: header route field merged with the wrong direction" rtl/noc_output_port.sv \
  '    merged[13:10] = xbar_out_route_next;' '    merged[13:10] = 4'"'"'b0100;'
rm -rf obj_dir/v_mut
