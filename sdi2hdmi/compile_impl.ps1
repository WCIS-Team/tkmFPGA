# compile_impl.ps1 -- opt/place/route/bitstream from the post-synthesis checkpoint.
#
# Separate from compile.ps1 because of a fault on this machine, not in the
# design: the Vivado install intermittently loses visibility of its own runtime
# scripts, and dies with exit code -1 and a truncated log at a different phase
# on every run. Synthesis is the longest phase and so the most likely place to
# hit it. Doing it once and resuming from .build/post_synth.dcp reuses that work
# instead of paying for it again on each retry.
#
# Retry is still needed, just over a much shorter run.
#
# Usage:
#   compile_impl.ps1            up to 4 attempts
#   compile_impl.ps1 -Tries 10  more attempts

param([int]$Tries = 4)

$ErrorActionPreference = 'Stop'

$Vivado = 'S:\apps\Xilinx\Vivado\2018.3\bin\vivado.bat'
$Root   = $PSScriptRoot
Set-Location $Root

$vout = Join-Path $Root 'vout_impl.txt'

$rc = -1
for ($try = 1; $try -le $Tries; $try++) {
    Write-Host ''
    Write-Host "=== impl attempt $try/$Tries ==="
    cmd /c "`"$Vivado`" -mode batch -nojournal -notrace -log vlog_impl.log -source impl_only.tcl > vout_impl.txt 2>&1"
    $rc = $LASTEXITCODE
    if ($rc -eq 0) { Write-Host '    ok'; break }
    Write-Host "    attempt $try failed (exit $rc)"
    Start-Sleep -Seconds 8
}

Get-Content $vout -ErrorAction SilentlyContinue |
    Where-Object { $_ -match 'ERROR|IMPL:|DRC finished|Route Status' } |
    Select-Object -Last 25 | ForEach-Object { Write-Host $_ }

Write-Host ''
if ($rc -ne 0) {
    Write-Host "IMPL FAILED (exit $rc). Tail:"
    Get-Content $vout -Tail 20 -ErrorAction SilentlyContinue | ForEach-Object { Write-Host "  $_" }
    exit $rc
}

Write-Host 'bitstream:'
Get-ChildItem (Join-Path $Root 'dist') -Filter '*.bit' -ErrorAction SilentlyContinue |
    ForEach-Object { Write-Host "  $($_.Name)  $($_.Length) bytes" }