[CmdletBinding(SupportsShouldProcess = $true)]
param (
    
  [Parameter(Mandatory = $false)]
  [ValidateNotNullOrEmpty()]
  [string] $executableName = "FSLogixApp.zip"

)

# Download installer
Write-Output "Downloading installer..."
$uri = "https://download.microsoft.com/download/d/1/9/d190de51-f1c1-4581-9007-24e5a812d6e9/FSLogix_Apps_2.9.8228.50276.zip"
Invoke-WebRequest -Uri $Uri -OutFile "$($PSScriptRoot)\$executableName"
$fsLogixArchivePath = Join-Path $PSScriptRoot "FSLogixApp.zip"

# Extract installer
Write-Output "Extracting installer..."
Expand-Archive -Path $fsLogixArchivePath -DestinationPath $PSScriptRoot

# Set paths & switches
$executableName = "x64\Release\FSLogixAppsSetup.exe"
$fsLogixExePath = Join-Path $PSScriptRoot $executableName
$switches = "/passive /norestart"

# Install
Write-Output "Installing Microsoft Teams from path '$fsLogixExePath'"
$installer = Start-Process -FilePath $fsLogixExePath -ArgumentList $switches -Wait -PassThru

# Output
Write-Output "The exit code is $($installer.ExitCode)"