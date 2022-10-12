<# 
.SYNOPSIS
    This script automates the preparation process on the image VM 

.DESCRIPTION
    This script is designed to optimize the vm image and run sysprep. The script
    will perform the following actions:

      •	Remove all App-X packages that can cause sysprep to fail
      •	Optimize the machine by disabling scheduled tasks and services not needed within a VDI environment
      •	Remove all user profiles except for the currently logged in user
      •	Run disk clean-up to remove all temporary files
      •	Sysprep the machine

.NOTES
    Author  : Dave Pierson
    Version : 1.0.0

    # THIS SOFTWARE IS PROVIDED "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, 
    # INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY 
    # AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL 
    # THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, 
    # INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT 
    # NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, 
    # DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY 
    # THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT 
    # (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE 
    # OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
#>

# Write to AIB Output
$timeStamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
Write-Output "$timeStamp *** STARTING OPTIMIZATION SCRIPT ***"

# Check for secure boot
$secureBoot = Confirm-SecureBootUEFI
if ($secureBoot -eq $true) {
  add-type @"
    using System.Net;
    using System.Security.Cryptography.X509Certificates;
    public class TrustAllCertsPolicy : ICertificatePolicy {
        public bool CheckValidationResult(
            ServicePoint srvPoint, X509Certificate certificate,
            WebRequest request, int certificateProblem) {
            return true;
        }
    }
"@
  [System.Net.ServicePointManager]::CertificatePolicy = New-Object TrustAllCertsPolicy
}

# Create directory for file download
$dirPath = "C:\Windows\Temp"
New-Item -Path $dirPath -Name "optimizationFiles" -ItemType Directory

# Download files
$appxConfigFileUri = "https://raw.githubusercontent.com/Bistech/Azure/master/WVD/Image/CustomScriptExtensions/Optimize/AppXPackages.json"
$scheduledTasksFileUri = "https://raw.githubusercontent.com/Bistech/Azure/master/WVD/Image/CustomScriptExtensions/Optimize/ScheduledTasks.json"
$servicesFileUri = "https://raw.githubusercontent.com/Bistech/Azure/master/WVD/Image/CustomScriptExtensions/Optimize/Services.json"
$appxConfigFilePath = "C:\Windows\Temp\optimizationFiles\AppxPackages.json"
$scheduledTasksFilePath = "C:\Windows\Temp\optimizationFiles\ScheduledTasks.json"
$servicesFilePath = "C:\Windows\Temp\optimizationFiles\Services.json"

Invoke-WebRequest -Uri $appxConfigFileUri -OutFile $appxConfigFilePath -UseBasicParsing
Invoke-WebRequest -Uri $scheduledTasksFileUri -OutFile $scheduledTasksFilePath -UseBasicParsing
Invoke-WebRequest -Uri $servicesFileUri -OutFile $servicesFilePath -UseBasicParsing
((Get-Content -path $appxConfigFilePath -Raw) -replace '<OneNote>', 'Enabled') | Set-Content -Path $appxConfigFilePath

#region AppXPackages
# Remove all Appx Packages marked as 'Disabled'
$appxPackages = (Get-Content $appxConfigFilePath | ConvertFrom-Json).Where( { $_.VDIState -eq 'Disabled' })
if ($appxPackages.Count -gt 0) {

  foreach ($appxPackage in $appxPackages) {
    try {                
      Get-AppxProvisionedPackage -Online | Where-Object { $_.PackageName -like ("*{0}*" -f $appxPackage.AppxPackage) } | Remove-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue | Out-Null
      Get-AppxPackage -AllUsers -Name ("*{0}*" -f $appxPackage.AppxPackage) | Remove-AppxPackage -AllUsers -ErrorAction SilentlyContinue 
      Get-AppxPackage -Name ("*{0}*" -f $appxPackage.AppxPackage) | Remove-AppxPackage -ErrorAction SilentlyContinue | Out-Null
      Write-Output "Removed Appx Package $($appxPackage.AppxPackage)"
    }
    catch {
      Write-Warning "Failed to remove Appx Package $($appxPackage.AppxPackage) - $($_.Exception.Message)"
    }
  }
}
else {
  Write-Output "No AppxPackages set to disabled in $appxConfigFilePath"
}
#endregion

#region Scheduled Tasks
$scheduledTasks = (Get-Content $scheduledTasksFilePath | ConvertFrom-Json).Where( { $_.VDIState -eq 'Disabled' })
if ($scheduledTasks.count -gt 0) {

  foreach ($scheduledTask in $scheduledTasks) {
    $taskObject = Get-ScheduledTask $scheduledTask.ScheduledTask
    if ($taskObject -and $taskObject.State -ne 'Disabled') {
      try {
        Disable-ScheduledTask -InputObject $taskObject | Out-Null
        Write-Output "Disabled Scheduled Task: $($taskObject.TaskName)"
      }
      catch {
        Write-Warning "Failed to disabled Scheduled Task: $($taskObject.TaskName) - $($_.Exception.Message)"
      }
    }
    elseIf ($taskObject -and $taskObject.State -eq 'Disabled') {
      Write-Output "Scheduled Task '$($TaskObject.TaskName)' is already disabled - $($_.Exception.Message)"
    }
    else {
      if (!$TaskObject.TaskName) {
        Write-Output "Unable to find Scheduled Task: $scheduledTask - $($_.Exception.Message)"
      }
      else {
        Write-Output "Unable to find Scheduled Task: $($TaskObject.TaskName) - $($_.Exception.Message)"
      }
    }
  }
}
else {
  Write-Output "No Scheduled Tasks set to disabled in $scheduledTasksFilePath"
}
#endregion

#region Services
$services = (Get-Content $servicesFilePath | ConvertFrom-Json ).Where( { $_.VDIState -eq 'Disabled' })
if ($services.count -gt 0) {

  foreach ($service in $services) {
    try {
      Stop-Service $service.Name -Force -ErrorAction SilentlyContinue
      Write-Output "Stopped Service: $($service.Name)"
    }
    catch {
      Write-Warning "Failed to disable Service: $($service.Name) `n $($_.Exception.Message)"
    }
    Set-Service $service.Name -StartupType Disabled
    Write-Output "Set Service: $($service.Name) start-up type to 'Disabled'"
  }
} 
else {
  Write-Output "No Services set to disabled in $servicesFilePath"
}
#endregion

#region Cleanup
Write-Output "Starting Image Cleanup..."

# Remove all user profiles except for the logged in user and system profiles
Write-Output 'Removing all user profiles except for the current logged in user...'
try {
  Get-CimInstance -ClassName Win32_UserProfile | Where-Object { ($_.LocalPath -ne $env:USERPROFILE) -and (!$_.Special) } | Remove-CimInstance
}
catch [exception] {
  $_.message
  exit
}

# Run disk cleanup on all possible areas
$sections = @(
  'Active Setup Temp Folders',
  'BranchCache',
  'Content Indexer Cleaner',
  'Device Driver Packages',
  'Downloaded Program Files',
  'GameNewsFiles',
  'GameStatisticsFiles',
  'GameUpdateFiles',
  'Internet Cache Files',
  'Memory Dump Files',
  'Offline Pages Files',
  'Old ChkDsk Files',
  'Previous Installations',
  'Recycle Bin',
  'Service Pack Cleanup',
  'Setup Log Files',
  'System error memory dump files',
  'System error minidump files',
  'Temporary Files',
  'Temporary Setup Files',
  'Temporary Sync Files',
  'Thumbnail Cache',
  'Update Cleanup',
  'Upgrade Discarded Files',
  'User file versions',
  'Windows Defender',
  'Windows Error Reporting Archive Files',
  'Windows Error Reporting Queue Files',
  'Windows Error Reporting System Archive Files',
  'Windows Error Reporting System Queue Files',
  'Windows ESD installation files',
  'Windows Upgrade Log Files'
)

Write-Output 'Clearing any previous disk cleanup settings...'

$getItemParams = @{
  Path        = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\VolumeCaches\*'
  Name        = 'StateFlags0001'
  ErrorAction = 'SilentlyContinue'
}
Get-ItemProperty @getItemParams | Remove-ItemProperty -Name StateFlags0001 -ErrorAction SilentlyContinue

Write-Output 'Adding image disk cleanup settings...'
foreach ($keyName in $sections) {
  $newItemParams = @{
    Path         = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\VolumeCaches\$keyName"
    Name         = 'StateFlags0001'
    Value        = 2
    PropertyType = 'DWord'
    ErrorAction  = 'SilentlyContinue'
  }
  $null = New-ItemProperty @newItemParams
}

Write-Output 'Running Disk Cleanup...'
Start-Process -FilePath CleanMgr.exe -ArgumentList '/sagerun:1' -WindowStyle Hidden
Start-Sleep -Seconds 180

$diskCleanupRunning = Get-Process | Where-Object { $_.MainWindowTitle -eq 'Disk Clean-up' }
while ($diskCleanupRunning) {
  $diskCleanupRunning = Get-Process | Where-Object { $_.MainWindowTitle -eq 'Disk Clean-up' }
  Start-Sleep -Seconds 10
}
Write-Output 'Disk Cleanup complete!'
Stop-Process -Name cleanmgr
Write-Output 'Restoring default disk cleanup settings...'
Get-ItemProperty @getItemParams | Remove-ItemProperty -Name StateFlags0001 -ErrorAction SilentlyContinue
Write-Output 'Default disk cleanup settings restored'
#endregion

# Write to AIB Output
$timeStamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
Write-Output "$timeStamp *** COMPLETED OPTMIZATION SCRIPT ***"
