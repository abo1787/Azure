#region Parameters
[CmdletBinding(SupportsShouldProcess = $true)]
param (
    
  [string] $executableName = "Teams_windows_x64.msi"

)

Write-Output "Starting Install Teams script..."
$teamsUri = "https://teams.microsoft.com/downloads/desktopurl?env=production&plat=windows&arch=x64&managedInstaller=true&download=true"
$visualRedistUri = "https://aka.ms/vs/16/release/vc_redist.x64.exe"
$avRedirectionUri = "https://query.prod.cms.rt.microsoft.com/cms/api/am/binary/RWQ1UW"
#endregion

#region Download software
Write-Output "Downloading software..."
Invoke-WebRequest -Uri $teamsUri -OutFile "$($PSScriptRoot)\$executableName"
Invoke-WebRequest -Uri $visualRedistUri -OutFile "$($PSScriptRoot)\vc_redist.x64.exe"
Invoke-WebRequest -Uri $avRedirectionUri -OutFile "$($PSScriptRoot)\MsRdcWebRTC.msi"
#endregion

#region File Paths
$visualRedistSwitches = "/install /passive /norestart"
$avRedirectionPath = "$($PSScriptRoot)\MsRdcWebRTC.msi"
$avRedirectionScriptBlock = { msiexec /i $avRedirectionPath }
$teamsPath = "$($PSScriptRoot)\$executableName"
$teamsScriptBlock = { msiexec /i $teamsPath ALLUSER=1 ALLUSERS=1 }
#endregion

#region Install Software
Write-Output "Installing Visual C++ Redistributable..."
Start-Process -FilePath "$($PSScriptRoot)\vc_redist.x64.exe" -ArgumentList $visualRedistSwitches -Wait -PassThru

Write-Output "Installing Teams Web RTC..."
Invoke-Command $avRedirectionScriptBlock

Write-Output "Checking/Setting Teams AVD environment registry key..."
if ((Test-Path "HKLM:\Software\Microsoft\Teams") -eq $false) {
  New-Item -Path "HKLM:\Software\Microsoft\Teams" -Force
}
New-ItemProperty "HKLM:\Software\Microsoft\Teams" -Name "IsWVDEnvironment" -Value 1 -PropertyType DWord -Force
Write-Output "Set IsWVDEnvironment DWord to value 1 successfully"

Write-Output "Installing Teams..."
Invoke-Command $teamsScriptBlock
Write-Output "Teams was successfully installed"
#endregion