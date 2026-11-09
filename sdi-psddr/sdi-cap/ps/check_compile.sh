#!/bin/sh
# ============================================================================
# check_compile.sh -- ps/ 目录下的 C 代码编译检查
#
# 为什么需要它：本机没有 aarch64 gcc，但有 WSL2 Ubuntu，里面是 x86_64 的
# gcc 15.2.0。**目标码不同，但语法/类型/接口检查一样有效** —— 抓到的是
# 拼错、漏 include、字段名写错、类型不匹配、原型丢失这类问题，
# 这些跟最终跑在 ARM 上还是 x86 上无关。真正跟目标平台有关的
# （DMA 一致性、cache 对齐、原子性）仍然只能上板验。
#
# ★ 2026-11-10 修 ★ 旧版只编了**不带 SDI_CAP_DEMO** 的 sdi_cap.c——
# 那条路径把 main() 整个 #ifdef 掉了，demo 里 ~1/3 的代码（抓帧策略、
# udmabuf 探测、打印格式）从来没有被任何编译器看过。现在：
#   1. 两遍都编（库形态 + demo 形态）；
#   2. demo 形态做真实链接（main() 在，能抓符号丢失/原型不一致）；
#   3. 加 -Wmissing-prototypes/-Wstrict-prototypes/-Wformat=2 ——
#      库和 demo 都要过全套严格警告。
#
# 用法：
#   wsl -e sh /mnt/c/.../ps/check_compile.sh
#   从 WSL 里：  sh check_compile.sh
#
# 退出码：0 = 干净通过；非 0 = 有错或警告。
# ============================================================================
set -e

HERE=$(cd "$(dirname "$0")" && pwd)
OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT

CC=${CC:-gcc}
CFLAGS="-Wall -Wextra -Wpedantic -Wshadow -Wconversion \
        -Wmissing-prototypes -Wstrict-prototypes -Wformat=2 \
        -Wtype-limits -std=gnu11"

echo "=== compiler ==="
$CC --version | head -1

echo
echo "=== sdi_cap.h as a translation unit ==="
$CC -fsyntax-only $CFLAGS -x c "$HERE/sdi_cap.h"
echo "  ok"

echo
echo "=== sdi_cap.c (library form, no demo main) ==="
$CC $CFLAGS -c -o "$OUT/sdi_cap.o" "$HERE/sdi_cap.c"
echo "  ok"

echo
echo "=== sdi_cap.c (demo form with main(), real link) ==="
$CC $CFLAGS -DSDI_CAP_DEMO -o "$OUT/demo" "$HERE/sdi_cap.c"
echo "  ok"

echo
echo "ALL CLEAN"
