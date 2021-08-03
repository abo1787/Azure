# Write to AIB Output
Write-Output "*** STARTING OFFICE 365 INSTALL ***"

# Download Office365
$office365Uri = "https://raw.githubusercontent.com/Bistech/Azure/master/WVD/Image/CustomScriptExtensions/OfficeDeploy.zip"
Invoke-WebRequest -Uri $office365Uri -OutFile "C:\Windows\Temp\OfficeDeploy.zip"
Expand-Archive -Path "C:\Windows\Temp\OfficeDeploy.zip" -DestinationPath "C:\Windows\Temp"

# Set paths
$executableName = "C:\Windows\Temp\OfficeDeploy\setup.exe"
$customOfficeFile = "C:\Windows\Temp\OfficeConfiguration.xml"

# Set switches to use config file
$switches = "/configure $customOfficeFile"

# Install Office
Start-Process -FilePath $executableName -ArgumentList $switches -PassThru

# Write to AIB Output
Write-Output "*** COMPLETED OFFICE 365 INSTALL ***"
