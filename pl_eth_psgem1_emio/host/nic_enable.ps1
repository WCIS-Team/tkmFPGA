# 提权：pnputil /enable-device + 三重状态核对
$inst = 'PCI\VEN_10EC&DEV_8168&SUBSYS_35A21558&REV_15\01000000684CE00000'
$log  = 'S:\work\WCIS\workenv\pl_eth\nic_enable.log'

function Say($m) {
    Add-Content -Path $log -Value $m -Encoding UTF8
}

Say "===== $(Get-Date -Format 'HH:mm:ss') ====="
$pr = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
Say ("IsAdmin=" + $pr.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator))

Say "--- pnputil /enable-device ---"
$r = & pnputil.exe /enable-device "$inst" 2>&1
Say ($r -join ' | ')

Start-Sleep -Seconds 10

Say "--- 状态核对 ---"
$d = Get-PnpDevice -InstanceId $inst
Say ("Pnp Status=" + $d.Status + " Problem=" + $d.Problem + " " + $d.ProblemDescription)
$c = Get-CimInstance Win32_NetworkAdapter -Filter "DeviceID='1'"
Say ("CIM NetEnabled=" + $c.NetEnabled + " ErrCode=" + $c.ConfigManagerErrorCode + " NetConnStatus=" + $c.NetConnectionStatus)

Say "--- 若仍 Code 22，再 Enable-PnpDevice ---"
$c = Get-CimInstance Win32_NetworkAdapter -Filter "DeviceID='1'"
if ($c.ConfigManagerErrorCode -eq 22) {
    try {
        Enable-PnpDevice -InstanceId $inst -Confirm:$false -ErrorAction Stop
        Say "Enable-PnpDevice 成功"
    } catch {
        Say ("Enable-PnpDevice 失败: " + $_.Exception.Message)
    }
    Start-Sleep -Seconds 12
    $d2 = Get-PnpDevice -InstanceId $inst
    Say ("最终 Pnp Status=" + $d2.Status + " Problem=" + $d2.Problem + " " + $d2.ProblemDescription)
    $c2 = Get-CimInstance Win32_NetworkAdapter -Filter "DeviceID='1'"
    Say ("最终 CIM NetEnabled=" + $c2.NetEnabled + " ErrCode=" + $c2.ConfigManagerErrorCode)
}

Say "===== done ====="
