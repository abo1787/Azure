# Set the ExecutionPolicy
Set-ExecutionPolicy -ExecutionPolicy Bypass -Scope CurrentUser -Force -Confirm:$false

# Set variables
$language = "de-de"
$filePath = "C:\Windows\Temp\setLocaleDe"
$LangPackName = "de-de\LanguageExperiencePack.de-de.Neutral.appx"
$LangPackPath = Join-Path $filePath $LangPackName
$LicenseName = "de-de\License.xml"
$LicensePath = Join-Path $filePath $LicenseName


# Provision Local Experience Pack
try {
   Write-Output "Adding de-de Language Pack.."
   Add-AppxProvisionedPackage -Online -PackagePath $LangPackPath -LicensePath $LicensePath
}
catch {
   Write-Output "Error - Couldnt install AppXPackage" -ErrorAction Stop
}

# Install optional features for language
$DECapabilities = Get-WindowsCapability -Online | Where-Object { $_.Name -match "$language" -and $_.State -ne "Installed" }
$DECapabilities | ForEach-Object {
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
$LanguageList.Add("de-de")
Set-WinUserLanguageList $LanguageList -Force

# Cleanup files
Write-Output "Cleaning up files.."
Remove-Item -Path "$filePath\de-de" -Force -Recurse
Remove-Item -Path "$filePath\de-de.zip" -Force -Recurse
Remove-Item $MyInvocation.MyCommand.Source
Remove-Item $filePath -Force -Recurse

Write-Output "All settings have been updated"
