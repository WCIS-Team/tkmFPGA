Write-Output '===== A) 网络配置文件/连接历史（说明这块 Realtek 之前是否用过） ====='
Get-NetConnectionProfile -ErrorAction SilentlyContinue |
    Select-Object Name, InterfaceAlias, NetworkCategory, IPv4Connectivity | Format-Table -AutoSize

Write-Output '===== B) NetworkProfile 事件日志（链路出现/消失） ====='
$since = (Get-Date).AddHours(-3)
try {
    Get-WinEvent -FilterHashtable @{ LogName='Microsoft-Windows-NetworkProfile/Operational'; StartTime=$since } -ErrorAction Stop |
        Select-Object -First 20 TimeCreated, Id, @{n='Msg';e={($_.Message -replace '\s+',' ').Substring(0,[Math]::Min(150,$_.Message.Length))}} |
        Format-Table -AutoSize -Wrap
} catch { Write-Output ("NetworkProfile log ERR: " + $_.Exception.Message) }

Write-Output '===== C) Dhcp-Client 事件（有没有为 Ethernet 申请过地址） ====='
try {
    Get-WinEvent -FilterHashtable @{ LogName='Microsoft-Windows-Dhcp-Client/Operational'; StartTime=$since } -ErrorAction Stop |
        Select-Object -First 15 TimeCreated, Id, @{n='Msg';e={($_.Message -replace '\s+',' ').Substring(0,[Math]::Min(140,$_.Message.Length))}} |
        Format-Table -AutoSize -Wrap
} catch { Write-Output ("Dhcp log ERR: " + $_.Exception.Message) }

Write-Output '===== D) NDIS 事件（链路状态变化，最直接的证据） ====='
try {
    Get-WinEvent -FilterHashtable @{ LogName='Microsoft-Windows-NDIS/Operational'; StartTime=$since } -ErrorAction Stop |
        Select-Object -First 25 TimeCreated, Id, @{n='Msg';e={($_.Message -replace '\s+',' ').Substring(0,[Math]::Min(150,$_.Message.Length))}} |
        Format-Table -AutoSize -Wrap
} catch { Write-Output ("NDIS log ERR: " + $_.Exception.Message) }

Write-Output '===== E) 今天 Realtek 网卡是否曾被禁用/启用（UserPnp/Kernel-PnP 全量） ====='
Get-WinEvent -FilterHashtable @{ LogName='System'; StartTime=(Get-Date).AddHours(-6) } -ErrorAction SilentlyContinue |
    Where-Object { $_.Id -in 400,410,420,430,441,442,443,444,445 -and $_.Message -match 'Realtek|8168|Ethernet' } |
    Select-Object -First 15 TimeCreated, ProviderName, Id, @{n='Msg';e={($_.Message -replace '\s+',' ').Substring(0,[Math]::Min(140,$_.Message.Length))}} |
    Format-Table -AutoSize -Wrap
