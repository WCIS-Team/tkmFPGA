$sh = New-Object -ComObject WScript.Shell
$lnk = $sh.CreateShortcut('C:\Users\Public\Desktop\Procise.lnk')
"TargetPath : " + $lnk.TargetPath
"Arguments  : " + $lnk.Arguments
"WorkingDir : " + $lnk.WorkingDirectory
"IconLoc    : " + $lnk.IconLocation
"Exists     : " + (Test-Path $lnk.TargetPath)
