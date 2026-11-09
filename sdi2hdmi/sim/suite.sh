#!/bin/bash
# ---------------------------------------------------------------------------
# Full verification suite for sdi2hdmi, run on the school machine.
#
# Three classes of question, none of which tb_e2e or tb_scaler_720 can answer
# on their own:
#   * real video   -- compression artefacts, motion, a real camera, hundreds of
#                     frames, against an independent model
#   * extremes     -- all-zero, all-max, 1-pixel structure, PRNG noise
#   * events       -- reset mid-frame, source unlock/relock, geometry change
#   * long runs    -- where a producer/consumer rate imbalance accumulates
#
# Every check compares the DISPLAYED frame against the specification model, at
# the best vertical frame phase (hdmi_out's ring occupancy cannot be aligned with
# the producer's line 0 -- see the note in harness.cpp).
# ---------------------------------------------------------------------------
export PATH="/mingw64/bin:/usr/bin:/bin:$PATH"
cd "$(dirname "$0")/.." || exit 1

echo "=== rebuild harness ==="
rm -rf obj_harness
verilator --cc --exe --build -j 8 -CFLAGS "-O2" \
    -Wno-fatal -Wno-WIDTHEXPAND -Wno-UNUSEDSIGNAL -Wno-UNDRIVEN \
    --top-module vlt_top -Mdir obj_harness -o harness \
    rtl/sdi2hdmi/scaler_720.v rtl/sdi2hdmi/hdmi_out.v sim/vlt_top.v sim/harness.cpp 2>&1 \
    | grep -E '%Error|error:' | head -20
[ -x obj_harness/harness.exe ] || { echo "BUILD FAILED"; exit 1; }
echo "harness built"

LOG=out/suite_full.log
SUM=out/suite_summary.txt
: > "$LOG"; : > "$SUM"

run () {
    name="$1"; shift
    ./obj_harness/harness "$@" > out/_one.log 2>&1
    rc=$?
    verdict=$(grep -m1 -E '^PASS|^FAIL' out/_one.log)
    printf '%-52s rc=%s  %s\n' "$name" "$rc" "$verdict" | tee -a "$SUM"
    { echo "########## $name   [$*]   rc=$rc"; cat out/_one.log; echo; } >> "$LOG"
}

echo "--- real video ---" | tee -a "$SUM"
run "BBB 1080p H.264, 30 frames"         --src data/frames/bbb.rgb565      --frames 30
run "park_joy 1080p50 camera, 12 frames" --src data/frames/parkjoy.rgb565 --frames 12

echo "--- extreme patterns ---" | tee -a "$SUM"
for p in tb_e2e black white gray ramp checker1 checker2 vlines hline dot noise extreme; do
    run "pattern $p" --pattern "$p" --frames 4
done

echo "--- events ---" | tee -a "$SUM"
run "reset mid-frame at source frame 6"  --pattern ramp  --frames 10 --reset-frame 6
run "unlock frames 5-6 then relock"      --pattern ramp  --frames 12 --unlock-at 5 --unlock-len 2
run "geometry 1920x1080 -> 1440x1080"    --pattern ramp  --frames 12 --geom2 1440x1080x2200x1125 --geom2-at 6
run "blanking 2200x1125 -> 2250x1100"    --pattern noise --frames 12 --geom2 1920x1080x2250x1100 --geom2-at 6
run "reset + unlock together"            --pattern noise --frames 14 --reset-frame 4 --unlock-at 9 --unlock-len 2
run "reset + geometry change"            --pattern ramp  --frames 14 --reset-frame 4 --geom2 1440x1080x2200x1125 --geom2-at 9

echo "--- long runs ---" | tee -a "$SUM"
run "60 frames, ramp"                    --pattern ramp --frames 60
run "60 frames, noise"                   --pattern noise --frames 60
run "BBB full 60-frame clip"             --src data/frames/bbb.rgb565 --frames 60

# ---------------------------------------------------------------------------
# Source frame rate vs output frame rate.
#
# scamer_720 emits exactly 720 lines per source frame and hdmi_out consumes
# exactly 720 lines per output frame, so the two frame PERIODS have to be equal.
# They are for 1080p60 (2200x1125 at 148.5 MHz = 16.67 ms) and this is the
# design's target. A source at a different rate cannot be shown correctly by a
# line-slot ring with no frame store, and the failure mode is decimation
# (source too fast) or starvation (source too slow) rather than a hang. These
# runs are measured, not judged.
#
# NOT covered: a 720p60 source. It is 60 Hz, so it should work, but it needs
# cam_clk = 74.25 MHz and this harness drives cam_clk at 148.5 MHz with the HDMI
# clock as its half -- a 1:1 relationship that the phase map does not express.
# ---------------------------------------------------------------------------
echo "--- source frame rate vs output (documented limitation, measured) ---" | tee -a "$SUM"
for entry in "1920x1080x2376x1125|1080p50 source: 8% slower than the output" \
             "1280x720x1650x750|720p-class raster at 148.5 MHz: 2x faster"; do
    spec="${entry%%|*}"; note="${entry#*|}"
    echo "    $note  [$spec]" | tee -a "$SUM"
    ./obj_harness/harness --pattern ramp --frames 6 --geom2 "$spec" --geom2-at 2 --no-check > out/_fr.log 2>&1
    grep -E 'scaler locked|scaler lines|stat_dropped|overflow |held pixels' out/_fr.log \
        | sed 's/^/        /' | tee -a "$SUM"
    { echo "##### frame-rate $spec"; cat out/_fr.log; echo; } >> "$LOG"
done

echo "--- cam_vs edge phase (diagnostic, not a pass/fail) ---" | tee -a "$SUM"
echo "    how much does a displaced cam_vs rising edge cost? reported as the" | tee -a "$SUM"
echo "    smallest pixel difference over all 720 frame phases, of 921600."   | tee -a "$SUM"
for x in 0 1 2 8 64 200 1000 1919 1920 2000; do
    ./obj_harness/harness --pattern ramp --frames 2 --vs-rise-x "$x" > out/_vs.log 2>&1
    best=$(grep -oE 'best [0-9]+ of 921600 pixels differ at offset [0-9]+' out/_vs.log | head -1)
    lock=$(grep -oE 'measured [0-9]+x[0-9]+' out/_vs.log | head -1)
    printf '    vs-rise-x=%-5s  %-58s  %s\n' "$x" "${best:-no offset made it match}" "$lock" | tee -a "$SUM"
    { echo "##### vs-rise-x=$x"; cat out/_vs.log; echo; } >> "$LOG"
done

echo
echo "================ summary ================"
cat "$SUM"
