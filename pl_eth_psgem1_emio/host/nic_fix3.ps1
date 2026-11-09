$out = "S:\work\WCIS\workenv\pl_eth\nic_state3.txt"
function W($m) { $m | Tee-Object -FilePath $out -Append }

$inst = (Get-PnpDevice -Class Net | Where-Object { $_.FriendlyName -match 'Realtek' }).InstanceId
W "===== $(Get-Date -Format 'HH:mm:ss') InstanceId=$inst ====="

W "----- 1) Get-PnpDevice -----"
$d = Get-PnpDevice -InstanceId $inst
W ("Status=" + $d.Status + " Problem=" + $d.Problem + " " + $d.ProblemDescription)

W "----- 2) Enable-PnpDevice -----"
try { Enable-PnpDevice -InstanceId $inst -Confirm:$false -ErrorAction Stop; W "Enable-PnpDevice 成功" }
catch { W ("Enable-PnpDevice 失败: " + $_.Exception.Message) }

Start-Sleep -Seconds 15

W "----- 3) 15 秒后 -----"
$d = Get-PnpDevice -InstanceId $inst
W ("Status=" + $d.Status + " Problem=" + $d.Problem + " " + $d.ProblemDescription)

W "----- 4) CIM 交叉验证（不看 PnpDevice 缓存） -----"
$c = Get-CimInstance Win32_NetworkAdapter -Filter "DeviceID='1'"
W ("NetEnabled=" + $c.NetEnabled + " NetConnectionStatus=" + $c.NetConnectionStatus + " ConfigManagerErrorCode=" + $c.ConfigManagerErrorCode + " Speed=" + $c.Speed)

W "----- 5) Get-NetAdapter -----"
$n = Get-NetAdapter -Name 'Ethernet' -ErrorAction SilentlyContinue
if ($n) { W ("Status='" + $n.Status + "' AdminStatus=" + $n.AdminStatus + " MediaConnectionState=" + $n.MediaConnectionState + " LinkSpeed=" + $n.LinkSpeed) } else { W "Get-NetAdapter 无对象" }

W "----- 6) 若 Code 22 仍在，走设备管理器等价路径 -----"
$c2 = Get-CimInstance Win32_NetworkAdapter -Filter "DeviceID='1'"
if ($c2.ConfigManagerErrorCode -eq 22) {
    W "仍是 Code 22，尝试 devcon 风格的 CIM Enable"
    try {
        $obj = Get-CimInstance -ClassName Win32_NetworkAdapter -Filter "DeviceID='1'"
        Invoke-CimMethod -InputObject $obj -MethodName Enable -ErrorAction Stop | Out-Null
        W "CIM Enable 调用成功"
    } catch { W ("CIM Enable 失败: " + $_.Exception.Message) }
    Start-Sleep -Seconds 12
    $c3 = Get-CimInstance Win32_NetworkAdapter -Filter "DeviceID='1'"
    W ("最终 NetEnabled=" + $c3.NetEnabled + " NetConnectionStatus=" + $c3.NetConnectionStatus + " ErrorCode=" + $c3.ConfigManagerErrorCode)
    $d3 = Get-PnpDevice -InstanceId $inst
    W ("最终 Pnp Status=" + $d3.Status + " Problem=" + $d3.Problem + " " + $d3.ProblemDescription)
}
