# Write to AIB Output
$timeStamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
Write-Output "$timeStamp *** STARTING DISK CLEANUP ***"

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

Write-Output 'Adding disk cleanup settings...'
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

Write-Output 'Cleaning...'
Get-Item -Path "C:\Windows\Temp\*" -Exclude "packer*", "script*", "mat*", "*.ses", "CreativeCloud*", "pdf24*" | Remove-Item -Recurse -Force
Start-Process -FilePath CleanMgr.exe -ArgumentList '/sagerun:1' -WindowStyle Hidden
Start-Sleep -Seconds 60

$diskCleanupRunning = Get-Process | Where-Object { $_.MainWindowTitle -eq 'Disk Clean-up' }
while ($diskCleanupRunning) {
    $diskCleanupRunning = Get-Process | Where-Object { $_.MainWindowTitle -eq 'Disk Clean-up' }
    Start-Sleep -Seconds 10
}
Write-Output 'Cleaning complete!'
Stop-Process -Name cleanmgr
Write-Output 'Restoring default disk cleanup settings...'
Get-ItemProperty @getItemParams | Remove-ItemProperty -Name StateFlags0001 -ErrorAction SilentlyContinue
$timeStamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
Write-Output "$timeStamp *** COMPLETED DISK CLEANUP ***"
