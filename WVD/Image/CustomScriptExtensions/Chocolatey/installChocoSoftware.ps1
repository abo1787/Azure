# Write to AIB Output
Write-Output "*** STARTING CHOCOLATEY SOFTWARE INSTALL ***"

# Set path for software instruction file
$softwarePath = "C:\Windows\Temp\aibVendorSoftwareToInstall.csv"

# Import software list to install
Write-Output "Installing packages"
$software = Import-Csv -Path $softwarePath
foreach ($package in $software) {

    Choco Install $package.Name -y
    Write-Output "Installed package $($package.Name)"
    
}

# Remove software instruction file
Remove-Item $softwarePath

# Write to AIB Output
Write-Output "*** COMPLETED CHOCOLATEY SOFTWARE INSTALL ***"
