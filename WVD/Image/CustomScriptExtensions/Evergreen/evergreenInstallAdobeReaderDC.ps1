# Set directory for software download
$filePath = "C:\Windows\Temp\evergreenSoftware"

# Install Adobe Reader DC
Write-Output "Installing Adobe Reader DC..."
$adobeReader = Get-EvergreenApp -Name AdobeAcrobatReaderDC | Where-Object { $_.Architecture -eq 'x64' -and $_.Language -eq 'English (UK)' }
$filename = ($adobeReader.URI -split '/')[-1]
Invoke-WebRequest -Uri $adobeReader.URI -OutFile "$filepath\$filename"
$Switches = "/sPB /rs /msi"
$Installer = Start-Process -FilePath "$filepath\$filename" -ArgumentList $Switches -Wait -PassThru
Write-Output ("The exit code is $($Installer.ExitCode)")
