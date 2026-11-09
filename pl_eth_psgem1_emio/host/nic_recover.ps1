Write-Output '===== 恢复前状态 ====='
Get-PnpDevice -Class Net | Where-Object { $_.FriendlyName -match 'Realtek' } |
    Select-Object Status, Problem, ProblemDescription | Format-List

Write-Output '===== 步骤 1：禁用再启用网卡（最轻的恢复手段） ====='
try {
    Disable-NetAdapter -Name 'Ethernet' -Confirm:$false -ErrorAction Stop
    Write-Output 'Disable 成功'
    Start-Sleep -Seconds 3
    Enable-NetAdapter -Name 'Ethernet' -Confirm:$false -ErrorAction Stop
    Write-Output 'Enable 成功'
} catch {
    Write-Output ("Disable/Enable 失败: " + $_.Exception.Message)
}

Start-Sleep -Seconds 6

Write-Output '===== 恢复后状态 ====='
Get-PnpDevice -Class Net | Where-Object { $_.FriendlyName -match 'Realtek' } |
    Select-Object Status, Problem, ProblemDescription | Format-List
Get-NetAdapter -Name 'Ethernet' | Format-List Name, Status, AdminStatus, MediaConnectionState, LinkSpeed
