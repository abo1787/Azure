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

Set-Logger "C:\WindowsAzure\Logs\Plugins\Microsoft.Compute.CustomScriptExtension\executionLog\UKLocale" # inside "executionCustomScriptExtension_$scriptName_$date.log"

# Check osVersion to set correct Language Pack version
if($osVersion -eq "19h2-evd" -or $osVersion -eq "19h2-ent"){
    $Uri = "https://raw.githubusercontent.com/Bistech/Azure/master/WVD/Image/LangPacks/1909/en-GB.zip"
}
else{
    $Uri = "https://raw.githubusercontent.com/Bistech/Azure/master/WVD/Image/LangPacks/2004/en-GB.zip"
}

# Set Directory
$dirPath = "C:\Windows\Temp"
New-Item -Path $dirPath -Name "setLocaleUk" -ItemType Directory
$filePath = "C:\Windows\Temp\setLocaleUk"

# Get Local Experience Pack
Invoke-WebRequest -Uri $Uri -OutFile "$filePath\en-GB.zip"
$LangArchivePath = Join-Path $filePath "en-GB.zip"
    
# Prepare Local Experience Pack
Expand-Archive -Path $LangArchivePath -DestinationPath $filePath

# Get xml File
$xmlUri = "https://raw.githubusercontent.com/Bistech/Azure/master/WVD/Image/CustomScriptExtensions/setLocaleUk.xml"
Invoke-WebRequest -Uri $xmlUri -OutFile "$filePath\setLocaleUkAIB.xml"

# Get Locale Script
$localeUri = "https://raw.githubusercontent.com/Bistech/Azure/master/WVD/Image/CustomScriptExtensions/setLocaleUkAIB.ps1"
Invoke-WebRequest -Uri $localeUri -OutFile "$filePath\setLocaleUkAIB.ps1"

# Run setLocaleUk script
& "$filePath\setLocaleUkAIB.ps1"
