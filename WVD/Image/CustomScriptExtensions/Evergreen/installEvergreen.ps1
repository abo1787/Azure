# Do not prompt user for confirmations
Set-Variable -Name 'ConfirmPreference' -Value 'None' -Scope Global

# Install PackageManagement
Write-Output "Installing PackageManagement"
Install-Package -Name PackageManagement -MinimumVersion 1.4.7 -Force -Confirm:$false -Source PSGallery

# Install PowershellGet
Write-Output "Installing PowershellGet"
Install-Package -Name PowershellGet -Force

# Install Evergreen
Install-Module -Name Evergreen -Confirm:$false -Force
Import-Module -Name Evergreen

# Create directory for software download
$dirPath = "C:\Windows\Temp"
New-Item -Path $dirPath -Name "evergreenSoftware" -ItemType Directory
