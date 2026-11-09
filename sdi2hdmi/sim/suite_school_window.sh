#!/bin/bash
# ---------------------------------------------------------------------------
# How much source-vs-raster frame misalignment can the line-slot ring absorb?
#
# The ring has 8 line slots.  The raster's frame boundary and the source's
# frame boundary are independent; the offset between them is what this script
# sweeps, by holding the source blank for N cam clocks before its frame 0.
#
#   1 row        = 3300 cam clocks   (the reader takes one row per 1650 rclk)
#   1 frame      = 2475000 cam clocks
#   the ring     = +/-8 rows = +/-26400 cam clocks
#
# steadyDrop/steadyHeld are the average of the LAST FOUR per-frame diag lines,
# i.e. the steady state, not the startup transient (which always holds ~1
# frame's worth of pixels while the scaler measures the geometry).
# ---------------------------------------------------------------------------
export PATH="/mingw64/bin:/usr/bin:/bin:$PATH"
cd "$(dirname "$0")/.." || exit 1

printf '%-10s %-4s %-11s %-11s %-11s %s\n' phase rc wrongpx steadyDrop steadyHeld verdict
for n in 0 1000 5000 10000 20000 26000 26400 27000 30000 50000 100000 1237500 2400000 2448000 2465000 2474000; do
  ./obj_harness/harness --pattern noise --frames 12 --diag --start-phase $n > out/_w.log 2>&1
  rc=$?
  wrong=$(grep -oE 'best per golden: [0-9]+' out/_w.log | head -1 | grep -oE '[0-9]+')
  sd=$(grep -oE 'dropped +\+[0-9]+' out/_w.log | grep -oE '[0-9]+' | tail -4 | awk '{s+=$1} END {printf "%d", s/4}')
  sh=$(grep -oE 'held +\+[0-9]+' out/_w.log | grep -oE '[0-9]+' | tail -4 | awk '{s+=$1} END {printf "%d", s/4}')
  v=$(grep -oE '^(PASS|FAIL)' out/_w.log | head -1)
  printf '%-10s %-4s %-11s %-11s %-11s %s\n' "$n" "$rc" "${wrong:-0}" "$sd" "$sh" "$v"
done
