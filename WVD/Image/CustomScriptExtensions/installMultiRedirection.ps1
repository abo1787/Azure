[CmdletBinding(SupportsShouldProcess = $true)]
param (
    
  [string] $executableName = "MsMMRHostInstaller.msi"

)

# Download installer
Write-Output "Downloading installer..."
$uri = "https://query.prod.cms.rt.microsoft.com/cms/api/am/binary/RE4QWrF"
Invoke-WebRequest -Uri $uri -OutFile "$($PSScriptRoot)\$executableName"
$msiPath = "$($PSScriptRoot)\$executableName"

# Set Reg key to enable
Set-Location HKLM:
Write-Output "Setting Multimedia Redirection registry key"
if ((Test-Path "Software\Microsoft\MSRDC\Policies") -eq $false) {
  New-Item -Path "Software\Microsoft\MSRDC\Policies" -Force
}
New-ItemProperty "Software\Microsoft\MSRDC\Policies" -Name "ReleaseRing" -Value "insider" -PropertyType String -Force
Write-Output "Set ReleaseRing Reg Key to value 'insider' successfully"

# Install
Write-Output "Installing Multimedia Redirection from path $MSIPath"
$scriptBlock = { msiexec /i $msiPath /qn }
Invoke-Command $scriptBlock -Verbose

# Output
Write-Output "Multimedia Redirection was successfully installed"