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
            Write-Output "$($TaskObject.TaskName) Scheduled Task is already disabled - $($_.Exception.Message)"
        }
        else {
            Write-Output "Unable to find Scheduled Task: $($TaskObject.TaskName) - $($_.Exception.Message)"
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
