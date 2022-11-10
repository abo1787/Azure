#region Parameters
[CmdletBinding(SupportsShouldProcess = $true)]
param (
    
  [string] $osVersion,
  [string] $executableName = "en-GB.zip"
)

Write-Output "Starting Install UK Language script..."
# Check osVersion to set correct Language Pack version
if ($osVersion -eq "19h2-evd" -or $osVersion -eq "19h2-ent") {
  $langPackUri = "https://raw.githubusercontent.com/Bistech/Azure/master/WVD/Image/LangPacks/1909/en-GB.zip"
}
else {
  $langPackUri = "https://raw.githubusercontent.com/Bistech/Azure/master/WVD/Image/LangPacks/2004/en-GB.zip"
}
$xmlUri = "https://raw.githubusercontent.com/Bistech/Azure/master/WVD/Image/CustomScriptExtensions/setLocaleUk.xml"
$localeUri = "https://raw.githubusercontent.com/Bistech/Azure/master/WVD/Image/CustomScriptExtensions/setLocaleUkAIB.ps1"
#endregion

#region Check/Create Directory
Write-Output "Checking/Creating temporary download directory..."
$dirPath = "C:\Windows\Temp"
New-Item -Path $dirPath -Name "setLocaleUk" -ItemType Directory
$filePath = "C:\Windows\Temp\setLocaleUk"
#endregion

#region Download software
Write-Output "Downloading software..."
Invoke-WebRequest -Uri $langPackUri -OutFile "$filePath\en-GB.zip"
Invoke-WebRequest -Uri $xmlUri -OutFile "$filePath\setLocaleUkAIB.xml"
Invoke-WebRequest -Uri $localeUri -OutFile "$filePath\setLocaleUkAIB.ps1"
#endregion

#region File Paths
$langArchivePath = Join-Path $filePath "en-GB.zip"
#endregion
    
#region File Extraction
Write-Output "Extracting language packs..."
Expand-Archive -Path $langArchivePath -DestinationPath $filePath
#endregion

#region Install Software
Write-Output "Installing UK Language Pack..."
& "$filePath\setLocaleUkAIB.ps1"
Write-Output "Completed installing UK Language Pack"
#endregion