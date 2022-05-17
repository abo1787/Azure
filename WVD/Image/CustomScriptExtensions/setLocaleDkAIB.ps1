# Set the ExecutionPolicy
Set-ExecutionPolicy -ExecutionPolicy Bypass -Scope CurrentUser -Force -Confirm:$false

# Set variables
$language = "da-DK"
$filePath = "C:\Windows\Temp\setLocaleDk"
$LangPackName = "da-DK\LanguageExperiencePack.da-DK.Neutral.appx"
$LangPackPath = Join-Path $filePath $LangPackName
$LicenseName = "da-DK\License.xml"
$LicensePath = Join-Path $filePath $LicenseName


# Provision Local Experience Pack
try {
   Write-Output "Adding da-dK Language Pack.."
   Add-AppxProvisionedPackage -Online -PackagePath $LangPackPath -LicensePath $LicensePath
}
catch {
   Write-Output "Error - Couldnt install AppXPackage" -ErrorAction Stop
}

# Install optional features for language
$DKCapabilities = Get-WindowsCapability -Online | Where-Object { $_.Name -match "$language" -and $_.State -ne "Installed" }
$DKCapabilities | ForEach-Object {
   Write-Output "Adding capability $($_.Name).."
   try {
      Add-WindowsCapability -Online -Name $_.Name
   }
   catch {
      Write-Output "Error Adding capability $($_.Name)"
   }
}

# Set Language List
Write-Output "Setting Language list.."
$LanguageList = Get-WinUserLanguageList
$LanguageList.Add("da-DK")
Set-WinUserLanguageList $LanguageList -Force

# Cleanup files
Write-Output "Cleaning up files.."
Remove-Item -Path "$filePath\da-DK" -Force -Recurse
Remove-Item -Path "$filePath\da-DK.zip" -Force -Recurse
Remove-Item $MyInvocation.MyCommand.Source
Remove-Item $filePath -Force -Recurse

Write-Output "All settings have been updated"
