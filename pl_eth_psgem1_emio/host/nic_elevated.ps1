# 提权后执行的网卡恢复脚本
$log = "S:\work\WCIS\workenv\pl_eth\nic_recover_elevated.log"
function W($m) { $m | Tee-Object -FilePath $log -Append }

W "===== 提权脚本开始 $(Get-Date -Format 'HH:mm:ss') ====="

# 确认是否真的是管理员
$p = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
W ("IsAdmin = " + $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator))
W ("User = " + [System.Security.Principal.WindowsIdentity]::GetCurrent().Name)

W "===== 恢复前 ====="
$before = Get-PnpDevice -Class Net | Where-Object { $_.FriendlyName -match 'Realtek' }
W ("Status=" + $before.Status + " Problem=" + $before.Problem + " " + $before.ProblemDescription)

W "===== 禁用 ====="
try {
    Disable-NetAdapter -Name 'Ethernet' -Confirm:$false -ErrorAction Stop
    W "Disable 成功"
} catch { W ("Disable 失败: " + $_.Exception.Message) }

Start-Sleep -Seconds 4

W "===== 启用 ====="
try {
    Enable-NetAdapter -Name 'Ethernet' -Confirm:$false -ErrorAction Stop
    W "Enable 成功"
} catch { W ("Enable 失败: " + $_.Exception.Message) }

Start-Sleep -Seconds 8

W "===== 恢复后 ====="
$a = Get-PnpDevice -Class Net | Where-Object { $_.FriendlyName -match 'Realtek' }
W ("Status=" + $a.Status + " Problem=" + $a.Problem + " " + $a.ProblemDescription)
$n = Get-NetAdapter -Name 'Ethernet' -ErrorAction SilentlyContinue
if ($n) { W ("Adapter Status=" + $n.Status + " AdminStatus=" + $n.AdminStatus + " LinkSpeed=" + $n.LinkSpeed) }
W "===== 结束 ====="
