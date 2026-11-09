#============================================================================
# run_bench.ps1 -- 像素链回归（打包 -> 异步 FIFO -> AXI 写帧器 -> HP2 从模型）
#
# 用法：
#   powershell -ExecutionPolicy Bypass -File run_bench.ps1           # 默认扫描
#   powershell -ExecutionPolicy Bypass -File run_bench.ps1 -Full     # 全扫
#   powershell -ExecutionPolicy Bypass -File run_bench.ps1 -Only B_LAT_127
#   powershell -ExecutionPolicy Bypass -File run_bench.ps1 -Only REGS
#
# 两条链：tb_sdi_stream_wr（像素链 19 个套件）+ tb_sdi_cap_regs（CSR，1 条）。
# -Full 才包含 W_LAT_*/RING_*/PX_*/RST_MID；REGS 无参数，默认也跑。
#
# 依赖：Vivado 2018.3 的 xvlog / xelab / xsim
# 产物：bench.txt（每次覆盖，被测参数）、run_<套件名>.log（xsim 原始输出）
#============================================================================
param([switch]$Full, [string]$Only = '')

$ErrorActionPreference = 'Stop'
$sim  = $PSScriptRoot
$cap  = (Resolve-Path (Join-Path $sim '..\rtl\cap')).Path

$srcs = @(
    (Join-Path $cap 'sdi_px_pack.v'),
    (Join-Path $cap 'sdi_px_afifo.v'),
    (Join-Path $cap 'sdi_stream_wr.v'),
    (Join-Path $sim 'tb_sdi_stream_wr.v')
)

function Find-Tool([string]$name) {
    foreach ($c in @(
        "S:\apps\Xilinx\Vivado\2018.3\bin\$name",
        "C:\apps\Xilinx\Vivado\2018.3\bin\$name",
        "C:\Users\takomi\AppData\Local\Temp\opencode\sdi_sim\$name")) {
        if (Test-Path $c) { return $c }
    }
    return $name
}
$xvlog = Find-Tool 'xvlog.bat'
$xelab = Find-Tool 'xelab.bat'
$xsim  = Find-Tool 'xsim.bat'

Set-Location $sim

#------------------------------------------------------------------------------
# 编译 + 展开
#------------------------------------------------------------------------------
Write-Host "=== compile ===" -ForegroundColor Cyan
$cout = & $xvlog @srcs 2>&1 | Out-String
$cout.Split("`n") | Where-Object { $_ -match 'ERROR|WARNING' } | ForEach-Object { $_.Trim() }
if ($cout -match '(?m)^ERROR') { Write-Host "xvlog FAILED"; exit 1 }

Write-Host "=== elaborate ===" -ForegroundColor Cyan
$eout = & $xelab tb_sdi_stream_wr -s tb8 --debug typical 2>&1 | Out-String
$eout.Split("`n") | Where-Object { $_ -match 'ERROR|error' } | ForEach-Object { $_.Trim() }
if ($eout -match '(?m)^ERROR') { Write-Host "xelab FAILED"; exit 1 }

#------------------------------------------------------------------------------
# 套件
#------------------------------------------------------------------------------
$suites = New-Object System.Collections.ArrayList
function Add-Suite($name, $keys) {
    [void]$suites.Add([pscustomobject]@{ Name = $name; Keys = $keys })
}

# 1) BRESP 延迟：单突发吞吐的命门
foreach ($b in 1, 8, 32, 64, 127) {
    Add-Suite "B_LAT_$b" @{ AW_LAT=1; W_LAT=1; B_LAT=$b; CYCLES=200000; RING_BYTES=0; PX_DUTY=100; PX_MHZ=74; RST_MID=0 }
}
if ($Full) {
    # 2) W 通道反压
    foreach ($w in 1, 2, 4, 8) {
        Add-Suite "W_LAT_$w" @{ AW_LAT=1; W_LAT=$w; B_LAT=32; CYCLES=200000; RING_BYTES=0; PX_DUTY=100; PX_MHZ=74; RST_MID=0 }
    }
    # 3) 环形回绕（含最小环 16 字节 = 2 拍）
    foreach ($r in 0, 33554432, 4096, 1000, 128, 64, 16) {
        Add-Suite "RING_$r" @{ AW_LAT=1; W_LAT=1; B_LAT=32; CYCLES=200000; RING_BYTES=$r; PX_DUTY=100; PX_MHZ=74; RST_MID=0 }
    }
    # 4) 不丢字模式：跨拍连续性必须严格成立
    Add-Suite "PX_DUTY_8" @{ AW_LAT=1; W_LAT=1; B_LAT=32; CYCLES=200000; RING_BYTES=0; PX_DUTY=8; PX_MHZ=74; RST_MID=0 }
    # 5) 失锁兜底时钟：像素域跑 200 MHz（那是"没锁也照写"那条路）
    Add-Suite "PX_MHZ_200" @{ AW_LAT=1; W_LAT=1; B_LAT=32; CYCLES=200000; RING_BYTES=0; PX_DUTY=100; PX_MHZ=200; RST_MID=0 }
    # 6) 事务没排空就复位（厂商文档 L4 场景），复位后必须自己起来
    Add-Suite "RST_MID" @{ AW_LAT=1; W_LAT=1; B_LAT=32; CYCLES=200000; RING_BYTES=0; PX_DUTY=100; PX_MHZ=74; RST_MID=1 }
}

$rows = New-Object System.Collections.ArrayList
$errs = New-Object System.Collections.ArrayList

foreach ($s in $suites) {
    if ($Only -ne '' -and $s.Name -ne $Only) { continue }

    $lines = $s.Keys.GetEnumerator() | Sort-Object Name | ForEach-Object { "{0} {1}" -f $_.Key, $_.Value }
    [IO.File]::WriteAllLines((Join-Path $sim 'bench.txt'), $lines)

    $out = & $xsim tb8 -runall 2>&1 | Out-String
    [IO.File]::WriteAllText((Join-Path $sim ("run_{0}.log" -f $s.Name)), $out)

    $chk  = ([regex]::Match($out, '(?m)^\s*CHECK .*$')).Value.Trim()
    $thr  = ([regex]::Match($out, '(?m)^\s*throughput = .*$')).Value.Trim()
    $rate = ([regex]::Match($out, '(?m)^\s*beat rate = .*$')).Value.Trim()
    $misc = ([regex]::Match($out, '(?m)^\s*\(drain:.*$')).Value.Trim()
    $erln = $out -split "`r?`n" | Where-Object { $_ -match '\bERROR:|\bTIMEOUT\b' } | Select-Object -First 6

    [void]$rows.Add([pscustomobject]@{
        Suite = $s.Name
        Throughput = ($thr -replace '^\s*throughput =\s*', '')
        Check = ($chk -replace '^\s*CHECK\s*', '')
    })
    if (($chk -match 'FAIL') -or $erln -or $thr -eq '') {
        [void]$errs.Add("--- $($s.Name): $chk")
        foreach ($l in $erln) { [void]$errs.Add("      $($l.Trim())") }
        if ($thr -eq '') { [void]$errs.Add("      (no summary -- see run_$($s.Name).log)") }
    }
}

#------------------------------------------------------------------------------
# 寄存器块回归：sdi_cap_regs —— PS 唯一直接接触的接口
#
# 单独一条链，因为被测对象不同（AXI4-Lite CSR，不是像素链），
# 而且它不需要 bench.txt 参数。像素链 19 个套件跑完再跑它。
#   -Only REGS   只跑这一条
#------------------------------------------------------------------------------
if ($Only -eq '' -or $Only -eq 'REGS') {
    Write-Host "=== regs suite (sdi_cap_regs) ===" -ForegroundColor Cyan
    $rsrcs = @(
        (Join-Path $cap 'sdi_cap_regs.v'),
        (Join-Path $sim 'tb_sdi_cap_regs.v')
    )
    $rout = & $xvlog @rsrcs 2>&1 | Out-String
    $rout.Split("`n") | Where-Object { $_ -match 'ERROR|WARNING' } | ForEach-Object { $_.Trim() }
    if ($rout -match '(?m)^ERROR') { Write-Host "xvlog FAILED (regs)"; exit 1 }

    $reout = & $xelab tb_sdi_cap_regs -s tbregs --debug typical 2>&1 | Out-String
    if ($reout -match '(?m)^ERROR') {
        $reout.Split("`n") | Where-Object { $_ -match 'ERROR' } | ForEach-Object { $_.Trim() }
        Write-Host "xelab FAILED (regs)"; exit 1
    }

    $rres = & $xsim tbregs -runall 2>&1 | Out-String
    [IO.File]::WriteAllText((Join-Path $sim 'run_REGS.log'), $rres)

    $firstFail = ($rres -split "`r?`n" | Where-Object { $_ -match 'FAIL' } | Select-Object -First 3)
    $resLine   = ([regex]::Match($rres, '(?m)^REGS RESULT:.*$')).Value.Trim()
    $nok       = ([regex]::Matches($rres, '(?m)^\s+ok\s')).Count

    [void]$rows.Add([pscustomobject]@{
        Suite = 'REGS'
        Throughput = ("{0} checks" -f $nok)
        Check = $resLine
    })
    if ($resLine -notmatch 'PASS') {
        [void]$errs.Add("--- REGS: $resLine")
        foreach ($l in $firstFail) { [void]$errs.Add("      $($l.Trim())") }
    }
}

if ($rows.Count -eq 0) {
    Write-Host "************ NO SUITES RAN ************" -ForegroundColor Red
    Write-Host ("     -Only '{0}' matched nothing. W_LAT_*/RING_*/PX_*/RST_MID only exist with -Full; REGS is a single suite." -f $Only)
    exit 1
}

Write-Host ""
Write-Host "=================== RESULTS ===================" -ForegroundColor Cyan
$rows | Format-Table -AutoSize | Out-String -Width 200 | Write-Host
if ($errs.Count -gt 0) {
    Write-Host "************ FAILED ************" -ForegroundColor Red
    $errs | ForEach-Object { Write-Host $_ -ForegroundColor Red }
    exit 1
} else {
    Write-Host "ALL PASS" -ForegroundColor Green
}
