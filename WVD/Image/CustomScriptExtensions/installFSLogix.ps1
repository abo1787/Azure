#region Parameters
[CmdletBinding(SupportsShouldProcess = $true)]
param (
    
  [Parameter(Mandatory = $false)]
  [ValidateNotNullOrEmpty()]
  [string] $executableName = "FSLogixApp.zip"

)

Write-Output "Starting Install FSLogix script..."
$fsLogixUri = "https://download.microsoft.com/download/d/1/9/d190de51-f1c1-4581-9007-24e5a812d6e9/FSLogix_Apps_2.9.8228.50276.zip"
#endregion

#region Download software
Write-Output "Downloading software..."
Invoke-WebRequest -Uri $fsLogixUri -OutFile "$($PSScriptRoot)\$executableName"
#endregion

#region File Paths
$fsLogixArchivePath = Join-Path $PSScriptRoot "FSLogixApp.zip"
$executableName = "x64\Release\FSLogixAppsSetup.exe"
$fsLogixExePath = Join-Path $PSScriptRoot $executableName
$fsLogixSwitches = "/passive /norestart"
#endregion

#region File Extraction
Write-Output "Extracting installer..."
Expand-Archive -Path $fsLogixArchivePath -DestinationPath $PSScriptRoot
#endregion

#region Install Software
Write-Output "Installing FSLogix..."
$installer = Start-Process -FilePath $fsLogixExePath -ArgumentList $fsLogixSwitches -Wait -PassThru
if ($installer.ExitCode -eq 0) {
  Write-Output "FSLogix was successfully installed"
}
else {
  Write-Output "FSLogix installation failed"
}
#endregion