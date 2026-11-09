Write-Output '===== 网卡总览 ====='
Get-NetAdapter | Sort-Object Status, Name |
    Select-Object Name, InterfaceDescription, Status, LinkSpeed, FullDuplex, MacAddress, ifIndex |
    Format-Table -AutoSize

Write-Output ''
Write-Output '===== 有链路（Status=Up）的网卡 ====='
Get-NetAdapter | Where-Object { $_.Status -eq 'Up' } |
    Select-Object Name, InterfaceDescription, LinkSpeed, MediaType |
    Format-Table -AutoSize

Write-Output ''
Write-Output '===== IP 配置 ====='
Get-NetIPConfiguration | ForEach-Object {
    $a = $_.InterfaceAlias
    $d = $_.InterfaceDescription
    $ips = ($_.IPv4Address.IPAddress -join ',')
    $gw  = ($_.IPv4DefaultGateway.NextHop -join ',')
    "{0,-22} {1,-45} ipv4={2,-18} gw={3}" -f $a, $d, $ips, $gw
}

Write-Output ''
Write-Output '===== 每块网卡的连接状态与速率细节 ====='
Get-NetAdapter | ForEach-Object {
    $n = $_.Name
    $st = $_.Status
    $sp = $_.LinkSpeed
    $mt = $_.MediaType
    $conn = $null
    try { $conn = (Get-NetConnectionProfile -InterfaceIndex $_.ifIndex -ErrorAction Stop).Name } catch { }
    "{0,-22} status={1,-8} speed={2,-12} media={3,-14} profile={4}" -f $n, $st, $sp, $mt, $conn
}

Write-Output ''
Write-Output '===== 可疑的“第二个网口”（除了正在用的 LAN 之外还 Up 的） ====='
$up = Get-NetAdapter | Where-Object { $_.Status -eq 'Up' }
Write-Output ("Up 的网卡数: " + $up.Count)
$up | Select-Object Name, InterfaceDescription, LinkSpeed, MacAddress | Format-Table -AutoSize
