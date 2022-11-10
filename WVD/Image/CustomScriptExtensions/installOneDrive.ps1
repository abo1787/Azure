#region Parameters
[CmdletBinding(SupportsShouldProcess = $true)]
param (
    
  [Parameter(Mandatory = $false)]
  [ValidateNotNullOrEmpty()]
  [string] $executableName = "OneDriveSetup.exe"

)

Write-Output "Starting Install OneDrive script..."
$onedriveUri = "https://go.microsoft.com/fwlink/p/?LinkID=2182910&clcid=0x809&culture=en-gb&country=GB"
#endregion

#region Download software
Write-Output "Downloading software..."
Invoke-WebRequest -Uri $onedriveUri -OutFile "$($PSScriptRoot)\$executableName"
#endregion

#region File Paths
$onedrivePath = Join-Path $PSScriptRoot $executableName
$onedriveSwitches = "/allusers"
#endregion

#region Install Software
Write-Output "Installing OneDrive..."
$installer = Start-Process -FilePath $onedrivePath -ArgumentList $onedriveSwitches -Wait -PassThru
if ($installer.ExitCode -eq 0) {
  Write-Output "OneDrive was successfully installed"
}
else {
  Write-Output "OneDrive installation failed"
}
#endregion