<#
    run_gl_bench.ps1 -- gate-level simulation of sdi_stream_wr.

    Runs the synthesised netlist against the real Xilinx primitive models.
    Written in PowerShell because cmd quoting cannot survive this many nested
    file lists, and because every earlier failure of this flow produced
    misleading output rather than an error.

    Four toolchain traps, all documented in docs/设计说明.md section 6.13:

      1. data\verilog\src\unisim_comp.v is an EMPTY-BOX retarget library. Its
         own header says "unisim_retarget_comp.v" and every primitive is
         declared with no body. It elaborates fine and drives nothing, so
         every netlist output reads as z. The real behavioural models are the
         .v files under unisims\.

      2. xvlog accepts neither a directory argument nor --quiet. The file
         list has to be passed explicitly, in chunks.

      3. Compiled output lives in xsim.dir\work. Deleting xsim.dir between
         steps deletes the primitives you just compiled; it then surfaces much
         later as "Module <LUT6> not found".

      4. FDRE.v references glbl, so glbl.v must be compiled too and passed to
         xelab as a second top unit.

    A fifth trap was added 2026-10-15, PowerShell rather than Vivado: naming a
    function parameter $Args collides with the automatic $Args, so splatting
    @Args passes nothing and Vivado opens its GUI with no arguments. The call
    never returns and looks like a hang. The parameter is $Argv and the log is
    checked for 'start_gui'.

    Everything (primitives, glbl, netlist, testbench) is compiled and
    elaborated in ONE session so trap 3 cannot bite.

    2026-10-15 update, for the 64-bit chain:
      - The tb now instantiates the whole three-stage chain (sdi_px_pack,
        sdi_px_afifo, sdi_stream_wr). Only sdi_stream_wr is synthesised to a
        netlist; the other two are compiled from RTL and run behaviourally.
      - The tb's parameter override on the dut is no longer the old
        `#(.MAX_OUT(MAX_OUT))`, so it is stripped with a regex and the strip
        is asserted. (An exact-string .Replace silently no-op'd once; a netlist
        module cannot accept a parameter override, and xelab would have
        reported it far from the cause.)
      - bench.txt now also pins PX_MHZ/RST_MID so it is byte-identical to the
        behavioural suite B_LAT_32, making the numbers directly comparable.
#>
[CmdletBinding()]
param(
    [int]$Cycles = 200000,
    [string]$Work = (Join-Path $env:TEMP 'opencode\glsim')
)

$ErrorActionPreference = 'Stop'

$Vivado  = 'S:\apps\Xilinx\Vivado\2018.3'
$Project = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$Unisims = Join-Path $Vivado 'data\verilog\src\unisims'
$Glbl    = Join-Path $Vivado 'data\verilog\src\glbl.v'

# ---------------------------------------------------------------- prepare ---
if (Test-Path $Work) { Remove-Item -Recurse -Force $Work }
New-Item -ItemType Directory -Force -Path $Work, "$Work\inc", "$Work\rtl" | Out-Null

# Same knobs as run_bench.ps1 -Only B_LAT_32 (plus PX_MHZ/RST_MID pinned, since
# bench.txt is read line by line and missing keys fall back to tb defaults).
# PX_DUTY 100 offers a pixel every cycle, which is the case that exposes
# FIFO-full drops.
@"
AW_LAT 1
W_LAT 1
B_LAT 32
CYCLES $Cycles
RING_BYTES 0
PX_DUTY 100
PX_MHZ 74
RST_MID 0
"@ | Set-Content -Path "$Work\bench.txt" -Encoding ASCII

# MAX_OUT is an RTL parameter; the synthesised netlist no longer has it.
$tb = [IO.File]::ReadAllText("$Project\sim\tb_sdi_stream_wr.v")
$patched = [regex]::Replace($tb, 'sdi_stream_wr\s*#\(.*?\)\s*dut', 'sdi_stream_wr dut')
if ($patched -eq $tb) {
    throw "tb parameter override not found -- the dut instantiation changed; update the regex in run_gl_bench.ps1"
}
if ($patched -match 'MAX_OUT\(MAX_OUT\)') {
    throw "tb still carries the MAX_OUT override after patching -- refusing to elaborate"
}

# Three tb lines peek into dut internals. A synthesised netlist preserves
# neither of them (w_beat_i is optimised away, beat_addr survives only as
# [31:2]), so they are replaced with constants and the two checks that depend
# on them report n/a. That cross-check (marker beat <-> frame_start_addr)
# stays covered by the behavioural suites; every port-level check (data, AXI,
# ring, drain, quiet, ovf) is unchanged here.
$patched = [regex]::Replace($patched, 'wire\s+dbg_wbeat\s*=\s*dut\.w_beat_i;',
    'wire        dbg_wbeat     = 1''b0;  // GATE: netlist has no w_beat_i')
$patched = [regex]::Replace($patched, 'wire\s+dbg_marker\s*=\s*dut\.px_rd_data\[64\];',
    'wire        dbg_marker    = 1''b0;  // GATE: marker cross-check n/a')
$patched = [regex]::Replace($patched, 'wire\s+\[31:0\]\s*dbg_beat_addr\s*=\s*dut\.beat_addr;',
    'wire [31:0] dbg_beat_addr = 32''d0; // GATE: netlist keeps only [31:2]')
$patched = [regex]::Replace($patched, '\(mark_errs == 0\) \? "PASS" : "FAIL",',
    '"n/a (gate: marker check is behavioural-only)",')
$patched = [regex]::Replace($patched, '\(frame_cnt == n_marker\) \? "PASS" : "FAIL",',
    '"n/a (gate)",')
if ($patched -match 'dut\.') {
    throw "some hierarchy peek survived the patch -- update the patterns in run_gl_bench.ps1"
}
[IO.File]::WriteAllText("$Work\rtl\tb.v", $patched, (New-Object System.Text.UTF8Encoding($false)))

# The tb includes "defs.vh". Built with an explicit backtick because PowerShell
# treats ` as its own escape character inside double-quoted strings.
$bt = [char]0x60
[IO.File]::WriteAllText("$Work\inc\defs.vh", "$bt" + 'define MAX_OUT_VAL 8',
                        (New-Object System.Text.ASCIIEncoding))

function Invoke-Step {
    # NOTE: do not name this parameter $Args -- that collides with PowerShell's
    # automatic $Args, and splatting @Args then passes NOTHING. Vivado starts in
    # GUI mode with no arguments, the call never returns, and the failure looks
    # like a hang instead of an error. (Hit 2026-10-15.)
    param([string]$Label, [string]$Exe, [string[]]$Argv, [string]$Log)
    Write-Host "=== $Label ==="
    & $Exe @Argv *> $Log
    $code = $LASTEXITCODE
    # The log may be UTF-16 (Vivado's console output), so look for start_gui
    # in both the raw-bytes-as-ASCII and raw-bytes-as-UTF-16 readings.
    $bytes = [IO.File]::ReadAllBytes($Log)
    $ascii = [Text.Encoding]::ASCII.GetString($bytes)
    $utf16 = [Text.Encoding]::Unicode.GetString($bytes)
    if ($code -eq 0 -and ($ascii -match 'start_gui' -or $utf16 -match 'start_gui')) {
        throw "$Label launched GUI mode -- argument passing is broken (check @Argv splat)"
    }
    if ($code -ne 0) {
        Write-Host "  FAILED (exit $code). Tail of $Log :"
        Get-Content $Log -Tail 15 | ForEach-Object { "    $_" }
        throw "$Label failed"
    }
}

# ------------------------------------------------------------- synthesise ---
Invoke-Step -Label '1/3 synthesise + export funcsim netlist' `
             -Exe (Join-Path $Vivado 'bin\vivado.bat') `
             -Argv @('-mode','batch','-nojournal','-nolog','-notrace',
                     '-source',"$Project\sim\gl_synth.tcl") `
             -Log  "$Work\synth.log"

$netlist = "$Work\sw.v"
if (-not (Test-Path $netlist)) { throw "netlist not produced: $netlist" }

Write-Host "=== 2/3 compile primitives + glbl + netlist + testbench ==="
Push-Location $Work
try {
    # Trap 2: no directory arguments, so build the command line in chunks.
    $all = Get-ChildItem $Unisims -Filter '*.v' | Sort-Object Name | ForEach-Object { $_.FullName }
    Write-Host "  unisim sources: $($all.Count)"
    $xvlog = Join-Path $Vivado 'bin\xvlog.bat'
    for ($i = 0; $i -lt $all.Count; $i += 80) {
        $grp = $all[$i..([Math]::Min($i + 79, $all.Count - 1))]
        & $xvlog @grp *> u.log
        if ($LASTEXITCODE -ne 0) { Get-Content u.log -Tail 10; throw "unisim compile failed" }
    }

    # Trap 4: glbl must be compiled alongside, and passed to xelab below.
    # The tb instantiates sdi_px_pack and sdi_px_afifo as behavioural RTL --
    # only sdi_stream_wr is the synthesised netlist under test.
    & $xvlog '-i' "$Work\inc" $Glbl $netlist `
        "$Project\rtl\cap\sdi_px_pack.v" "$Project\rtl\cap\sdi_px_afifo.v" `
        "$Work\rtl\tb.v" *> cv.log
    if ($LASTEXITCODE -ne 0) { Get-Content cv.log -Tail 15; throw "netlist/tb compile failed" }

    Write-Host "=== 3/3 elaborate and run ==="
    & (Join-Path $Vivado 'bin\xelab.bat') tb_sdi_stream_wr glbl -s gl --timescale 1ns/1ps *> el.log
    if ($LASTEXITCODE -ne 0) { Get-Content el.log -Tail 20; throw "elaboration failed" }

    & (Join-Path $Vivado 'bin\xsim.bat') gl -runall *> run.log
    if ($LASTEXITCODE -ne 0) { Get-Content run.log -Tail 20; throw "simulation failed" }
}
finally {
    Pop-Location
}

# ------------------------------------------------------------------ report ---
Write-Host ''
Write-Host '--- gate-level result ---'
Get-Content "$Work\run.log" |
    Select-String 'MAX_OUT=|throughput|beat rate|beats=|CHECK|data beats|drain:|ovf:' |
    ForEach-Object { "  $($_.Line.Trim())" }

Write-Host ''
Write-Host '--- memory inference ---'
Get-Content "$Work\mem.txt" -ErrorAction SilentlyContinue | ForEach-Object { "  $_" }
Get-Content "$Work\util.rpt" -ErrorAction SilentlyContinue |
    Select-String 'Slice LUTs\*|Slice Registers|Block RAM Tile|RAMB18E1 only' |
    Select-Object -First 4 | ForEach-Object { "  $($_.Line.Trim())" }

Write-Host ''
Write-Host 'Reference: run_bench.ps1 -Only B_LAT_32 (same bench.txt, behavioural RTL):'
Write-Host '  150.91 MB/s, beats=37728, frame_cnt=140, err_stat=0x0, all checks PASS'
Write-Host 'Gate level must match. A mismatch means the netlist differs from the RTL.'