# Set the ExecutionPolicy
Set-ExecutionPolicy -ExecutionPolicy Bypass -Scope CurrentUser -Force -Confirm:$false

# Set path for software instruction file
$softwarePath = "C:\Windows\Temp\aibVendorSoftwareToInstall.csv"

# Import software list to install
Write-Output "Installing packages"
$software = Import-Csv -Path $softwarePath
foreach ($package in $software) {

    C:\Users\packer\AppData\Local\Microsoft\WindowsApps\winget.exe winget install --id $package.Id -h
    Write-Output "Installed package $package"
    
}

# Remove software instruction file
Remove-Item $softwarePath
