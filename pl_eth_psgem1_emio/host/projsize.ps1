$p = 'S:\apps\llm\agentwork\fpga-src\fpai_demo_fpga'
Get-ChildItem $p | Select-Object Mode, Name, Length | Format-Table -AutoSize
'--- xpr ---'
Get-ChildItem $p -Filter *.xpr | Select-Object FullName, Length, LastWriteTime | Format-Table -AutoSize
'--- size ---'
$files = Get-ChildItem $p -Recurse -File -ErrorAction SilentlyContinue
$sum = ($files | Measure-Object -Property Length -Sum)
'{0:N2} GB / {1} files' -f ($sum.Sum / 1GB), $sum.Count
'--- disk free ---'
Get-PSDrive S | Select-Object Used, Free | Format-Table -AutoSize
