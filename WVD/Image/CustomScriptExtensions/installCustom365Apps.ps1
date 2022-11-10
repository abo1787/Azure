#region Parameters
[CmdletBinding(SupportsShouldProcess = $true)]
param (
    
  [string] $appsToInstall,
  [string] $executableName = "OfficeDeploy.zip"
)

Write-Output "Starting Install Office 365 script..."
$officeUri = "https://raw.githubusercontent.com/Bistech/Azure/master/WVD/Image/CustomScriptExtensions/OfficeDeploy.zip"

#endregion

#region Download software
Write-Output "Downloading software..."
Invoke-WebRequest -Uri $officeUri -OutFile "$($PSScriptRoot)\$executableName"
#endregion

#region File Paths
$M365ArchivePath = Join-Path $PSScriptRoot "OfficeDeploy.zip"
$executableName = "OfficeDeploy\setup.exe"
$M365ExePath = Join-Path $PSScriptRoot $executableName
if ($appsToInstall -eq "All") {
  $switches = "/configure .\OfficeDeploy\Configuration_AllApps.xml"
}
if ($appsToInstall -eq "No_Access") {
  $switches = "/configure .\OfficeDeploy\Configuration_NoAccess.xml"
}
if ($appsToInstall -eq "No_Access_OneNote") {
  $switches = "/configure .\OfficeDeploy\Configuration_NoAccessOneNote.xml"
}
if ($appsToInstall -eq "No_Access_Publisher") {
  $switches = "/configure .\OfficeDeploy\Configuration_NoAccessPublisher.xml"
}
if ($appsToInstall -eq "No_Access_OneNote_Publisher") {
  $switches = "/configure .\OfficeDeploy\Configuration_NoAccessPublisherOneNote.xml"
}
if ($appsToInstall -eq "No_OneNote") {
  $switches = "/configure .\OfficeDeploy\Configuration_NoOneNote.xml"
}
if ($appsToInstall -eq "No_OneNote_Publisher") {
  $switches = "/configure .\OfficeDeploy\Configuration_NoOneNotePublisher.xml"
}
if ($appsToInstall -eq "No_Publisher") {
  $switches = "/configure .\OfficeDeploy\Configuration_NoPublisher.xml"
}
#endregion

#region File Extraction
Write-Output "Extracting files..."
Expand-Archive -Path $M365ArchivePath -DestinationPath $PSScriptRoot
#endregion

#region Install Software
Write-Output "Installing Office 365..."
$installer = Start-Process -FilePath $M365ExePath -ArgumentList $switches -Wait -PassThru
if ($installer.ExitCode -eq 0) {
  Write-Output "Office 365 was successfully installed"
}
else {
  Write-Output "Office 365 installation failed"
}
#endregion
