[CmdletBinding(SupportsShouldProcess = $true)]
param (
    
   [string] $ExecutableName = "MsMMRHostInstaller.msi"

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

Set-Logger "C:\WindowsAzure\Logs\Plugins\Microsoft.Compute.CustomScriptExtension\executionLog\MultimediaRedirection" # inside "executionCustomScriptExtension_$scriptName_$date.log"

# Download installer
$Uri = "https://query.prod.cms.rt.microsoft.com/cms/api/am/binary/RE4QWrF"
Invoke-WebRequest -Uri $Uri -OutFile "$($PSScriptRoot)\$ExecutableName"
$MSIPath = "$($PSScriptRoot)\$ExecutableName"

# Set Reg key to enable
Set-Location HKLM:
LogInfo("Setting Multimedia Redirection registry key")
if ((Test-Path "Software\Microsoft\MSRDC\Policies") -eq $false) {
   New-Item -Path "Software\Microsoft\MSRDC\Policies" -Force
}
New-ItemProperty "Software\Microsoft\MSRDC\Policies" -Name "ReleaseRing" -Value "insider" -PropertyType String -Force
LogInfo("Set ReleaseRing Reg Key to value 'insider' successfully")

# Install
LogInfo("Installing Multimedia Redirection from path $MSIPath")
LogInfo("Invoking command with the following scriptblock: $scriptBlock")
$scriptBlock = { msiexec /i $MSIPath /qn /l*v "C:\WindowsAzure\Logs\Plugins\Microsoft.Compute.CustomScriptExtension\executionLog\MultimediaRedirection\InstallLog.txt" }
LogInfo("Invoking command with the following scriptblock: $scriptBlock")
LogInfo("Install logs can be found in the InstallLog.txt file in this folder.")
Invoke-Command $scriptBlock -Verbose

LogInfo("Multimedia Redirection was successfully installed")
