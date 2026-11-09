$roots = @(
  'S:\apps\llm\agentwork',
  'S:\work\WCIS\largefiles',
  'S:\work\WCIS\source',
  'C:\Users\takomi\AppData\Local\Temp\opencode',
  'S:\work\WCIS\wiki\PL\FPGA\4compile'
)
$patterns = 'processing_system7*', 'ps_ai*', '*.bd', 'component.xml', '*.xci'
foreach ($r in $roots) {
    if (-not (Test-Path $r)) { Write-Output ("[miss] " + $r); continue }
    Write-Output ("===== " + $r + " =====")
    foreach ($p in $patterns) {
        Get-ChildItem $r -Recurse -File -Filter $p -ErrorAction SilentlyContinue |
            Select-Object -First 25 |
            ForEach-Object { "{0,10}  {1}" -f $_.Length, $_.FullName }
    }
}
