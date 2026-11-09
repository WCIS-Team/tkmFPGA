$root = 'S:\apps\ic\Procise'
$namePattern = 'ps7|processing_system|enet|emac|pcw|zynq'
Write-Output '===== 1) 文件名命中 ====='
Get-ChildItem $root -Recurse -File -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -match $namePattern } |
    Select-Object -First 80 |
    ForEach-Object { "{0,10}  {1}" -f $_.Length, $_.FullName }

Write-Output ''
Write-Output '===== 2) 文本内容命中 ENET / EMIO ====='
$exts = @('.tcl', '.xml', '.json', '.ini', '.cfg', '.csv', '.txt', '.mdd', '.fdc', '.pdc', '.v', '.sv', '.md')
$files = Get-ChildItem $root -Recurse -File -ErrorAction SilentlyContinue |
         Where-Object { $exts -contains $_.Extension.ToLower() }
Write-Output ("待扫文本文件数: " + $files.Count)
$hits = $files | Select-String -Pattern 'PCW_ENET|ps7_enet|ENET1|ENET_1|GMII2RGMII|gmii_to_rgmii' -List -ErrorAction SilentlyContinue
Write-Output ("命中文件数: " + $hits.Count)
$hits | Select-Object -First 40 | ForEach-Object { $_.Path }
