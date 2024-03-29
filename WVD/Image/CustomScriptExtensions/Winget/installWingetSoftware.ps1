# Write to AIB Output
$timeStamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
Write-Output "$timeStamp *** STARTING WINGET SOFTWARE INSTALL ***"

# Set the ExecutionPolicy
Set-ExecutionPolicy -ExecutionPolicy Bypass -Scope CurrentUser -Force -Confirm:$false

# Set path for software instruction file
$softwarePath = "C:\Windows\Temp\aibVendorSoftwareToInstall.csv"

# Change directory
Set-Location "C:\Program Files\WindowsApps\Microsoft.DesktopAppInstaller_1.12.11692.0_x64__8wekyb3d8bbwe"

Get-AppxPackage Microsoft.DesktopAppInstaller

# Output for troubleshooting
$appVersion = Get-AppxPackage Microsoft.DesktopAppInstaller
Write-Output "AppVersion is $appVersion"
$location = Get-Location
Write-Output "Directory is $location"
$enviromentPath = $env:Path -split ';'
Write-Output "Environment path is $enviromentPath"
$listDirs = Get-ChildItem "C:\Program Files\WindowsApps" | Where-Object {$_.Name -like "Microsoft.DesktopAppInstaller*"}
Write-Output "Directories are $listDirs"

# Import software list to install
Write-Output "Installing packages"
$software = Import-Csv -Path $softwarePath
foreach ($package in $software) {

    #.\AppInstallerCLI.exe install --id $package.Id -h
    cmd.exe /c winget install --id $package.Id -h
    Write-Output "Installed package $package"
    
}

# Remove software instruction file
Remove-Item $softwarePath

# Write to AIB Output
$timeStamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
Write-Output "$timeStamp *** COMPLETED WINGET SOFTWARE INSTALL ***"
