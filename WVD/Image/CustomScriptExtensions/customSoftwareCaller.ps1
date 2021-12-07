# Set the ExecutionPolicy
Set-ExecutionPolicy -ExecutionPolicy Bypass -Scope CurrentUser -Force -Confirm:$false

# Set variables
$customInstallerScript = "customSoftware.ps1"

# Change to location
Set-Location C:\Windows\Temp

# Call custom installer script
Write-Output "Starting Bespoke Software installation script..."
& .\$customInstallerScript
