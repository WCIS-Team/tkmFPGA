Write-Output '===== Realtek 高级属性（速率/节能相关） ====='
Get-NetAdapter -Name 'Ethernet' | Get-NetAdapterAdvancedProperty |
    Where-Object { $_.DisplayName -match 'Speed|Duplex|Green|Energy|Power|Wake|EEE|Flow' } |
    Select-Object DisplayName, DisplayValue | Format-Table -AutoSize

Write-Output ''
Write-Output '===== 驱动/电源管理 ====='
try {
    Get-NetAdapterPowerManagement -Name 'Ethernet' | Format-List *
} catch { Write-Output ("ERR " + $_) }

Write-Output ''
Write-Output '===== 最近 40 分钟系统日志里与网卡/链路有关的事件 ====='
$since = (Get-Date).AddMinutes(-40)
Get-WinEvent -FilterHashtable @{ LogName = 'System'; StartTime = $since } -ErrorAction SilentlyContinue |
    Where-Object { $_.ProviderName -match 'rt6|Realtek|NDIS|Tcpip|netwtw|e1' -or $_.Message -match 'link|Link|adapter|Adapter' } |
    Select-Object -First 30 TimeCreated, ProviderName, Id, LevelDisplayName, @{n='Msg';e={ ($_.Message -replace '\s+',' ').Substring(0, [Math]::Min(140, $_.Message.Length)) }} |
    Format-Table -AutoSize -Wrap

Write-Output ''
Write-Output '===== 最近 40 分钟 应用/系统 里含 “Realtek” 的所有事件 ====='
Get-WinEvent -FilterHashtable @{ LogName = 'System'; StartTime = $since } -ErrorAction SilentlyContinue |
    Where-Object { $_.Message -match 'Realtek|GbE' } |
    Select-Object -First 20 TimeCreated, ProviderName, Id, @{n='Msg';e={ ($_.Message -replace '\s+',' ').Substring(0, [Math]::Min(160, $_.Message.Length)) }} |
    Format-Table -AutoSize -Wrap
