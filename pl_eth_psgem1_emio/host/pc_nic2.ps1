$name = 'Ethernet'
Write-Output '===== Get-NetAdapter 详情 ====='
Get-NetAdapter -Name $name | Format-List Name, InterfaceDescription, Status, AdminStatus, MediaConnectionState, LinkSpeed, FullDuplex, MacAddress, ifIndex, DriverVersion, DriverDate

Write-Output '===== 硬件信息 ====='
try { Get-NetAdapterHardwareInfo -Name $name | Format-List * } catch { Write-Output ("ERR " + $_) }

Write-Output '===== WMI NetConnectionStatus ====='
$w = Get-CimInstance Win32_NetworkAdapter -Filter "NetEnabled = TRUE OR NetEnabled = FALSE" |
     Where-Object { $_.Name -like '*Realtek*' -or $_.Name -like '*GbE*' }
$w | Select-Object DeviceID, Name, NetEnabled, NetConnectionStatus, Speed, MACAddress | Format-List

Write-Output '===== 所有适配器的连接状态码（0=断开 2=已连接 7=媒体断开） ====='
Get-CimInstance Win32_NetworkAdapter | Where-Object { $_.PhysicalAdapter -eq $true } |
    Select-Object DeviceID, Name, NetConnectionStatus, Speed | Format-Table -AutoSize

Write-Output '===== 路由/ARP 有没有多出来的东西 ====='
Get-NetRoute -AddressFamily IPv4 | Select-Object DestinationPrefix, NextHop, InterfaceAlias, RouteMetric | Format-Table -AutoSize
