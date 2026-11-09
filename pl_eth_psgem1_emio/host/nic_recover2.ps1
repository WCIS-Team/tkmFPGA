Write-Output '===== 尝试 Restart-PnpDevice（另一种恢复路径） ====='
$inst = (Get-PnpDevice -Class Net | Where-Object { $_.FriendlyName -match 'Realtek' }).InstanceId
Write-Output ("InstanceId = " + $inst)
try {
    Restart-PnpDevice -InstanceId $inst -Confirm:$false -ErrorAction Stop
    Write-Output 'Restart-PnpDevice 成功'
} catch {
    Write-Output ("Restart-PnpDevice 失败: " + $_.Exception.Message)
}

Start-Sleep -Seconds 5

Write-Output '===== pnputil /restart-device（Win11 才有） ====='
try {
    $r = & pnputil.exe /restart-device "$inst" 2>&1
    Write-Output ($r -join "`n")
} catch {
    Write-Output ("pnputil 失败: " + $_.Exception.Message)
}

Write-Output '===== 当前身份与是否管理员 ====='
Write-Output ("User = " + [System.Security.Principal.WindowsIdentity]::GetCurrent().Name)
$p = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
Write-Output ("IsAdmin = " + $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator))

Write-Output '===== 最终状态 ====='
Get-PnpDevice -Class Net | Where-Object { $_.FriendlyName -match 'Realtek' } |
    Select-Object Status, Problem, ProblemDescription | Format-List
