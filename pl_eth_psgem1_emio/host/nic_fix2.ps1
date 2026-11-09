$out = "S:\work\WCIS\workenv\pl_eth\nic_state2.txt"
function W($m) { $m | Tee-Object -FilePath $out -Append }

W "===== 当前状态 $(Get-Date -Format 'HH:mm:ss') ====="
$d = Get-PnpDevice -Class Net | Where-Object { $_.FriendlyName -match 'Realtek' }
W ("Status=" + $d.Status + " | Problem=" + $d.Problem + " | " + $d.ProblemDescription)
$n = Get-NetAdapter -Name 'Ethernet' -ErrorAction SilentlyContinue
if ($n) { W ("Adapter: Status='" + $n.Status + "' AdminStatus=" + $n.AdminStatus + " MediaConnectionState=" + $n.MediaConnectionState) }

W "===== 用 pnputil 重启设备 ====="
$inst = $d.InstanceId
W ("InstanceId = " + $inst)
$r = & pnputil.exe /restart-device "$inst" 2>&1
W ($r -join "`n")

Start-Sleep -Seconds 8

W "===== 重启后 ====="
$d2 = Get-PnpDevice -Class Net | Where-Object { $_.FriendlyName -match 'Realtek' }
W ("Status=" + $d2.Status + " | Problem=" + $d2.Problem + " | " + $d2.ProblemDescription)
$n2 = Get-NetAdapter -Name 'Ethernet' -ErrorAction SilentlyContinue
if ($n2) { W ("Adapter: Status='" + $n2.Status + "' AdminStatus=" + $n2.AdminStatus + " LinkSpeed=" + $n2.LinkSpeed) }

W "===== 若仍禁用，再显式 Enable 一次 ====="
if ($d2.Status -ne 'OK') {
    try { Enable-NetAdapter -Name 'Ethernet' -Confirm:$false -ErrorAction Stop; W "Enable 成功" }
    catch { W ("Enable 失败: " + $_.Exception.Message) }
    Start-Sleep -Seconds 8
    $d3 = Get-PnpDevice -Class Net | Where-Object { $_.FriendlyName -match 'Realtek' }
    W ("最终 Status=" + $d3.Status + " | Problem=" + $d3.Problem + " | " + $d3.ProblemDescription)
}
