#region Parameters
[CmdletBinding(SupportsShouldProcess = $true)]
param (
    
  [string] $osVersion,
  [string] $executableName = "da-DK.zip"
)

Write-Output "Starting Install Danish Language script..."
# Check osVersion to set correct Language Pack version
if ($osVersion -eq "19h2-evd" -or $osVersion -eq "19h2-ent") {
  $langPackUri = "https://raw.githubusercontent.com/Bistech/Azure/master/WVD/Image/LangPacks/1909/da-DK.zip"
}
else {
  $langPackUri = "https://raw.githubusercontent.com/Bistech/Azure/master/WVD/Image/LangPacks/2004/da-DK.zip"
}
$localeUri = "https://raw.githubusercontent.com/Bistech/Azure/master/WVD/Image/CustomScriptExtensions/setLocaleDkAIB.ps1"
#endregion

#region Check/Create Directory
Write-Output "Checking/Creating temporary download directory..."
$dirPath = "C:\Windows\Temp"
New-Item -Path $dirPath -Name "setLocaleDk" -ItemType Directory
$filePath = "C:\Windows\Temp\setLocaleDk"
#endregion

#region Download software
Write-Output "Downloading software..."
Invoke-WebRequest -Uri $langPackUri -OutFile "$filePath\da-DK.zip"
Invoke-WebRequest -Uri $localeUri -OutFile "$filePath\setLocaleDkAIB.ps1"
#endregion

#region File Paths
$langArchivePath = Join-Path $filePath "da-DK.zip"
#endregion
    
#region File Extraction
Write-Output "Extracting language packs..."
Expand-Archive -Path $langArchivePath -DestinationPath $filePath
#endregion

#region Install Software
Write-Output "Installing Danish Language Pack..."
& "$filePath\setLocaleDkAIB.ps1"
Write-Output "Completed installing Danish Language Pack"
#endregion