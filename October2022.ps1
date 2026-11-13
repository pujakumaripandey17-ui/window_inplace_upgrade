$patches = @(
"\\homsqlpr12\Scripts\October\2022\windows10.0-kb5126655-x64_8053239cdb4c4264e6d76017d863cea4a2230804.msu",
"\\homsqlpr12\Scripts\October\2022\windows10.0-kb5127687-x64-ndp48_ea99577fc39bf62051a7a4c0bdf4ddd69820e62d.msu",
"\\homsqlpr12\Scripts\October\2022\windows10.0-kb5127693-x64-ndp481_4e84967600fe142948af741fa2b2736f8ed88637.msu"
)

foreach ($patch in $patches) {    
    $kbNumber = if ($patch -match "(kb\d+)") { $matches[1].ToUpper() } else { Split-Path $patch -Leaf }
    
    Write-Host "Installing: $kbNumber" -ForegroundColor Cyan
        
    $process = Start-Process -FilePath "wusa.exe" -ArgumentList "`"$patch`" /quiet /norestart" -Wait -PassThru
    
        if ($process.ExitCode -eq 0) {
        Write-Host "Successfully installed: $kbNumber" -ForegroundColor Green
    } elseif ($process.ExitCode -eq 3010) {
        Write-Host "Successfully installed (Reboot pending): $kbNumber" -ForegroundColor Yellow
    } else {
        Write-Host "Installation failed or returned exit code $($process.ExitCode): $kbNumber" -ForegroundColor Red
    }
    
    Write-Host "----------------------------------------"
}

Write-Host "All patch installations completed. A manual reboot is required to apply the updates." -ForegroundColor Yellow