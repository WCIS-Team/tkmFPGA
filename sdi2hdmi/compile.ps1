# compile.ps1 -- synth + implement + bitstream for sdi2hdmi.
#
# Vivado is on this machine only (the school box has no Vivado), so this runs
# here. ASCII-only on purpose: Windows PowerShell 5.1 reads .ps1 with the ANSI
# code page, and a stray non-ASCII byte surfaces as a confusing ParserError.
#
# Retry is not paranoia, it is a workaround for a real fault on this machine.
# Vivado intermittently fails to read one of its OWN internal macro files:
#   couldn't read file ".../scripts/rt/data/unimacro/unimacro_vhdl.tcl": No error
# The file is present, PowerShell reads it, and Vivado reads it fine on other
# runs; which of the two macro files it names changes from run to run. Vivado
# itself lives on the S: drive, which also shows the same intermittency from
# PowerShell (Test-Path returning False for files that exist). So: single
# thread, and retry.
#
# Usage:
#   compile.ps1                 full flow
#   compile.ps1 -SynthOnly      stop after synthesis and its reports
#   compile.ps1 -Tries 5        allow more retries

param(
    [int]$Jobs = 1,
    [int]$Tries = 3,
    [switch]$SynthOnly
)

$ErrorActionPreference = 'Stop'

$Vivado = 'S:\apps\Xilinx\Vivado\2018.3\bin\vivado.bat'
if (-not (Test-Path $Vivado)) { throw "vivado not found at $Vivado" }

$Root = $PSScriptRoot
Set-Location $Root

$tcl = if ($SynthOnly) { 'build_synth.tcl' } else { 'build.tcl' }
$log = Join-Path $Root 'build.log'
$vout = Join-Path $Root 'vout.txt'

$rc = -1
for ($try = 1; $try -le $Tries; $try++) {
    $env:JOBS = $Jobs
    if (Test-Path $log) { Remove-Item $log -Force }

    Write-Host ''
    Write-Host "=== attempt $try/$Tries : $tcl (jobs=$Jobs) ==="
    cmd /c "`"$Vivado`" -mode batch -nojournal -notrace -log vlog.log -source $tcl > vout.txt 2>&1"
    $rc = $LASTEXITCODE

    # The macro-file fault truncates the log with no ERROR line and a -1 exit.
    # Detect it explicitly instead of trusting the exit code alone.
    $unimacro = Select-String -Path $vout -Pattern 'unimacro_.*\.tcl' -Quiet -ErrorAction SilentlyContinue
    if ($rc -eq 0) {
        Write-Host '    ok'
        break
    }
    if ($unimacro) {
        Write-Host "    vivado could not read its own unimacro file (attempt $try). Retrying."
        Start-Sleep -Seconds 10
        continue
    }
    break
}

Get-Content $vout -ErrorAction SilentlyContinue |
    Where-Object { $_ -match 'ERROR|BUILD:|INBB|CRITICAL WARNING' } |
    Select-Object -Last 25 | ForEach-Object { Write-Host $_ }

Write-Host ''
if ($rc -ne 0) {
    Write-Host "BUILD FAILED (exit $rc). Tail of vout.txt:"
    Get-Content $vout -Tail 25 -ErrorAction SilentlyContinue | ForEach-Object { Write-Host "  $_" }
    exit $rc
}

# Report the numbers that decide whether this design is viable at all.
$util = Join-Path $Root 'dist\utilization_routed.rpt'
$tim  = Join-Path $Root 'dist\timing_routed.rpt'

if (Test-Path $tim) {
    Write-Host '--- timing ---'
    Select-String -Path $tim -Pattern 'WNS\(ns\)|Design Timing Summary' -Context 0,4 |
        Select-Object -First 2 | ForEach-Object { $_.Line; $_.Context.PostContext }
}
if (Test-Path $util) {
    Write-Host '--- resources ---'
    Select-String -Path $util -Pattern 'Slice LUTs|Slice Registers|Block RAM Tile|DSPs|MMCM|BUFGCTRL|OSERDES|BRAM' |
        Select-Object -First 12 | ForEach-Object { $_.Line.Trim() }
}
Write-Host ''
Write-Host 'bitstream:'
Get-ChildItem (Join-Path $Root 'dist') -Filter '*.bit' -ErrorAction SilentlyContinue |
    ForEach-Object { Write-Host "  $($_.Name)  $($_.Length) bytes" }