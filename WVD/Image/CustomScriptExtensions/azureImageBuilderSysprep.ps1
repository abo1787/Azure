$customSysprepUrl = "https://raw.githubusercontent.com/Bistech/Azure/master/WVD/Image/CustomScriptExtensions/DeprovisioningScript.ps1"
$customSysprepFilePath = "C:\DeprovisioningScript.ps1"

# Download custom sysprep script
Invoke-WebRequest -Uri $customSysprepUrl -OutFile $customSysprepFilePath -UseBasicParsing
