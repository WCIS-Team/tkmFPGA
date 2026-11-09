#!/bin/bash
# Focused re-run after the frame-phase model fix + the in_hs seed fix.
set -u
export PATH="/mingw64/bin:/usr/bin:/bin:$PATH"
cd "$(dirname "$0")/.." || exit 1

echo "=== rebuild harness (frame-phase model + in_hs seed) ==="
rm -rf obj_harness
verilator --cc --exe --build -j 8 -CFLAGS "-O2" \
    -Wno-fatal -Wno-WIDTHEXPAND -Wno-UNUSEDSIGNAL -Wno-UNDRIVEN \
    --top-module vlt_top -Mdir obj_harness -o harness \
    rtl/sdi2hdmi/scaler_720.v rtl/sdi2hdmi/hdmi_out.v sim/vlt_top.v sim/harness.cpp 2>&1 \
    | grep -E "%Error|error:" | head -20
[ -x obj_harness/harness ] || { echo "BUILD FAILED"; exit 1; }
echo "harness built"
OUT=out
mkdir -p $OUT
run() { # name, args...
  local name="$1"; shift
  local log="$OUT/focus_$(echo "$name" | tr " /" "__").log"
  ./obj_harness/harness "$@" > "$log" 2>&1
  local rc=$?
  local last
  last=$(grep -E 'PASS:|FAIL ' "$log" | tail -1)
  printf '%-46s rc=%d  %s\n' "$name" "$rc" "$last"
}

echo "=== real video (frame-phase model now crosses the frame boundary) ==="
run "BBB 30 frames"     --src data/frames/bbb.rgb565 --frames 30
run "park_joy 12"       --src data/frames/parkjoy.rgb565 --frames 12

echo "=== events, with per-frame state ==="
run "reset mid-frame"   --pattern ramp --frames 10 --reset-frame 6 --diag
run "unlock 5-6 relock" --pattern noise --frames 12 --unlock-at 5 --unlock-len 2 --diag
run "geometry change"   --pattern noise --frames 12 --geom2 1440x1080x2475x1125 --geom2-at 5 --diag
run "blanking change"   --pattern noise --frames 12 --geom2 1920x1080x2250x1100 --geom2-at 5 --diag

echo "=== cam_vs edge phase (diagnostic) ==="
for x in 0 1 2 8 64 200 1000 1919 1920; do
  log="$OUT/focus_vsx_$x.log"
  ./obj_harness/harness --pattern noise --frames 6 --vs-rise-x $x > "$log" 2>&1
  rc=$?
  best=$(grep -oE 'best per golden: [0-9]+' "$log" | head -1 | grep -oE '[0-9]+')
  geo=$(grep -oE 'measured [0-9]+x[0-9]+' "$log" | tail -1)
  printf 'vs-rise-x=%-5s rc=%d  best=%s  %s\n' "$x" "$rc" "${best:-0}" "$geo"
done

