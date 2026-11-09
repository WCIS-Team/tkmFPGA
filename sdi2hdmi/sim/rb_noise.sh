#!/bin/bash
# Rebuild the harness after editing harness.cpp, then run the noise probe with
# the source frame dumped alongside the capture. The source dump removes the
# last unknown in the offline inversion: which source frame the captured
# output came from.
export PATH="/mingw64/bin:/usr/bin:/bin:$PATH"
cd "$(dirname "$0")/.." || exit 1

rm -rf obj_harness
verilator --cc --exe --build -j 8 \
    -CFLAGS "-O2" \
    -Wno-fatal -Wno-WIDTHEXPAND -Wno-UNUSEDSIGNAL -Wno-UNDRIVEN \
    --top-module vlt_top \
    -Mdir obj_harness -o harness \
    rtl/sdi2hdmi/scaler_720.v rtl/sdi2hdmi/hdmi_out.v sim/vlt_top.v sim/harness.cpp 2>&1 \
    | grep -E '%Error|error:|Error:' | head -12
ls -la obj_harness/harness.exe 2>&1 | tail -1
[ -x obj_harness/harness.exe ] || { echo "BUILD FAILED"; exit 1; }

echo "=== noise probe ==="
./obj_harness/harness --pattern noise --frames 2 --dump out/nz --dumpsrc out/nzs 2>&1 | head -8
ls -la out/nz*.bin
