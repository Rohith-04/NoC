set -u
cd /home/rohith/Projects/NoC
run_mut () {
  local name="$1" file="$2" old="$3" new="$4"
  cp "$file" /tmp/opencode/mut.bak
  if ! grep -qF -- "$old" "$file"; then echo "SKIP  $name"; cp /tmp/opencode/mut.bak "$file"; return; fi
  if ! python3 - "$file" "$old" "$new" <<'PY'
import sys
f, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(f).read(); assert s.count(old) == 1, s.count(old)
open(f, 'w').write(s.replace(old, new))
PY
  then echo "SKIP  $name (not unique)"; cp /tmp/opencode/mut.bak "$file"; return; fi
  rm -rf obj_dir/v_mut
  if ! verilator --binary --timing --trace -Wall -Wno-BLKSEQ -Wno-WIDTHEXPAND -Wno-UNUSEDSIGNAL -sv \
      --top-module tb_router_top -Mdir obj_dir/v_mut -o run rtl/*.sv tb/tb_router_top.sv \
      > /tmp/opencode/mut.build 2>&1; then
    echo "ERROR $name (build)"; tail -3 /tmp/opencode/mut.build; cp /tmp/opencode/mut.bak "$file"; return; fi
  local out; out=$(./obj_dir/v_mut/run 2>&1 | grep -E "CHECKS (PASSED|FAILED)" | tail -1)
  if echo "$out" | grep -q PASSED; then echo "SURVIVED  $name   ($out)"; else echo "killed    $name   ($out)"; fi
  cp /tmp/opencode/mut.bak "$file"
}
run_mut "noc_output_port: route merge never happens" rtl/noc_output_port.sv \
  '    if (xbar_out_data[0]) begin' '    if (1'"'"'b0) begin'
run_mut "noc_output_port: route merge applied to every flit" rtl/noc_output_port.sv \
  '    if (xbar_out_data[0]) begin' '    if (1'"'"'b1) begin'
rm -rf obj_dir/v_mut
