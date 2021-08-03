# Write to AIB Output
Write-Output "*** STARTING CUSTOM SYSPREP DOWNLOAD ***"

$customSysprepUrl = "https://raw.githubusercontent.com/Bistech/Azure/master/WVD/Image/CustomScriptExtensions/DeprovisioningScript.ps1"
$customSysprepFilePath = "C:\DeprovisioningScript.ps1"

# Download custom sysprep script
Invoke-WebRequest -Uri $customSysprepUrl -OutFile $customSysprepFilePath -UseBasicParsing

# Write to AIB Output
Write-Output "*** COMPLETED CUSTOM SYSPREP DOWNLOAD ***"
