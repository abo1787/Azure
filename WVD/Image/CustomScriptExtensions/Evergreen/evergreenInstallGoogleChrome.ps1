# Set directory for software download
$filePath = "C:\Windows\Temp\evergreenSoftware"

# Install Google Chrome
Write-Output "Installing Google Chrome..."
$chrome = Get-EvergreenApp -Name GoogleChrome | Where-Object { $_.Architecture -eq 'x64' }
$filename = ($chrome.URI -split '/')[-1]
Invoke-WebRequest -Uri $chrome.URI -OutFile "$filepath\$filename"
$scriptBlock = { msiexec /i "$filepath\$filename" /qn }
Invoke-Command $scriptBlock
