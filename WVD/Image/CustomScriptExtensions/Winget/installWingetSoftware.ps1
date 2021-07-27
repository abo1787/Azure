# Set the ExecutionPolicy
Set-ExecutionPolicy -ExecutionPolicy Bypass -Scope CurrentUser -Force -Confirm:$false

# Set path for software instruction file
$softwarePath = "C:\Windows\Temp\aibVendorSoftwareToInstall.csv"

# Change directory
Set-Location C:\Users\packer\AppData\Local\Microsoft\WindowsApps

# Output for troubleshooting
$location = Get-Location
Write-Output "Directory is $location"
$enviromentPath = $env:Path -split ';'
Write-Output "Environment path is $enviromentPath"

# Import software list to install
Write-Output "Installing packages"
$software = Import-Csv -Path $softwarePath
foreach ($package in $software) {

    .\winget.exe install --id $package.Id -h
    Write-Output "Installed package $package"
    
}

# Remove software instruction file
Remove-Item $softwarePath
