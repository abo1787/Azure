# Write to AIB Output
$timeStamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
Write-Output "$timeStamp *** STARTING OFFICE 365 INSTALL ***"

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
Start-Process -FilePath $executableName -ArgumentList $switches -Wait -PassThru -NoNewWindow

# Write to AIB Output
$timeStamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
Write-Output "$timeStamp *** COMPLETED OFFICE 365 INSTALL ***"
