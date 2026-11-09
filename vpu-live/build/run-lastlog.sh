#!/usr/bin/bash
export PATH="/d/yzd/MSYS2/usr/bin:/c/Windows:/c/Windows/System32"
L=$(ls -t /d/yzd/WCIS/crosswin/logs/build-live-*.log | head -1)
cp "$L" /d/yzd/WCIS/crosswin/logs/last.log
echo "SRC=$L"
