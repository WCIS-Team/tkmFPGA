#!/usr/bin/bash
# build-live.sh -- container-free aarch64 build of the two PS-only VPU tools and the gates
# that decide whether either may be copied to the board.
#
#   bash build-live.sh [TOOLCHAIN_DIR] [KIT_DIR]
# Exit: 0 = both built, all gates pass; 2 = preflight/configure/build failed; 3 = a gate failed.

set -o pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
TC=${1:-/d/yzd/tools/cross/gcc-arm-10.3-2021.07-mingw-w64-i686-aarch64-none-linux-gnu}
KIT=${2:-$HERE/kit}
UAPI=${3:-$HERE/uapi}
MINGW=/d/yzd/MSYS2/mingw64
BUILD=$HERE/build-live
READELF="$TC/bin/aarch64-none-linux-gnu-readelf.exe"
TARGETS="live_sim vpu_jpg"

BOARD_GLIBC_MAX=2.31
BOARD_GLIBCXX_MAX=3.4.28
BOARD_CXXABI_MAX=1.3.11

mkdir -p "$HERE/logs"
LOG=$HERE/logs/build-live-$(date +%Y%m%d_%H%M%S).log
exec > >(tee -a "$LOG") 2>&1
echo "LOG=$LOG"

fail_gate=0
gate() { if [ "$1" = 0 ]; then echo "PASS  $2"; else echo "FAIL  $2"; fail_gate=1; fi; }
w() { cygpath -w "$1"; }
wm() { cygpath -m "$1"; }

echo "=== [0] preflight ==="
for f in "$TC/bin/aarch64-none-linux-gnu-g++.exe" "$READELF" "$MINGW/bin/cmake.exe" "$MINGW/bin/ninja.exe" \
         "$KIT/ModelzooDeps/aarch64/Static/lib/cmake/opencv4/OpenCVConfig.cmake" \
         "$HERE/proj-live/CMakeLists.txt" \
         "$HERE/src-live/include/pipeline/live/vpu_live_core.hpp" \
         "$HERE/src-live/include/pipeline/io/output/stream2segfile.hpp" \
         "$HERE/src-live/3p/spdlog/spdlog.h" \
         "$HERE/src-live/src/live_sim.cpp" "$HERE/src-live/src/vpu_jpg.cpp" \
         "$UAPI/usr/include/linux/videodev2.h" "$HERE/ref/board-libs.txt"; do
  [ -e "$f" ] || { echo "FATAL missing: $f"; exit 2; }
done
echo "all preflight paths present"

echo "=== [1] versions ==="
export PATH="$TC/bin:$MINGW/bin:$PATH"
aarch64-none-linux-gnu-g++.exe --version | head -1
cmake.exe --version | head -1

echo "=== [2] configure ==="
export CROSSWIN_TC="$(wm "$TC")"
rm -rf "$BUILD"
cmake.exe -G Ninja -S "$(w "$HERE/proj-live")" -B "$(w "$BUILD")" \
  -DCMAKE_TOOLCHAIN_FILE="$(w "$HERE/cmake/crosswin-toolchain.cmake")" \
  -DCROSSWIN_TC="$(wm "$TC")" \
  -DCROSSWIN_KIT="$(wm "$KIT")" \
  -DCROSSWIN_SRC="$(wm "$HERE/src-live")" \
  -DCROSSWIN_UAPI="$(wm "$UAPI")" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_POLICY_VERSION_MINIMUM=3.5
rc=$?
[ $rc = 0 ] || { echo "CONFIGURE FAILED rc=$rc"; exit 2; }

echo "=== [3] build ==="
for t in $TARGETS; do
  echo "-- $t"
  cmake.exe --build "$(w "$BUILD")" -j 8 -- "$t" || { echo "BUILD FAILED $t"; exit 2; }
done

for t in $TARGETS; do
  BIN=$(find "$BUILD" -maxdepth 1 -type f -name "$t" | head -1)
  [ -n "$BIN" ] || { echo "no binary for $t"; exit 2; }
  echo
  echo "=== [$t] ==="
  sz=$(stat -c %s "$BIN")
  echo "BIN=$BIN SIZE=$sz"

  echo "--- arch"
  "$READELF" -h "$BIN" | grep -E 'Class:|Machine:|Type:'
  "$READELF" -h "$BIN" | grep -q 'Class: *ELF64' && \
  "$READELF" -h "$BIN" | grep -q 'Machine: *AArch64'; gate $? "$t ELF64 + AArch64"

  # -W matters: without it readelf truncates long entries and the gate goes red on nothing.
  echo "--- DT_NEEDED vs the board rootfs + the kit"
  "$READELF" -W -d "$BIN" | grep -o 'Shared library: *\[[^]]*\]' | sed 's/.*\[\(.*\)\]/\1/' > "$BUILD/$t.needed"
  sed 's/^/    /' "$BUILD/$t.needed"
  unres=0
  while read -r lib; do
    [ -z "$lib" ] && continue
    if grep -qx "$lib" "$HERE/ref/board-libs.txt"; then continue; fi
    if find "$KIT" -name "$lib" -type f | grep -q .; then continue; fi
    echo "    UNRESOLVED at runtime: $lib"; unres=1
  done < "$BUILD/$t.needed"
  gate $unres "$t every DT_NEEDED resolvable on the board"

  echo "--- no icraft dependency (this tool is VPU-only, must not drag the NPU runtime)"
  if grep -q 'icraft' "$BUILD/$t.needed"; then gate 1 "$t free of icraft"; else gate 0 "$t free of icraft"; fi

  echo "--- symbol version ceilings"
  V=$("$READELF" -W -V "$BIN" 2>/dev/null)
  maxver() { echo "$1" | grep -o "$2" | sed "s/$3//" | sort -uV | tail -1; }
  g=$(maxver "$V" 'GLIBC_[0-9.]*'   'GLIBC_')
  x=$(maxver "$V" 'GLIBCXX_[0-9.]*' 'GLIBCXX_')
  a=$(maxver "$V" 'CXXABI_[0-9.]*'  'CXXABI_')
  echo "    wants: GLIBC=$g GLIBCXX=$x CXXABI=$a   board gives: $BOARD_GLIBC_MAX / $BOARD_GLIBCXX_MAX / $BOARD_CXXABI_MAX"
  over() { [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -1)" = "$2" ]; }
  over "${g:-0}" "$BOARD_GLIBC_MAX"; gate $? "$t glibc ceiling <= $BOARD_GLIBC_MAX"
  over "${x:-0}" "$BOARD_GLIBCXX_MAX"; gate $? "$t GLIBCXX ceiling <= $BOARD_GLIBCXX_MAX"
  over "${a:-0}" "$BOARD_CXXABI_MAX"; gate $? "$t CXXABI ceiling <= $BOARD_CXXABI_MAX"

  echo "--- md5 (for the board ledger)"
  md5sum "$BIN"
done

echo "=== result ==="
if [ $fail_gate = 0 ]; then echo "ALL GATES PASS"; exit 0; fi
echo "GATE FAILURE -- see FAIL lines above"; exit 3
