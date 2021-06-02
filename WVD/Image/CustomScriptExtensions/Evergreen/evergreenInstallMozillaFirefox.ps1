# Set directory for software download
$filePath = "C:\Windows\Temp\evergreenSoftware"

# Install Mozilla Firefox
Write-Output "Installing Firefox..."
$firefox = Get-EvergreenApp -Name MozillaFirefox | Where-Object { $_.Architecture -eq 'x64' -and $_.Language -eq 'en-GB' -and $_.Type -eq 'msi' -and $_.Channel -eq 'LATEST_FIREFOX_VERSION' }
$filename = ($firefox.URI -split '/')[-1]
Invoke-WebRequest -Uri $firefox.URI -OutFile "$filepath\$filename"
$scriptBlock = { msiexec /i "$filepath\$filename" /q }
Invoke-Command $scriptBlock
