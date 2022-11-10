#region Parameters
[CmdletBinding(SupportsShouldProcess = $true)]
param (
    
  [string] $executableName = "MsMMRHostInstaller.msi"

)

Write-Output "Starting Install Multimedia Redirection script..."
$mmRedirectionUri = "https://query.prod.cms.rt.microsoft.com/cms/api/am/binary/RE4QWrF"
#endregion

#region Download software
Write-Output "Downloading software..."
Invoke-WebRequest -Uri $mmRedirectionUri -OutFile "$($PSScriptRoot)\$executableName"
#endregion

#region File Paths
$mmRedirectionPath = "$($PSScriptRoot)\$executableName"
$mmRedirectionScriptBlock = { msiexec /i $mmRedirectionPath /qn }
#endregion

#region Install Software
Write-Output "Checking/Setting Multimedia Redirection registry key..."
Set-Location HKLM:
if ((Test-Path "Software\Microsoft\MSRDC\Policies") -eq $false) {
  New-Item -Path "Software\Microsoft\MSRDC\Policies" -Force
}
New-ItemProperty "Software\Microsoft\MSRDC\Policies" -Name "ReleaseRing" -Value "insider" -PropertyType String -Force
Write-Output "Set ReleaseRing Reg Key to value 'insider' successfully"

Write-Output "Installing Multimedia Redirection..."
Invoke-Command $mmRedirectionScriptBlock -Verbose
Write-Output "Multimedia Redirection was successfully installed"
#endregion