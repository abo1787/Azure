# Set directory for software download
$filePath = "C:\Windows\Temp\evergreenSoftware"

# Install Notepad++
Write-Output "Installing Notepad++..."
$notepadplusplus = Get-EvergreenApp -Name Notepadplusplus | Where-Object { $_.Architecture -eq 'x64' -and $_.Type -eq 'exe' }
$filename = ($notepadplusplus.URI -split '/')[-1]
Invoke-WebRequest -Uri $notepadplusplus.URI -OutFile "$filepath\$filename"
$Switches = "/S"
$Installer = Start-Process -FilePath "$filepath\$filename" -ArgumentList $Switches -Wait -PassThru
Write-Output ("The exit code is $($Installer.ExitCode)")
