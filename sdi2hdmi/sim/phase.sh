#!/bin/bash
# What does the source-vs-reader frame phase cost?
#
# On the board the HDMI raster starts with rst_n while the SDI source starts
# whenever the camera does, so their frame boundaries land at an arbitrary
# relative phase. This sweeps that phase and measures the damage.
#
# frame period = 1125 x 2200 = 2 475 000 cam clocks
set -u
export PATH="/mingw64/bin:/usr/bin:/bin:$PATH"
cd "$(dirname "$0")/.." || exit 1

echo "=== A. source-vs-reader frame phase sweep (noise, 8 frames, frame 4+ checked) ==="
printf '%-10s %-8s %-9s %-9s %-9s %-9s %s\n' phase rc srcWrong dropped held phaseErr verdict
for n in 0 100000 300000 600000 1200000 1800000 2100000 2400000; do
  log=out/phase_$n.log
  ./obj_harness/harness --pattern noise --frames 8 --diag --start-phase $n > $log 2>&1
  rc=$?
  # rows dropped / held / capture frames, summed over the checked frames
  drop=$(grep -oE 'dropped +\+[0-9]+' $log | grep -oE '[0-9]+' | awk '{s+=$1} END {print s+0}')
  held=$(grep -oE 'held +\+[0-9]+' $log | grep -oE '[0-9]+' | awk '{s+=$1} END {print s+0}')
  wrong=$(grep -oE 'best per golden: [0-9]+' $log | head -1 | grep -oE '[0-9]+')
  ph=$(grep -oE 'capture line 0 holds golden line [0-9]+' $log | head -1 | grep -oE '[0-9]+$')
  v=$(grep -oE '^(PASS|FAIL)' $log | head -1)
  printf '%-10s %-8s %-9s %-9s %-9s %-9s %s\n' "$n" "$rc" "${wrong:-0}" "$drop" "$held" "${ph:--}" "$v"
done

echo
echo "=== B. geometry change that PRESERVES the active-window duration ==="
echo "    (active window = active_lines x total_width cam clocks; the reader"
echo "     needs 720 x 3300 = 2 376 000, so 1080 x 2200 is the only legal 1080-line fit)"
for g in 1440x1080x2200x1125 1920x1080x2200x1200; do
  log=out/geom_$g.log
  ./obj_harness/harness --pattern noise --frames 10 --diag --geom2 $g --geom2-at 5 > $log 2>&1
  rc=$?
  v=$(grep -oE '^(PASS|FAIL)' $log | head -1)
  printf '  --geom2 %-20s rc=%d  %s\n' "$g" "$rc" "$v"
done

echo
echo "=== C. same change WITHOUT preserving it (measured, not a pass/fail) ==="
for g in 1440x1080x2475x1125 1920x1080x2250x1100; do
  log=out/geom_$g.log
  ./obj_harness/harness --pattern noise --frames 10 --diag --geom2 $g --geom2-at 5 > $log 2>&1
  rc=$?
  bad=$(grep -oE 'wrong rows [0-9]+' $log | head -1 | grep -oE '[0-9]+')
  drop=$(grep -oE 'dropped +\+[0-9]+' $log | grep -oE '[0-9]+' | awk '{s+=$1} END {print s+0}')
  held=$(grep -oE 'held +\+[0-9]+' $log | grep -oE '[0-9]+' | awk '{s+=$1} END {print s+0}')
  printf '  --geom2 %-20s rc=%d  wrong rows %s/720  dropped %s  held %s\n' "$g" "$rc" "${bad:--}" "$drop" "$held"
done
