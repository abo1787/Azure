# Set directory for software download
$filePath = "C:\Windows\Temp\evergreenSoftware"

# Install Zoom VDI
Write-Output "Installing Zoom VDI..."
$zoom = Get-EvergreenApp -Name Zoom | Where-Object { $_.Platform -eq 'VDI' }
$filename = ($zoom.URI -split '/')[-1]
Invoke-WebRequest -Uri $zoom.URI -OutFile "$filepath\$filename"
$scriptBlock = { msiexec /i "$filepath\$filename" /qn }
Invoke-Command $scriptBlock
