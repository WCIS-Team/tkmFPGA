Write-Output '===== A) rt68cx21 全部历史事件（不限时间窗，取最近 60 条） ====='
$all = Get-WinEvent -FilterHashtable @{ LogName='System'; ProviderName='rt68cx21' } -MaxEvents 60 -ErrorAction SilentlyContinue
Write-Output ("总条数: " + $all.Count)
if ($all) {
    Write-Output '--- 前 20 条（最新） ---'
    $all | Select-Object -First 20 TimeCreated, Id, LevelDisplayName, @{n='Msg';e={($_.Message -replace '\s+',' ')}} | Format-Table -AutoSize -Wrap
    Write-Output '--- 最后 5 条（最老） ---'
    $all | Select-Object -Last 5 TimeCreated, Id, @{n='Msg';e={($_.Message -replace '\s+',' ')}} | Format-Table -AutoSize -Wrap
    Write-Output '--- 按日期分布 ---'
    $all | Group-Object { $_.TimeCreated.ToString('yyyy-MM-dd HH') } | Sort-Object Name |
        Select-Object Name, Count | Format-Table -AutoSize
}

Write-Output '===== B) 今天所有 Kernel-PnP 关于 Realtek 的记录（含 Code 43 之前的） ====='
$since = (Get-Date).AddHours(-8)
Get-WinEvent -FilterHashtable @{ LogName='System'; ProviderName='Microsoft-Windows-Kernel-PnP'; StartTime=$since } -ErrorAction SilentlyContinue |
    Where-Object { $_.Message -match '8168|10EC|Realtek|GbE' } |
    Select-Object -First 20 TimeCreated, Id, @{n='Msg';e={($_.Message -replace '\s+',' ').Substring(0,[Math]::Min(160,$_.Message.Length))}} |
    Format-Table -AutoSize -Wrap

Write-Output '===== C) 网卡驱动文件与版本 ====='
Get-CimInstance Win32_PnPSignedDriver | Where-Object { $_.DeviceName -match 'Realtek.*GbE' } |
    Select-Object DeviceName, DriverVersion, DriverDate, InfName, DriverProviderName, IsSigned | Format-List

Write-Output '===== D) 今天 20:00 之后全部系统错误（不限来源，看有没有别的线索） ====='
$since2 = (Get-Date).Date.AddHours(20)
Get-WinEvent -FilterHashtable @{ LogName='System'; Level=1,2,3; StartTime=$since2 } -ErrorAction SilentlyContinue |
    Select-Object -First 30 TimeCreated, ProviderName, Id, LevelDisplayName, @{n='Msg';e={($_.Message -replace '\s+',' ').Substring(0,[Math]::Min(120,$_.Message.Length))}} |
    Format-Table -AutoSize -Wrap
