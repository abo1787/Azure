#region Parameters
[CmdletBinding(SupportsShouldProcess = $true)]
param (
    
  [string] $osVersion,
  [string] $executableName = "de-de.zip"
)

Write-Output "Starting Install German Language script..."
# Check osVersion to set correct Language Pack version
if ($osVersion -eq "19h2-evd" -or $osVersion -eq "19h2-ent") {
  $langPackUri = "https://raw.githubusercontent.com/Bistech/Azure/master/WVD/Image/LangPacks/1909/de-de.zip"
}
else {
  $langPackUri = "https://raw.githubusercontent.com/Bistech/Azure/master/WVD/Image/LangPacks/2004/de-de.zip"
}
$localeUri = "https://raw.githubusercontent.com/Bistech/Azure/master/WVD/Image/CustomScriptExtensions/setLocaleDeAIB.ps1"
#endregion

#region Check/Create Directory
Write-Output "Checking/Creating temporary download directory..."
$dirPath = "C:\Windows\Temp"
New-Item -Path $dirPath -Name "setLocaleDe" -ItemType Directory
$filePath = "C:\Windows\Temp\setLocaleDe"
#endregion

#region Download software
Write-Output "Downloading software..."
Invoke-WebRequest -Uri $langPackUri -OutFile "$filePath\de-de.zip"
Invoke-WebRequest -Uri $localeUri -OutFile "$filePath\setLocaleDeAIB.ps1"
#endregion

#region File Paths
$langArchivePath = Join-Path $filePath "de-de.zip"
#endregion
    
#region File Extraction
Write-Output "Extracting language packs..."
Expand-Archive -Path $langArchivePath -DestinationPath $filePath
#endregion

#region Install Software
Write-Output "Installing German Language Pack..."
& "$filePath\setLocaleDeAIB.ps1"
Write-Output "Completed installing German Language Pack"
#endregion