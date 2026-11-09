#!/bin/bash
# ---------------------------------------------------------------------------
# sdi2hdmi second verification suite -- school machine, Verilator.
#
# Round 2. Two things changed since the first suite:
#   * the frame-phase verdict now models the offset CROSSING a frame boundary
#     (the reader's window starts a line or two before the producer's frame
#     boundary, so its top rows belong to the PREVIOUS frame). Synthetic
#     patterns cannot see that; real video can, and did.
#   * the ring's alignment is now an explicit axis. It turns out to be
#     BISTABLE: power-on converges to zero loss at every source phase tested,
#     but a mid-frame reset parks it at a permanent 23-rows-per-frame loss.
#
# Every run compares the DISPLAYED frame against the specification model.
# ---------------------------------------------------------------------------
export PATH="/mingw64/bin:/usr/bin:/bin:$PATH"
cd "$(dirname "$0")/.." || exit 1

LOG=out/suite2_full.log
SUM=out/suite2_summary.txt
: > "$LOG"; : > "$SUM"

run () {
    name="$1"; shift
    ./obj_harness/harness "$@" > out/_one.log 2>&1
    rc=$?
    verdict=$(grep -m1 -E '^PASS|^FAIL' out/_one.log)
    printf '%-52s rc=%s  %s\n' "$name" "$rc" "$verdict" | tee -a "$SUM"
    { echo "########## $name   [$*]   rc=$rc"; cat out/_one.log; echo; } >> "$LOG"
}

echo "=== real video (the case synthetic patterns cannot reach) ==="
run "BBB 1080p H.264, 30 frames"  --src data/frames/bbb.rgb565     --frames 30
run "BBB 1080p H.264, 60 frames"  --src data/frames/bbb.rgb565     --frames 60
run "park_joy 1080p50, 12 frames" --src data/frames/parkjoy.rgb565 --frames 12

echo "=== extreme patterns ==="
for p in tb_e2e black white gray ramp checker1 checker2 vlines hline dot noise extreme; do
    run "pattern $p" --pattern $p --frames 4
done

echo "=== long runs ==="
run "60 frames, ramp"   --pattern ramp  --frames 60
run "60 frames, noise"  --pattern noise --frames 60

echo "=== event recovery ==="
run "unlock frames 5-6 then relock"    --pattern noise --frames 12 --unlock-at 5 --unlock-len 2
run "geometry 1920x1080 -> 1440x1080"  --pattern noise --frames 12 --geom2 1440x1080x2200x1125 --geom2-at 5
run "reset mid-frame at 6"             --pattern noise --frames 24 --reset-frame 6 --diag
run "reset 6 then unlock 12-13"        --pattern noise --frames 24 --reset-frame 6 --unlock-at 12 --unlock-len 2 --diag
run "reset 6 then geometry change 12"  --pattern noise --frames 24 --reset-frame 6 --geom2 1440x1080x2200x1125 --geom2-at 12 --diag

echo "=== ring alignment: what the power-on sequence rolls ==="
echo "    source held blank for N cam clocks before frame 0 (frame period 2 475 000)"
printf '%-10s %-6s %-12s %-10s %-10s %-8s %s\n' phase rc wrongpx dropped held phaseErr verdict | tee -a "$SUM"
for n in 0 100000 300000 600000 1200000 1800000 2100000 2400000; do
    ./obj_harness/harness --pattern noise --frames 8 --diag --start-phase $n > out/_one.log 2>&1
    rc=$?
    drop=$(grep -oE 'dropped +\+[0-9]+' out/_one.log | grep -oE '[0-9]+' | awk '{s+=$1} END {print s+0}')
    held=$(grep -oE 'held +\+[0-9]+' out/_one.log | grep -oE '[0-9]+' | awk '{s+=$1} END {print s+0}')
    wrong=$(grep -oE 'best per golden: [0-9]+' out/_one.log | head -1 | grep -oE '[0-9]+')
    ph=$(grep -oE 'capture line 0 holds golden line [0-9]+' out/_one.log | head -1 | grep -oE '[0-9]+$')
    v=$(grep -oE '^(PASS|FAIL)' out/_one.log | head -1)
    printf '%-10s %-6s %-12s %-10s %-10s %-8s %s\n' "$n" "$rc" "${wrong:-0}" "$drop" "$held" "${ph:--}" "$v" | tee -a "$SUM"
    { echo "########## start-phase $n   rc=$rc"; cat out/_one.log; echo; } >> "$LOG"
done

echo "=== active-window / frame-period boundaries (measured, not pass/fail) ==="
for g in 1920x1080x2200x1125 1440x1080x2200x1125 1920x1080x2250x1100 1920x1080x2200x1200 1920x1080x2376x1125 1280x720x1650x750; do
    ./obj_harness/harness --pattern noise --frames 10 --diag --geom2 $g --geom2-at 4 > out/_one.log 2>&1
    rc=$?
    v=$(grep -oE '^(PASS|FAIL)' out/_one.log | head -1)
    drop=$(grep -oE 'dropped +\+[0-9]+' out/_one.log | grep -oE '[0-9]+' | awk '{s+=$1} END {print s+0}')
    held=$(grep -oE 'held +\+[0-9]+' out/_one.log | grep -oE '[0-9]+' | awk '{s+=$1} END {print s+0}')
    bad=$(grep -oE 'wrong rows [0-9]+' out/_one.log | head -1 | grep -oE '[0-9]+')
    aw=$(( $(echo $g | cut -dx -f3) * $(echo $g | cut -dx -f2) ))
    fp=$(( $(echo $g | cut -dx -f3) * $(echo $g | cut -dx -f4) ))
    printf '  %-20s active-window %8d  frame %8d  rc=%d  %-5s wrong rows %s/720  dropped %s  held %s\n' \
        "$g" "$aw" "$fp" "$rc" "${v#*:}" "${bad:--}" "$drop" "$held" | tee -a "$SUM"
done

echo "=== cam_vs edge phase (raster sensitivity, measured) ==="
printf '%-14s %-6s %-10s %s\n' vs-rise-x rc wrongpx geometry | tee -a "$SUM"
for x in 0 1 2 8 64 200 1000 1919 1920 2000; do
    ./obj_harness/harness --pattern noise --frames 6 --vs-rise-x $x > out/_one.log 2>&1
    rc=$?
    best=$(grep -oE 'best per golden: [0-9]+' out/_one.log | head -1 | grep -oE '[0-9]+')
    geo=$(grep -oE 'measured [0-9]+x[0-9]+' out/_one.log | tail -1)
    printf '%-14s %-6s %-10s %s\n' "$x" "$rc" "${best:-0}" "$geo" | tee -a "$SUM"
done

echo
echo "================ summary ================"
cat "$SUM"
