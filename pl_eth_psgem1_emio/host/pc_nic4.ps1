Write-Output '===== 当前 Ethernet 实时状态 ====='
Get-NetAdapter -Name 'Ethernet' | Format-List Name, Status, AdminStatus, MediaConnectionState, LinkSpeed, FullDuplex

Write-Output ''
Write-Output '===== WMI 实时（0=断开 2=连接 7=媒体断开） ====='
Get-CimInstance Win32_NetworkAdapter -Filter "DeviceID='1'" |
    Select-Object DeviceID, Name, NetConnectionStatus, Speed, NetEnabled | Format-List

Write-Output ''
Write-Output '===== 过去 3 小时 rt68cx21 事件总数与时间分布 ====='
$since = (Get-Date).AddHours(-3)
$ev = Get-WinEvent -FilterHashtable @{ LogName='System'; ProviderName='rt68cx21'; StartTime=$since } -ErrorAction SilentlyContinue
Write-Output ("事件总数: " + $ev.Count)
if ($ev) {
    $ev | Group-Object Id | Select-Object Name, Count | Format-Table -AutoSize
    Write-Output '--- 最近 10 条 ---'
    $ev | Select-Object -First 10 TimeCreated, Id, @{n='Msg';e={($_.Message -replace '\s+',' ')}} | Format-Table -AutoSize -Wrap
    Write-Output '--- 最早 3 条 ---'
    $ev | Select-Object -Last 3 TimeCreated, Id, @{n='Msg';e={($_.Message -replace '\s+',' ')}} | Format-Table -AutoSize -Wrap
}

Write-Output ''
Write-Output '===== 事件 9 / 其他 ID 的原始含义（找 event 描述） ====='
try {
    $p = Get-WinEvent -FilterHashtable @{ LogName='System'; ProviderName='rt68cx21'; StartTime=$since } -ErrorAction Stop | Select-Object -First 1
    $p | Format-List TimeCreated, Id, Level, ProviderName, Message, Properties
} catch { Write-Output ("ERR " + $_) }
