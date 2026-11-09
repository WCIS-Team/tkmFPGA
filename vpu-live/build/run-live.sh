#!/usr/bin/bash
# run-live.sh -- MSYS coreutils are not on PATH when bash.exe is invoked directly by ssh,
# so export it before handing off. No quoting needed on the ssh command line.
export PATH="/d/yzd/MSYS2/usr/bin:/d/yzd/MSYS2/mingw64/bin:/c/Windows:/c/Windows/System32"
exec /d/yzd/MSYS2/usr/bin/bash.exe /d/yzd/WCIS/crosswin/build-live.sh
