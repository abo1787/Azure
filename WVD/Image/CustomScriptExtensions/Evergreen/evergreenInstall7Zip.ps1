# Set directory for software download
$filePath = "C:\Windows\Temp\evergreenSoftware"

# Install 7-Zip
Write-Output "Installing 7-Zip..."
$7zip = Get-EvergreenApp -Name 7zip | Where-Object { $_.Architecture -eq 'x64' -and $_.Type -eq 'msi' }
$filename = ($7zip.URI -split '/')[-1]
Invoke-WebRequest -Uri $7zip.URI -OutFile "$filepath\$filename"
$scriptBlock = { msiexec /i "$filepath\$filename" /q }
Invoke-Command $scriptBlock
