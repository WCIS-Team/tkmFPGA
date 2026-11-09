$src = 'S:\apps\llm\agentwork\fpga-src\fpai_demo_fpga'
$dst = 'S:\work\WCIS\workenv\pl_eth\proj_trial\fpai_demo_fpga'
if (Test-Path $dst) { Remove-Item $dst -Recurse -Force }
New-Item -ItemType Directory -Path (Split-Path $dst) -Force | Out-Null
$out = robocopy $src $dst /E /NFL /NDL /NJH /NJS /R:1 /W:1 /MT:16
$code = $LASTEXITCODE
"robocopy exit = $code"
"copied files = " + (Get-ChildItem $dst -Recurse -File -ErrorAction SilentlyContinue).Count
"xpr exists  = " + (Test-Path (Join-Path $dst 'fpai_demo_vivado.xpr'))
