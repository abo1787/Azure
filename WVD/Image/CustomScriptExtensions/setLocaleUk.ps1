[CmdletBinding(SupportsShouldProcess = $true)]
param (
    
    [string] $osVersion,
    [string] $xmlFileName = "setLocaleUk.xml"
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

Set-Logger "C:\WindowsAzure\Logs\Plugins\Microsoft.Compute.CustomScriptExtension\executionLog\UKLocale" # inside "executionCustomScriptExtension_$scriptName_$date.log"

# Language codes
$PrimaryLanguage = "en-GB"
$SecondaryLanguage = "en-US"
$PrimaryInputCode = "0809:00000809"
$SecondaryInputCode = "0409:00000409"
$PrimaryGeoID = "242"

# Check osVersion to set correct Language Pack version
if($osVersion -eq "19h2-evd" -or $osVersion -eq "19h2-ent"){
    $Uri = "https://raw.githubusercontent.com/Bistech/Azure/master/WVD/Image/LangPacks/1909/en-GB.zip"
}
else{
    $Uri = "https://raw.githubusercontent.com/Bistech/Azure/master/WVD/Image/LangPacks/2004/en-GB.zip"
}

# Provision Local Experience Pack
$DownloadedFile = "$PSScriptRoot\en-GB.zip"
Try
{
    $WebClient = New-Object System.Net.WebClient
    $WebClient.DownloadFile($Uri, $DownloadedFile)
    Unblock-File –Path $DownloadedFile –ErrorAction SilentlyContinue
    Expand-Archive –Path $DownloadedFile –DestinationPath $PSScriptRoot –Force –ErrorAction Stop
    Add-AppxProvisionedPackage –Online –PackagePath "$PSScriptRoot\en-gb\LanguageExperiencePack.en-gb.Neutral.appx" –LicensePath "$PSScriptRoot\en-gb\License.xml"
    Remove-Item –Path $DownloadedFile –Force –ErrorAction SilentlyContinue
}
Catch
{
    Write-Host "Failed to install Local Experience Pack: $_"
}

# Install optional features for primary language
$UKCapabilities = Get-WindowsCapability –Online | Where {$_.Name -match "$PrimaryLanguage" -and $_.State -ne "Installed"}
$UKCapabilities | foreach {
    Add-WindowsCapability –Online –Name $_.Name
}

$LanguageList = Get-WinUserLanguageList
$LanguageList.Add("en-gb")
Set-WinUserLanguageList $LanguageList -force

# Apply custom XML to set administrative language defaults
$XML = @"
<gs:GlobalizationServices xmlns:gs="urn:longhornGlobalizationUnattend">
 
<!– user list –> 
    <gs:UserList>
        <gs:User UserID="Current" CopySettingsToDefaultUserAcct="true" CopySettingsToSystemAcct="true"/> 
    </gs:UserList>
 
    <!– GeoID –>
    <gs:LocationPreferences> 
        <gs:GeoID Value="$PrimaryGeoID"/>
    </gs:LocationPreferences>
 
    <gs:MUILanguagePreferences>
        <gs:MUILanguage Value="$PrimaryLanguage"/>
        <gs:MUIFallback Value="$SecondaryLanguage"/>
    </gs:MUILanguagePreferences>

    <!– system locale –>
    <gs:SystemLocale Name="$PrimaryLanguage"/>
 
    <!– input preferences –>
    <gs:InputPreferences>
        <gs:InputLanguageID Action="add" ID="$PrimaryInputCode" Default="true"/>
        <gs:InputLanguageID Action="add" ID="$SecondaryInputCode"/>
      </gs:InputPreferences>
 
    <!– user locale –>
    <gs:UserLocale>
        <gs:Locale Name="$PrimaryLanguage" SetAsCurrent="true" ResetAllSettings="false"/>
    </gs:UserLocale>
 </gs:GlobalizationServices>
"@

New-Item $PSScriptRoot –Name "en-GB.xml" –ItemType File –Value $XML –Force

$Process = Start-Process –FilePath Control.exe –ArgumentList "intl.cpl,,/f:""$PSScriptRoot\en-GB.xml""" –NoNewWindow –PassThru –Wait
$Process.ExitCode

# Set Timezone
& tzutil /s "GMT Standard Time"

# Set languages/culture
#Set-Culture en-GB
#Set-WinSystemLocale en-GB
#Set-WinHomeLocation -GeoId 242
#Set-WinUserLanguageList en-GB -Force

LogInfo("The language script has finished. The osVersion was $osVersion. The vm will now be restarted")

Restart-Computer -Force
