# Write to AIB Output
$timeStamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
Write-Output "$timeStamp *** STARTING CHOCOLATEY INSTALL ***"

# Install Chocolatey
Set-ExecutionPolicy Bypass -Scope Process -Force; [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072; Invoke-Expression ((New-Object System.Net.WebClient).DownloadString('https://chocolatey.org/install.ps1'))

# Write to AIB Output
$timeStamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
Write-Output "$timeStamp *** COMPLETED CHOCOLATEY INSTALL ***"
