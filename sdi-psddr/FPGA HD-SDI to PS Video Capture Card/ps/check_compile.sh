#!/bin/sh
# ============================================================================
# check_compile.sh -- ps/ 目录下的 C 代码编译检查（不产生可执行文件）
#
# 为什么需要它：这台开发机上没有 arm-linux-gnueabihf-gcc，但有 WSL2 Ubuntu，
# 里面是 x86_64 的 gcc 15.2.0。**目标码不同，但语法/类型/接口检查一样有效** ——
# 抓到的是拼错、漏 include、字段名写错、类型不匹配这类问题，
# 这些跟最终跑在 ARM 上还是 x86 上无关。真正跟目标平台有关的
# （DMA 一致性、cache 对齐、原子性）仍然只能上板验。
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
CFLAGS="-c -Wall -Wextra -Wpedantic -Wshadow -Wconversion -std=gnu11"

echo "=== compiler ==="
$CC --version | head -1

echo
echo "=== sdi_cap.h as a translation unit ==="
$CC -fsyntax-only $CFLAGS -x c "$HERE/sdi_cap.h"
echo "  ok"

echo
echo "=== sdi_cap.c ==="
$CC $CFLAGS -o "$OUT/sdi_cap.o" "$HERE/sdi_cap.c"
echo "  ok"

echo
echo "ALL CLEAN"