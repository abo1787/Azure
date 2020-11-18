[CmdletBinding(SupportsShouldProcess = $true)]
param (
    
    [Parameter(Mandatory = $false)]
    [ValidateNotNullOrEmpty()]
    [string] $ExecutableName = "OfficeDeploy.zip",

    [Parameter(mandatory = $false)]
	[string]$AppsToInstall

)

#####################################

##########
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

Set-Logger "C:\WindowsAzure\Logs\Plugins\Microsoft.Compute.CustomScriptExtension\executionLog\M365Apps" # inside "executionCustomScriptExtension_$scriptName_$date.log"

$Uri = "https://raw.githubusercontent.com/Bistech/Azure/master/WVD/Image/CustomScriptExtensions/OfficeDeploy.zip"
Invoke-WebRequest -Uri $Uri -OutFile "$($PSScriptRoot)\$ExecutableName"
$M365ArchivePath = Join-Path $PSScriptRoot "OfficeDeploy.zip"
Expand-Archive -Path $M365ArchivePath -DestinationPath $PSScriptRoot

$ExecutableName = "OfficeDeploy\setup.exe"
$M365ExePath = Join-Path $PSScriptRoot $ExecutableName

# Set switches to use correct config file
if($appsToInstall -eq "All"){
    $switches = "/configure .\OfficeDeploy\Configuration_AllApps.xml"
}
if($appsToInstall -eq "All except Access"){
    $switches = "/configure .\OfficeDeploy\Configuration_NoAccess.xml"
}
if($appsToInstall -eq "All except Access,OneNote"){
    $switches = "/configure .\OfficeDeploy\Configuration_NoAccessOneNote.xml"
}
if($appsToInstall -eq "All except Access,Publisher"){
    $switches = "/configure .\OfficeDeploy\Configuration_NoAccessPublisher.xml"
}
if($appsToInstall -eq "All except Access,OneNote,Publisher"){
    $switches = "/configure .\OfficeDeploy\Configuration_NoAccessPublisherOneNote.xml"
}
if($appsToInstall -eq "All except OneNote"){
    $switches = "/configure .\OfficeDeploy\Configuration_NoOneNote.xml"
}
if($appsToInstall -eq "All except OneNote,Publisher"){
    $switches = "/configure .\OfficeDeploy\Configuration_NoOneNotePublisher.xml"
}
if($appsToInstall -eq "All except Publisher"){
    $switches = "/configure .\OfficeDeploy\Configuration_NoPublisher.xml"
}

$Installer = Start-Process -FilePath $M365ExePath -ArgumentList $Switches -Wait -PassThru
LogInfo("The exit code is $($Installer.ExitCode)")
