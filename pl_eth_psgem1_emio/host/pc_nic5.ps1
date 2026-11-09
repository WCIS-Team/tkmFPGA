Write-Output '===== 1) 网卡是否被禁用（PnP 设备状态） ====='
Get-PnpDevice -Class Net | Where-Object { $_.FriendlyName -match 'Realtek' } |
    Select-Object Status, Class, FriendlyName, InstanceId, Problem, ProblemDescription |
    Format-List

Write-Output '===== 2) NetEnabled / ConfigManagerErrorCode ====='
Get-CimInstance Win32_NetworkAdapter -Filter "DeviceID='1'" |
    Select-Object DeviceID, Name, NetEnabled, NetConnectionStatus, ConfigManagerErrorCode, Speed, PNPDeviceID |
    Format-List

Write-Output '===== 3) 今天所有 Realtek/网卡配置变更事件（含启用/禁用） ====='
$since = (Get-Date).AddHours(-6)
Get-WinEvent -FilterHashtable @{ LogName='System'; StartTime=$since } -ErrorAction SilentlyContinue |
    Where-Object { $_.ProviderName -match 'rt68cx21|Net|NDIS|UserPnp|Kernel-PnP' -and ( $_.Message -match 'Realtek|GbE|network adapter|Ethernet' ) } |
    Select-Object -First 25 TimeCreated, ProviderName, Id, LevelDisplayName, @{n='Msg';e={($_.Message -replace '\s+',' ').Substring(0,[Math]::Min(150,$_.Message.Length))}} |
    Format-Table -AutoSize -Wrap

Write-Output '===== 4) 是否有 DHCP/ARP 活动（说明链路当时是通的） ====='
Get-WinEvent -FilterHashtable @{ LogName='System'; ProviderName='Microsoft-Windows-Dhcp-Client'; StartTime=$since } -ErrorAction SilentlyContinue |
    Select-Object -First 15 TimeCreated, Id, @{n='Msg';e={($_.Message -replace '\s+',' ').Substring(0,[Math]::Min(130,$_.Message.Length))}} |
    Format-Table -AutoSize -Wrap

Write-Output '===== 5) 当前 ARP 表 ====='
arp -a

Write-Output '===== 6) Ethernet 网卡的 DHCP/静态配置 ====='
Get-NetIPAddress -InterfaceAlias 'Ethernet' -ErrorAction SilentlyContinue |
    Select-Object IPAddress, PrefixLength, AddressFamily, PrefixOrigin, SuffixOrigin | Format-Table -AutoSize

Write-Output '===== 7) 网卡已收发统计（若禁用则为空） ====='
Get-NetAdapterStatistics -Name 'Ethernet' -ErrorAction SilentlyContinue |
    Select-Object Name, ReceivedBytes, ReceivedPackets, ReceivedErrors, SentBytes, SentPackets, OutboundErrors, OutboundDiscarded |
    Format-List
