# Do not prompt user for confirmations
Set-Variable -Name 'ConfirmPreference' -Value 'None' -Scope Global

# Download Winget & Dependencies
Write-Host "Downloading Winget and dependencies"
Invoke-WebRequest -Uri "https://github.com/Bistech/Azure/blob/master/WVD/Image/CustomScriptExtensions/Winget/AppPackages/Microsoft.VCLibs.140.00.UWPDesktop_14.0.30035.0_x64__8wekyb3d8bbwe.Appx" -OutFile "C:\Windows\Temp\Microsoft.VCLibs.140.00.UWPDesktop_14.0.30035.0_x64__8wekyb3d8bbwe.Appx"
Invoke-WebRequest -Uri "https://github.com/Bistech/Azure/blob/master/WVD/Image/CustomScriptExtensions/Winget/AppPackages/Microsoft.VCLibs.140.00.UWPDesktop_14.0.30035.0_x64__8wekyb3d8bbwe.BlockMap" -OutFile "C:\Windows\Temp\Microsoft.VCLibs.140.00.UWPDesktop_14.0.30035.0_x64__8wekyb3d8bbwe.BlockMap"
Invoke-WebRequest -Uri "https://github.com/Bistech/Azure/blob/master/WVD/Image/CustomScriptExtensions/Winget/AppPackages/Microsoft.VCLibs.140.00_14.0.30035.0_x64__8wekyb3d8bbwe.Appx" -OutFile "C:\Windows\Temp\Microsoft.VCLibs.140.00_14.0.30035.0_x64__8wekyb3d8bbwe.Appx"
Invoke-WebRequest -Uri "https://github.com/Bistech/Azure/blob/master/WVD/Image/CustomScriptExtensions/Winget/AppPackages/Microsoft.VCLibs.140.00_14.0.30035.0_x64__8wekyb3d8bbwe.BlockMap" -OutFile "C:\Windows\Temp\Microsoft.VCLibs.140.00_14.0.30035.0_x64__8wekyb3d8bbwe.BlockMap"
Invoke-WebRequest -Uri "https://github.com/microsoft/winget-cli/releases/download/v1.0.11692/Microsoft.DesktopAppInstaller_8wekyb3d8bbwe.msixbundle" -OutFile "C:\Windows\Temp\Microsoft.DesktopAppInstaller_8wekyb3d8bbwe.msixbundle"

# Install Winget Dependencies
Write-Host "Installing dependencies"
Add-AppPackage -Path "C:\Windows\Temp\Microsoft.VCLibs.140.00_14.0.30035.0_x64__8wekyb3d8bbwe.Appx"
Add-AppPackage -Path "C:\Windows\Temp\Microsoft.VCLibs.140.00.UWPDesktop_14.0.30035.0_x64__8wekyb3d8bbwe.Appx"

# Install Winget
Write-Host "Installing Winget"
Add-AppPackage -Path "C:\Windows\Temp\Microsoft.DesktopAppInstaller_8wekyb3d8bbwe.msixbundle"
