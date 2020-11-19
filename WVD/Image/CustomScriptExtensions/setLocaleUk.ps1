[CmdletBinding(SupportsShouldProcess = $true)]
param (
    
    [string] $osVersion,
    [string] $ExecutableName = "en-GB.zip"
)

#####################################

# Helper #
##########
#region Functions
function LogInfo($message) {
    Log "Info" $message
}

function LogError($message) {
    Log "Error" $message
}

function LogSkip($message) {
    Log "Skip" $message
}
function LogWarning($message) {
    Log "Warning" $message
}

function Log {

    <#
    .SYNOPSIS
   Creates a log file and stores logs based on categories with tab seperation
    .PARAMETER category
    Category to put into the trace
    .PARAMETER message
    Message to be loged
    .EXAMPLE
    Log 'Info' 'Message'
    #>

    Param (
        $category = 'Info',
        [Parameter(Mandatory = $true)]
        $message
    )

    $date = get-date
    $content = "[$date]`t$category`t`t$message`n"
    Write-Verbose "$content" -verbose

    if (! $script:Log) {
        $File = Join-Path $env:TEMP "log.log"
        Write-Error "Log file not found, create new $File"
        $script:Log = $File
    }
    else {
        $File = $script:Log
    }
    Add-Content $File $content -ErrorAction Stop
}

function Set-Logger {
    <#
    .SYNOPSIS
    Sets default log file and stores in a script accessible variable $script:Log
    Log File name "executionCustomScriptExtension_$date.log"
    .PARAMETER Path
    Path to the log file
    .EXAMPLE
    Set-Logger
    Create a logger in
    #>

    Param (
        [Parameter(Mandatory = $true)]
        $Path
    )

    # Create central log file with given date

    $date = Get-Date -UFormat "%Y-%m-%d %H-%M-%S"

    $scriptName = (Get-Item $PSCommandPath ).Basename
    $scriptName = $scriptName -replace "-", ""

    Set-Variable logFile -Scope Script
    $script:logFile = "executionCustomScriptExtension_" + $scriptName + "_" + $date + ".log"

    if ((Test-Path $path ) -eq $false) {
        $null = New-Item -Path $path -type directory
    }

    $script:Log = Join-Path $path $logfile

    Add-Content $script:Log "Date`t`t`tCategory`t`tDetails"
}
#endregion

$mylogfile = "C:\WindowsAzure\Logs\Plugins\Microsoft.Compute.CustomScriptExtension\userlog.txt"

$dateTime = Get-Date -Format dd-MM-yy-HH:mm:ss
Add-Content $mylogfile -Value "$dateTime Starting script"
Add-Content $mylogfile -Value "$dateTime PSScriptRoot is $PSScriptRoot"

Set-Logger "C:\WindowsAzure\Logs\Plugins\Microsoft.Compute.CustomScriptExtension\executionLog\UKLocale" # inside "executionCustomScriptExtension_$scriptName_$date.log"

# Language codes
$PrimaryLanguage = "en-GB"

# Check osVersion to set correct Language Pack version
if($osVersion -eq "19h2-evd" -or $osVersion -eq "19h2-ent"){
    $Uri = "https://raw.githubusercontent.com/Bistech/Azure/master/WVD/Image/LangPacks/1909/en-GB.zip"
}
else{
    $Uri = "https://raw.githubusercontent.com/Bistech/Azure/master/WVD/Image/LangPacks/2004/en-GB.zip"
}

# Get Local Experience Pack
try {
    Invoke-WebRequest -Uri $Uri -OutFile "$($PSScriptRoot)\$ExecutableName"
    $LangArchivePath = Join-Path $PSScriptRoot "en-GB.zip"
    $LangPackName = "en-gb\LanguageExperiencePack.en-gb.Neutral.appx"
    $LangPackPath = Join-Path $PSScriptRoot $LangPackName
    $LicenseName = "en-gb\License.xml"
    $LicensePath = Join-Path $PSScriptRoot $LicenseName

    $dateTime = Get-Date -Format dd-MM-yy-HH:mm:ss
    Add-Content $mylogfile -Value "$dateTime Downloaded language packs"
    Add-Content $mylogfile -Value "$dateTime LangArchivePath is $LangArchivePath"
    Add-Content $mylogfile -Value "$dateTime LangPackPath is $LangPackPath"
    Add-Content $mylogfile -Value "$dateTime LicensePath is $LicensePath"
}
catch{
    $dateTime = Get-Date -Format dd-MM-yy-HH:mm:ss
    Add-Content $mylogfile -Value "$dateTime Couldnt download language packs"
}

# Provision Local Experience Pack
try{
    Unblock-File –Path $LangArchivePath –ErrorAction SilentlyContinue
    Expand-Archive -Path $LangArchivePath -DestinationPath $PSScriptRoot
    Add-AppxProvisionedPackage –Online –PackagePath $LangPackPath –LicensePath $LicensePath
    #Remove-Item –Path $LangArchivePath –Force –ErrorAction SilentlyContinue
    $dateTime = Get-Date -Format dd-MM-yy-HH:mm:ss
    Add-Content $mylogfile -Value "$dateTime Added AppXPackage"
}
catch{
    $dateTime = Get-Date -Format dd-MM-yy-HH:mm:ss
    Add-Content $mylogfile -Value "$dateTime Couldnt install language packs"
}
# Install optional features for primary language
$UKCapabilities = Get-WindowsCapability –Online | Where {$_.Name -match "$PrimaryLanguage" -and $_.State -ne "Installed"}
$UKCapabilities | foreach {
    Add-WindowsCapability –Online –Name $_.Name
    Add-Content $mylogfile -Value "Adding capability $($_.Name)"
}

$LanguageList = Get-WinUserLanguageList
$LanguageList.Add("en-gb")
Set-WinUserLanguageList $LanguageList -force

# Get xml File
$xmlFile = "setLocaleUk.xml"
$xmlUri = "https://raw.githubusercontent.com/Bistech/Azure/master/WVD/Image/CustomScriptExtensions/setLocaleUk.xml"
Invoke-WebRequest -Uri $xmlUri -OutFile "$($PSScriptRoot)\$xmlFile"
$xmlPath = Join-Path $PSScriptRoot $xmlFile

$dateTime = Get-Date -Format dd-MM-yy-HH:mm:ss
Add-Content $mylogfile -Value "$dateTime Downloading XML file"
Add-Content $mylogfile -Value "$dateTime XML Path is $xmlPath"

$dateTime = Get-Date -Format dd-MM-yy-HH:mm:ss
Add-Content $mylogfile -Value "$dateTime Setting cultures"

# Set Languages/Culture
Set-Culture en-GB
Set-WinSystemLocale en-GB
Set-WinHomeLocation -GeoId 242
Set-WinUserLanguageList en-GB -Force

$dateTime = Get-Date -Format dd-MM-yy-HH:mm:ss
Add-Content $mylogfile -Value "$dateTime Trying to run control.exe next"

# Set Timezone
& tzutil /s "GMT Standard Time"
