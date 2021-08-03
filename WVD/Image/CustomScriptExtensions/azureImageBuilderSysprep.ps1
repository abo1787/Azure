# Write to AIB Output
$timeStamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
Write-Output "$timeStamp *** STARTING CUSTOM SYSPREP DOWNLOAD ***"

$customSysprepUrl = "https://raw.githubusercontent.com/Bistech/Azure/master/WVD/Image/CustomScriptExtensions/DeprovisioningScript.ps1"
$customSysprepFilePath = "C:\DeprovisioningScript.ps1"

# Download custom sysprep script
Invoke-WebRequest -Uri $customSysprepUrl -OutFile $customSysprepFilePath -UseBasicParsing

# Write to AIB Output
$timeStamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
Write-Output "$timeStamp *** COMPLETED CUSTOM SYSPREP DOWNLOAD ***"
