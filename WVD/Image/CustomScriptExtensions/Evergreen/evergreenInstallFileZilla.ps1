# Set directory for software download
$filePath = "C:\Windows\Temp\evergreenSoftware"

# Install FileZilla
Write-Output "Installing FileZilla..."
$fileZilla = Get-EvergreenApp -Name FileZilla
$filename = ($fileZilla.URI -split '/')[-1]
Invoke-WebRequest -Uri $fileZilla.URI -OutFile "$filepath\$filename"
$Switches = "/S /user=all"
$Installer = Start-Process -FilePath "$filepath\$filename" -ArgumentList $Switches -Wait -PassThru
Write-Output ("The exit code is $($Installer.ExitCode)")
