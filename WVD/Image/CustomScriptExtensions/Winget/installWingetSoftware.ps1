# Set the ExecutionPolicy
Set-ExecutionPolicy -ExecutionPolicy Bypass -Scope CurrentUser -Force -Confirm:$false

# Set path for software instruction file
$softwarePath = "C:\Windows\Temp\aibVendorSoftwareToInstall.csv"

# Import software list to install
Write-Host "Installing packages"
$software = Import-Csv -Path $softwarePath
foreach ($package in $software) {

    winget install --id $package.Id -h
    Write-Host "Installed package $package"
    
}

# Remove software instruction file
Remove-Item $softwarePath
