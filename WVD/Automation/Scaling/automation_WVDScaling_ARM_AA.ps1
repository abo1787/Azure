<# 
.SYNOPSIS
    This script automates the powering on and off of session hosts within a WVD hostpool. 

.DESCRIPTION
    This script is designed to help organisations to both save compute costs for their WVD environment by ensuring only the required amount of resource is running at 
    the time and ensure that there are enough resources available to satisfy user density. The runbook is ran on a specified schedule, usually every 15 minutes, and 
    performs the following steps:
      1.	Receives all the parameters in from the scaling parameters file
      2.	Checks the current day and time against the specified ‘WorkDays’ and ‘Peak Start/End Times, and also against the UK Bank Holidays and Custom Holidays if applicable '’
      3.	Sets the appropriate Peak/Off Peak parameters, Load-Balancing method and ‘Maximum Sessions per Host’ based on Step 2
      4.	Checks all hosts in the pool and where the ‘Maintenance Tag’ value is set to True, sets these hosts into ‘Drain Mode’ if they are not already. These hosts are ignored when performing the rest of the calculations and will have no action taken on them.
      5.	Checks to see if the number of available hosts is less than the minimum required as set in the parameter file, and if true, starts valid hosts to reach this number
      6.	If it has just transitioned from Peak into Off-Peak hours, checks for the presence of a non-zero value in the ‘LimitSecondsToForceLogOffUser’ parameter and if true:
        a.	Puts all available hosts into ‘Drain Mode’
        b.	Sends the log off message to all users and waits for the timer to expire
        c.	Logs out any remaining users that have not logged out themselves
        d.	Shuts down all available hosts until the Off-Peak minimum required as set in the parameter file
        e.	Reverts ‘Drain Mode’ on these hosts to allow connections again
      7.	Checks to see if any available host has surpassed the ‘Scale Factor’ and if true:
        a.	Checks for available capacity on other running hosts
        b.	If none is found, another host is started if there is a valid host available to start
      8.	Check for any available host that has 0 sessions and if true:
        a.	Ensure that if this host were to be shut down, the minimum required hosts value would still be met
        b.	Checks for available capacity on other running hosts if this host were to be shut down
        c.	Shuts down the host if a & b both pass the test (test b is not evaluated if it's Off-Peak and Off-Peak minimum sessions are set to 0)
      9.	Writes logs to Log Analytics

.NOTES
    Author  : Dave Pierson
    Version : 4.3.0

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

param(
  [Parameter(mandatory = $false)]
  [object]$webHookData
)
# If the runbook was called from a Webhook, the WebhookData will not be null.
if ($webHookData) {

  # Collect properties of WebhookData
  $webhookName = $webHookData.WebhookName
  $webhookHeaders = $webHookData.RequestHeader
  $webhookBody = $webHookData.RequestBody

  # Collect individual headers. Input converted from JSON.
  $from = $webhookHeaders.From
  $input = (ConvertFrom-Json -InputObject $webhookBody)
}
else {
  Write-Error -Message 'Runbook was not started from Webhook' -ErrorAction stop
}

# Assign variable values from input
$subscriptionID = $Input.SubscriptionID
$resourceGroupName = $Input.ResourceGroupName
$hostPoolName = $Input.HostPoolName
$workDays = $Input.WorkDays
$beginPeakTime = $Input.BeginPeakTime
$endPeakTime = $Input.EndPeakTime
$timeZone = $Input.TimeZone
$peakLoadBalancingType = $Input.PeakLoadBalancingType
$offPeakLoadBalancingType = $Input.OffPeakLoadBalancingType
$peakMaxSessions = $Input.PeakMaxSessions
$offpeakMaxSessions = $Input.OffPeakMaxSessions
$peakScaleFactor = $Input.PeakScaleFactor
$offpeakScaleFactor = $Input.OffpeakScaleFactor
$peakMinimumNumberOfRDSH = $Input.PeakMinimumNumberOfRDSH
$offpeakMinimumNumberOfRDSH = $Input.OffpeakMinimumNumberOfRDSH
$jobTimeout = 420
$limitSecondsToForceLogOffUser = $Input.LimitSecondsToForceLogOffUser
$logOffMessageTitle = $Input.LogOffMessageTitle
$logOffMessageBody = $Input.LogOffMessageBody
$maintenanceTagName = $Input.MaintenanceTagName
$logAnalyticsWorkspaceId = $Input.LogAnalyticsWorkspaceId
$logAnalyticsPrimaryKey = $Input.LogAnalyticsPrimaryKey
$vmDiskType = $Input.VMDiskType
$observeUKBankHolidays = $Input.ObserveUKBankHolidays
$customHolidays = $Input.CustomHolidays

# Set Log Analytics log name
$logName = 'WVDScaling_CL'

Set-ExecutionPolicy -ExecutionPolicy Undefined -Scope Process -Force -Confirm:$false
Set-ExecutionPolicy -ExecutionPolicy Unrestricted -Scope LocalMachine -Force -Confirm:$false

# Setting ErrorActionPreference to stop script execution when error occurs
$ErrorActionPreference = "Stop"

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# Function to add logs to Log Analytics Workspace
function Add-LogEntry {
  param(
    [Object]$logMessageObj,
    [string]$logAnalyticsWorkspaceId,
    [string]$logAnalyticsPrimaryKey,
    [string]$logType
  )

  foreach ($key in $logMessage.Keys) {
    switch ($key.substring($key.Length - 2)) {
      '_s' { $sep = '"'; $trim = $key.Length - 2 }
      '_t' { $sep = '"'; $trim = $key.Length - 2 }
      '_b' { $sep = ''; $trim = $key.Length - 2 }
      '_d' { $sep = ''; $trim = $key.Length - 2 }
      '_g' { $sep = '"'; $trim = $key.Length - 2 }
      default { $sep = '"'; $trim = $key.Length }
    }
    $logData = $logData + '"' + $key.substring(0, $trim) + '":' + $sep + $logMessageObj.Item($key) + $sep + ','
  }

  $json = "{$($logData)}"
  $postResult = Send-OMSAPIIngestionFile -CustomerId $logAnalyticsWorkspaceId -SharedKey $logAnalyticsPrimaryKey -Body "$json" -LogType $logType
    
  if ($postResult -ne "Accepted") {
    Write-Error "Error when posting data to Log Analytics - $postResult"
  }
}

# Authenticate to Azure 
$azAuthentication = Connect-AzAccount -Identity
if (!$azAuthentication) {
  Write-Error "Failed to authenticate to Azure using the Automation Account Managed Identity $($_.exception.message)"
  exit
} 
else {
  Write-Output "Successfully authenticated to Azure using the Automation Account"
}

# Set the Azure context with Subscription
$azContext = Set-AzContext -SubscriptionId $subscriptionID
if (!$azContext) {
  Write-Error "Subscription '$subscriptionID' does not exist. Ensure that you have entered the correct values"
  exit
} 
else {
  Write-Output "Set the Azure context to the subscription named '$($azContext.Subscription.Name)' with Id '$($azContext.Subscription.Id)'"
}

# Convert Datetime format and construct Begin Peak and End Peak times for the Peak/Off-Peak periods
$currentDateTime = [System.TimeZoneInfo]::ConvertTimeBySystemTimeZoneId((Get-Date).ToUniversalTime(), $timeZone)
$beginPeakDateTime = [datetime]::Parse($currentDateTime.ToShortDateString() + ' ' + $beginPeakTime)
$endPeakDateTime = [datetime]::Parse($currentDateTime.ToShortDateString() + ' ' + $endPeakTime)

# Check the calculated end peak time is later than begin peak time in case of going between days
if ($endPeakDateTime -lt $beginPeakDateTime) {
  if ($currentDateTime -lt $endPeakDateTime) { $beginPeakDateTime = $beginPeakDateTime.AddDays(-1) } else { $endPeakDateTime = $endPeakDateTime.AddDays(1) }
}

# Create the time period for the Peak to Off Peak Transition period
$peakToOffPeakTransitionTime = $endPeakDateTime.AddMinutes(15)

# Check given hostpool name exists
$hostpoolInfo = Get-AzWvdHostPool -ResourceGroupName $resourceGroupName -Name $hostpoolName
if (!$hostpoolInfo) {
  Write-Error "Hostpoolname '$hostpoolName' does not exist. Ensure that you have entered the correct values"
  exit
}	

# Get todays day of week for comparing to Work Days along with todays date for comparing to Bank Holidays and Custom Holidays
$today = (Get-Date).DayOfWeek
$todaysDate = Get-Date -Format yyyy-MM-dd

# If observeUKBankHolidays is set to true then get list of holidays
if ($observeUKBankHolidays -eq $true) {
  $holidayAPI = 'https://www.gov.uk/bank-holidays.json'
  try {
    $holidays = Invoke-RestMethod -Uri $holidayAPI
    $holidays = $holidays.'england-and-wales'.events.date
  }
  catch {
    Write-Warning "Holiday API did not respond so cannot check Bank Holidays" -ErrorAction SilentlyContinue
  }

  # Check if today is a bank holiday
  if ($holidays -contains $todaysDate) {
    $bankHoliday = $true
    Write-Output "Today is a UK Bank Holiday so host pool will be kept in Off-Peak"
  }
}

# If customHolidays has data within it then check if today is contained within the customHolidays list
if ($customHolidays) {
  if ($customHolidays -contains $todaysDate) {
    $customHoliday = $true
    Write-Output "Today is a custom holiday so host pool will be kept in Off-Peak"
  }
}

# Compare Work Days,Peak Hours,Bank Holidays and Custom Holidays and set up appropriate load balancing type based on PeakLoadBalancingType & OffPeakLoadBalancingType
if (($currentDateTime -ge $beginPeakDateTime -and $currentDateTime -le $endPeakDateTime) -and ($workDays -contains $today) -and (!$bankHoliday) -and (!$customHoliday)) {
  Write-Output "It is currently within Peak hours"
  if ($hostpoolInfo.LoadBalancerType -ne $peakLoadBalancingType) {
    Write-Output "Changing hostpool Load Balance Type to: $peakLoadBalancingType Load Balancing"

    if ($peakLoadBalancingType -eq "DepthFirst") {                
      Update-AzWvdHostPool -ResourceGroupName $resourceGroupName -Name $hostpoolName -LoadBalancerType 'DepthFirst' -MaxSessionLimit $hostpoolInfo.MaxSessionLimit | Out-Null
    }
    else {
      Update-AzWvdHostPool -ResourceGroupName $resourceGroupName -Name $hostpoolName -LoadBalancerType 'BreadthFirst' -MaxSessionLimit $hostpoolInfo.MaxSessionLimit | Out-Null
    }
  }
  # Compare MaxSessionLimit of hostpool to peakMaxSessions value and adjust if necessary
  if ($hostpoolInfo.MaxSessionLimit -ne $peakMaxSessions) {
    Write-Output "Changing hostpool Peak Maximum Session Limit to: $peakMaxSessions"

    if ($peakLoadBalancingType -eq "DepthFirst") {
      Update-AzWvdHostPool -ResourceGroupName $resourceGroupName -Name $hostpoolName -LoadBalancerType 'DepthFirst' -MaxSessionLimit $peakMaxSessions | Out-Null
    }
    else {
      Update-AzWvdHostPool -ResourceGroupName $resourceGroupName -Name $hostpoolName -LoadBalancerType 'BreadthFirst' -MaxSessionLimit $peakMaxSessions | Out-Null
    }
  }
}
else {
  Write-Output "It is currently within Off-Peak hours"
  if ($hostpoolInfo.LoadBalancerType -ne $offPeakLoadBalancingType) {
    Write-Output "Changing hostpool Load Balance Type to: $offPeakLoadBalancingType Load Balancing"
        
    if ($offPeakLoadBalancingType -eq "DepthFirst") {                
      Update-AzWvdHostPool -ResourceGroupName $resourceGroupName -Name $hostpoolName -LoadBalancerType 'DepthFirst' -MaxSessionLimit $hostpoolInfo.MaxSessionLimit | Out-Null
    }
    else {
      Update-AzWvdHostPool -ResourceGroupName $resourceGroupName -Name $hostpoolName -LoadBalancerType 'BreadthFirst' -MaxSessionLimit $hostpoolInfo.MaxSessionLimit | Out-Null
    }
  }
  # Compare MaxSessionLimit of hostpool to offpeakMaxSessions value and adjust if necessary
  if ($hostpoolInfo.MaxSessionLimit -ne $offpeakMaxSessions) {
    Write-Output "Changing hostpool Off-Peak Maximum Session Limit to: $offpeakMaxSessions"

    if ($peakLoadBalancingType -eq "DepthFirst") {
      Update-AzWvdHostPool -ResourceGroupName $resourceGroupName -Name $hostpoolName -LoadBalancerType 'DepthFirst' -MaxSessionLimit $offpeakMaxSessions | Out-Null
    }
    else {
      Update-AzWvdHostPool -ResourceGroupName $resourceGroupName -Name $hostpoolName -LoadBalancerType 'BreadthFirst' -MaxSessionLimit $offpeakMaxSessions | Out-Null
    }
  }
}

# Check that host pool has Session Hosts within it
$allSessionHosts = Get-AzWvdSessionHost -ResourceGroupName $resourceGroupName -HostPoolName $hostpoolName
if (!$allSessionHosts) {
  Write-Error "No session hosts exist within the Hostpool '$HostpoolName'. Ensure that the hostpool has hosts within it"
  exit
}

# Check for VM's with maintenance tag set to True & ensure connections are set as not allowed
Write-Output "Checking virtual machine maintenance tags and updating drain modes..."
foreach ($sessionHost in $allSessionHosts) {

  $sessionHostName = $sessionHost.Name
  $sessionHostName = $sessionHostName.Split("/")[1]
  $vmName = $sessionHostName.Split(".")[0]
  $vmInfo = Get-AzVM | Where-Object { $_.Name -eq $VMName }

  if ($vmInfo.Tags.ContainsKey($maintenanceTagName) -and $vmInfo.Tags.ContainsValue($True)) {
    Write-Output "The host $vmName is in maintenance mode, so is not allowing any further connections"
    Update-AzWvdSessionHost -ResourceGroupName $resourceGroupName -HostPoolName $hostpoolName -Name $sessionHostName -AllowNewSession:$False -ErrorAction SilentlyContinue | Out-Null
  }
  else {
    Update-AzWvdSessionHost -ResourceGroupName $resourceGroupName -HostPoolName $hostpoolName -Name $sessionHostName -AllowNewSession:$True -ErrorAction SilentlyContinue | Out-Null
  }
}

# Check the Hostpool Load Balancer type and Maximum Sessions
$hostpoolInfo = Get-AzWvdHostPool -ResourceGroupName $resourceGroupName -Name $hostPoolName
$hostpoolMaxSessionLimit = $hostpoolInfo.MaxSessionLimit
Write-Output "Hostpool Load Balancing Type: $($hostpoolInfo.LoadBalancerType)"
Write-Output "Hostpool Maximum Session Limit per Host: $($hostpoolMaxSessionLimit)"

# Check if it's peak hours
if (($CurrentDateTime -ge $BeginPeakDateTime -and $CurrentDateTime -le $EndPeakDateTime) -and ($WorkDays -contains $today) -and (!$bankHoliday) -and (!$customHoliday)) {

  # Set Scalefactor for each host.										  
  $sessionHostLimit = $peakScaleFactor

  Write-Output "Checking current host availability and workloads..."

  # Get all session hosts in the host pool
  $allSessionHosts = Get-AzWvdSessionHost -ResourceGroupName $resourceGroupName -HostPoolName $HostpoolName | Sort-Object -Descending Session

  # Check the number of available running session hosts
  $numberOfRunningHost = 0
  foreach ($sessionHost in $allSessionHosts) {
    $sessionHostName = $sessionHost.Name
    $sessionHostName = $sessionHostName.Split("/")[1]
    $vmName = $sessionHostName.Split(".")[0]
    Write-Output "Host: $vmName, Current Sessions: $($sessionHost.Session), Status: $($sessionHost.Status), Allow New Sessions: $($sessionHost.AllowNewSession)"

    if ($sessionHost.Status -eq "Available" -and $sessionHost.AllowNewSession -eq $True) {
      $numberOfRunningHost = $numberOfRunningHost + 1
    }
  }
  Write-Output "Current number of available running hosts: $numberOfRunningHost"

  # Start more hosts if available host number is less than the specified Peak minimum number of hosts
  if ($numberOfRunningHost -lt $peakMinimumNumberOfRDSH) {
    Write-Output "Current number of available running hosts ($numberOfRunningHost) is less than the specified Peak minimum number of running hosts ($peakMinimumNumberOfRDSH) - Need to start additional hosts"

    $global:peakMinRDSHcapacityTrigger = $True

    :peakMinStartupLoop foreach ($sessionHost in $allSessionHosts) {

      if ($numberOfRunningHost -ge $peakMinimumNumberOfRDSH) {
        Write-Output "The number of available running hosts should soon equal the specified Peak minimum number of running hosts ($peakMinimumNumberOfRDSH)"
        break peakMinStartupLoop    
      }

      # Check the session hosts status to determine it's healthy before starting it
      if (($sessionHost.Status -eq "NoHeartbeat" -or $sessionHost.Status -eq "Unavailable") -and ($sessionHost.UpdateState -eq "Succeeded")) {
        $sessionHostName = $sessionHost.Name
        $sessionHostName = $sessionHostName.Split("/")[1]
        $vmName = $sessionHostName.Split(".")[0]
        $vmInfo = Get-AzVM | Where-Object { $_.Name -eq $vmName }
        $vmDisk = Get-AzDisk | Where-Object { $_.Name -eq $vmInfo.StorageProfile.OsDisk.Name }
        
        # Check to see if the Session host is in maintenance mode
        if ($vmInfo.Tags.ContainsKey($maintenanceTagName) -and $vmInfo.Tags.ContainsValue($True)) {
          Write-Output "Host $vmName is in maintenance mode, so this host will be skipped"
          continue
        }

        # Ensure the host has allow new connections set to True
        if ($sessionHost.AllowNewSession = $False) {
          try {
            Update-AzWvdSessionHost -ResourceGroupName $resourceGroupName -HostPoolName $hostPoolName -Name $sessionHostName -AllowNewSession:$True -ErrorAction SilentlyContinue | Out-Null
          }
          catch {
            Write-Error "Unable to set 'Allow New Sessions' to True on host $VMName with error: $($_.exception.message)"
            exit 1
          }
        }

        # Change the Azure VM disk tier before starting
        if ($vmDisk.Sku.Name -ne $vmDiskType) {
          try {
            $diskConfig = New-AzDiskUpdateConfig -SkuName $vmDiskType
            Update-AzDisk -ResourceGroupName $resourceGroupName -DiskName $vmDisk.Name -DiskUpdate $diskConfig | Out-Null
          }
          catch {
            Write-Error "Failed to change disk $vmDisk.Name tier to $vmDiskType with error: $($_.exception.message)"
            exit
          }
        }

        # Start the Azure VM in Fast-Scale Mode for parallel processing
        try {
          Write-Output "Starting host $vmName..."
          Start-AzVM -Name $vmName -ResourceGroupName $vmInfo.ResourceGroupName -AsJob | Out-Null

        }
        catch {
          Write-Error "Failed to start host $vmName with error: $($_.exception.message)"
          exit
        }
        
        $numberOfRunningHost = $numberOfRunningHost + 1
        $global:spareCapacity = $True
      }
    }
  }
  else {
    
    :mainLoop foreach ($sessionHost in $allSessionHosts) {

      # Check if a hosts sessions have exceeded the Peak scale factor
      if ($sessionHost.Session -ge $SessionHostLimit) {
        $sessionHostName = $SessionHost.Name
        $sessionHostName = $SessionHostName.Split("/")[1]
        $VMName = $SessionHostName.Split(".")[0]

        # Check if a hosts sessions have exceeded the Peak scale factor
        if (($global:exceededHostCapacity -eq $False -or !$global:exceededHostCapacity) -and ($global:capacityTrigger -eq $False -or !$global:capacityTrigger)) {
          Write-Output "One or more hosts have surpassed the Scale Factor of $SessionHostLimit. Checking other active host capacities now..."
          $global:capacityTrigger = $True
        }

        :startupLoop  foreach ($sessionHost in $allSessionHosts) {

          # Check the existing session hosts for spare capacity before starting another host
          if ($sessionHost.Status -eq "Available" -and $sessionHost.Session -lt $SessionHostLimit -and $SessionHost.AllowNewSession -eq $True) {
            $sessionHostName = $SessionHost.Name
            $sessionHostName = $SessionHostName.Split("/")[1]
            $VMName = $SessionHostName.Split(".")[0]

            if ($global:exceededHostCapacity -eq $False -or !$global:exceededHostCapacity) {
              Write-Output "Found spare capacity so don't need to start another host"
              $global:exceededHostCapacity = $True
              $global:spareCapacity = $True
            }
            break startupLoop
          }

          # Check the session hosts status to determine it's healthy before starting it
          if (($SessionHost.Status -eq "NoHeartbeat" -or $SessionHost.Status -eq "Unavailable") -and ($SessionHost.UpdateState -eq "Succeeded")) {
            $SessionHostName = $SessionHost.Name
            $SessionHostName = $SessionHostName.Split("/")[1]
            $VMName = $SessionHostName.Split(".")[0]
            $VmInfo = Get-AzVM | Where-Object { $_.Name -eq $VMName }
            $vmDisk = Get-AzDisk | Where-Object { $_.Name -eq $vmInfo.StorageProfile.OsDisk.Name }

            # Check to see if the Session host is in maintenance mode
            if ($VMInfo.Tags.ContainsKey($MaintenanceTagName) -and $VMInfo.Tags.ContainsValue($True)) {
              Write-Output "Host $VMName is in maintenance mode, so this host will be skipped"
              continue
            }

            # Ensure the host has allow new connections set to True
            if ($SessionHost.AllowNewSession = $False) {
              try {
                Update-AzWvdSessionHost -ResourceGroupName $resourceGroupName -HostPoolName $HostpoolName -Name $SessionHostName -AllowNewSession:$True -ErrorAction SilentlyContinue | Out-Null
              }
              catch {
                Write-Error "Unable to set 'Allow New Sessions' to True on host $VMName with error: $($_.exception.message)"
                exit 1
              }
            }

            # Change the Azure VM disk tier before starting
            if ($vmDisk.Sku.Name -ne $vmDiskType) {
              try {
                $diskConfig = New-AzDiskUpdateConfig -SkuName $vmDiskType
                Update-AzDisk -ResourceGroupName $resourceGroupName -DiskName $vmDisk.Name -DiskUpdate $diskConfig | Out-Null
              }
              catch {
                Write-Error "Failed to change disk $vmDisk.Name tier to $vmDiskType with error: $($_.exception.message)"
                exit
              }
            }

            # Start the Azure VM
            try {
              Write-Output "There is not enough spare capacity on other active hosts. A new host will now be started..."
              Write-Output "Starting host $VMName..."
              Start-AzVM -Name $VMName -ResourceGroupName $VMInfo.ResourceGroupName | Out-Null
            }
            catch {
              Write-Error "Failed to start host $VMName with error: $($_.exception.message)"
              exit
            }

            # Wait for the session host to become available
            $isHostAvailable = $false
            while (!$isHostAvailable) {

              $sessionHostStatus = Get-AzWvdSessionHost -ResourceGroupName $resourceGroupName -HostPoolName $hostPoolName -Name $sessionHostName

              if ($SessionHostStatus.Status -eq "Available") {
                $isHostAvailable = $true
              }
            }
            $numberOfRunningHost = $numberOfRunningHost + 1
            $global:spareCapacity = $True
            Write-Output "Current number of available running hosts is now: $numberOfRunningHost"
            break mainLoop

          }
        }
      }

      # Get sessions status of all available hosts. Build list of any hosts available to be shut down
      $allSessionHosts = Get-AzWvdSessionHost -ResourceGroupName $resourceGroupName -HostPoolName $HostpoolName
      $activeHostsZeroSessions = [System.Collections.ArrayList]@()
      $sessionlessHostList = $allSessionHosts | Where-Object { $_.Session -eq 0 -and $_.Status -eq "Available" -and $_.AllowNewSession -eq $True }
      $activeHostsWithSessions = $allSessionHosts | Where-Object { $_.Session -gt 0 -and $_.Status -eq "Available" -and $_.AllowNewSession -eq $True }
      $shutdownSpareCapacity = $false
      foreach ($sessionlessHost in $sessionlessHostList) {
        $activeHostsZeroSessions.Add($sessionlessHost) | Out-Null
      }

      # If any available hosts are running with 0 sessions, run the shutdown check sequence
      if ($activeHostsZeroSessions) {

        # Check if available hosts with sessions have spare capacity
        foreach ($activeHostWithSessions in $activeHostsWithSessions) {

          if ($activeHostWithSessions.Session -lt $sessionHostLimit) {
            $shutdownSpareCapacity = $true
          }
        }

        # If no host with existing sessions has spare capacity, remove a host from $activeHostsZeroSessions array list
        if ($shutdownSpareCapacity -eq $false) {
          $activeHostsZeroSessions.RemoveAt(0) 
        }
        
        foreach ($activeHost in $activeHostsZeroSessions) {
          
          # Ensure there is at least the peakMinimumNumberOfRDSH sessions available
          if ($numberOfRunningHost -le $peakMinimumNumberOfRDSH) {
            Write-Output "Found no available resource to save as the number of available running hosts = $numberOfRunningHost and the specified Peak minimum number of running hosts = $peakMinimumNumberOfRDSH"
            break mainLoop
          }

          # Check for session capacity on other active hosts before shutting the free host down
          else {

            $activeHostName = $activeHost.Name
            $activeHostName = $activeHostName.Split("/")[1]
            $vmName = $activeHostName.Split(".")[0]
            $vmInfo = Get-AzVM | Where-Object { $_.Name -eq $vmName }
            $vmDisk = Get-AzDisk | Where-Object { $_.Name -eq $vmInfo.StorageProfile.OsDisk.Name }

            # Check if the Session host is in maintenance
            if ($vmInfo.Tags.ContainsKey($MaintenanceTagName) -and $VMInfo.Tags.ContainsValue($True)) {
              Write-Output "Host $vmName is in maintenance mode, so this host will be skipped"
              continue
            }

            Write-Output "Identified free host $vmName with $($activeHost.Session) sessions that can be shut down to save resource"

            # Ensure the running Azure VM is set into drain mode
            try {
              Update-AzWvdSessionHost -ResourceGroupName $resourceGroupName -HostPoolName $HostpoolName -Name $ActiveHostName -AllowNewSession:$False -ErrorAction SilentlyContinue | Out-Null
            }
            catch {
              Write-Error "Unable to set 'Allow New Sessions' to False on host $VMName with error: $($_.exception.message)"
              exit
            }
            try {
              Write-Output "Stopping host $vmName..."
              Stop-AzVM -Name $vmName -ResourceGroupName $vmInfo.ResourceGroupName -Force | Out-Null
            }
            catch {
              Write-Error "Failed to stop host $VMName with error: $($_.exception.message)"
              exit
            }
            # Check if the session host server is healthy before enable allowing new connections
            if ($activeHost.UpdateState -eq "Succeeded") {
              # Ensure Azure VMs that are stopped have the allowing new connections state True
              try {
                Update-AzWvdSessionHost -ResourceGroupName $resourceGroupName -HostPoolName $HostpoolName -Name $ActiveHostName -AllowNewSession:$True -ErrorAction SilentlyContinue | Out-Null
              }
              catch {
                Write-Output "Unable to set 'Allow New Sessions' to True on host $VMName with error: $($_.exception.message)"
                exit
              }
            }

            # Wait after shutting down Host until it's Status returns as Unavailable
            $IsShutdownHostUnavailable = $false
            while (!$IsShutdownHostUnavailable) {

              $shutdownHost = Get-AzWvdSessionHost -ResourceGroupName $resourceGroupName -HostPoolName $HostpoolName -Name $ActiveHostName

              if ($shutdownHost.Status -eq "Unavailable") {
                $IsShutdownHostUnavailable = $true
              }
            }

            # Change the Azure VM disk tier after shutting down to save on costs
            if ($vmDisk.Sku.Name -ne 'Standard_LRS') {
              try {
                $diskConfig = New-AzDiskUpdateConfig -SkuName 'Standard_LRS'
                Update-AzDisk -ResourceGroupName $resourceGroupName -DiskName $vmDisk.Name -DiskUpdate $diskConfig | Out-Null
              }
              catch {
                Write-Error "Failed to change disk $vmDisk.Name tier to $vmDiskType with error: $($_.exception.message)"
                exit
              }
            }

            # Decrement the number of running session hosts
            $NumberOfRunningHost = $NumberOfRunningHost - 1
            Write-Output "Current number of available running hosts is now: $NumberOfRunningHost"
          }
        }
      }
    }     
  }
}  

else {

  # Set Scalefactor for each host.										  
  $SessionhostLimit = $offpeakScaleFactor

  Write-Output "Checking current host availability and workloads..."

  # Get all session hosts in the host pool
  $allSessionHosts = Get-AzWvdSessionHost -ResourceGroupName $resourceGroupName -HostPoolName $HostpoolName | Sort-Object -Descending Session
 
  # Check the number of available running session hosts
  $numberOfRunningHost = 0
  foreach ($SessionHost in $AllSessionHosts) {

    $SessionHostName = $SessionHost.Name
    $SessionHostName = $SessionHostName.Split("/")[1]
    $VMName = $SessionHostName.Split(".")[0]
    Write-Output "Host: $VMName, Current Sessions: $($SessionHost.Session), Status: $($SessionHost.Status), Allow New Sessions: $($SessionHost.AllowNewSession)"

    if ($SessionHost.Status -eq "Available" -and $SessionHost.AllowNewSession -eq $True) {
      $NumberOfRunningHost = $NumberOfRunningHost + 1
    }
  }
  Write-Output "Current number of available running hosts: $NumberOfRunningHost"

  # Check if it is within PeakToOffPeakTransitionTime after the end of Peak time and set the Peak to Off-Peak transition trigger if true
  $peakToOffPeakTransitionTrigger = $false

  if (($CurrentDateTime -ge $EndPeakDateTime) -and ($CurrentDateTime -le $peakToOffPeakTransitionTime)) {
    $peakToOffPeakTransitionTrigger = $True
  }

  # Check if user logoff is turned on in off peak
  if ($LimitSecondsToForceLogOffUser -ne 0 -and $peakToOffPeakTransitionTrigger -eq $True) {
    Write-Output "The hostpool has recently transitioned to Off-Peak from Peak and force logging-off of users in Off-Peak is enabled. Checking if any resource can be saved..."

    if ($NumberOfRunningHost -gt $offpeakMinimumNumberOfRDSH) {
      Write-Output "The number of available running hosts ($numberOfRunningHost) is greater than the Off-Peak Minimum Number of running hosts ($offpeakMinimumNumberOfRDSH). Logging-off procedure will now be started..."

      foreach ($SessionHost in $AllSessionHosts) {

        $SessionHostName = $SessionHost.Name
        $SessionHostName = $SessionHostName.Split("/")[1]
        $VMName = $SessionHostName.Split(".")[0]
        $VmInfo = Get-AzVM | Where-Object { $_.Name -eq $VMName }
        
        if ($SessionHost.Status -eq "Available") {

          # Get the User sessions in the hostPool
          try {
            $HostPoolUserSessions = Get-AzWvdUserSession -ResourceGroupName $resourceGroupName -HostPoolName $HostpoolName
          }
          catch {
            Write-Error "Failed to retrieve user sessions in hostpool $($HostpoolName) with error: $($_.exception.message)"
            exit
          }

          Write-Output "Current sessions running on host $VMName : $($SessionHost.Session)"
        }
      } 
      
      Write-Output "Sending log off message to users..."
      
      $HostPoolUserSessions = Get-AzWvdUserSession -ResourceGroupName $resourceGroupName -HostPoolName $HostpoolName
      $ExistingSession = 0
      foreach ($Session in $HostPoolUserSessions) {
  
        $SessionHostName = $Session.Name
        $SessionHostName = $SessionHostName.Split("/")[1]
        $SessionId = $Session.Id
        $SessionId = $SessionId.Split("/")[12]
        
        # Notify user to log off their session
        try {
          Send-AzWvdUserSessionMessage -ResourceGroupName $resourceGroupName -HostPoolName $HostpoolName -SessionHostName $SessionHostName -UserSessionId $SessionId -MessageTitle $LogOffMessageTitle -MessageBody "$($LogOffMessageBody) - You will logged off in $($LimitSecondsToForceLogOffUser) seconds" | Out-Null
        }
        catch {
          Write-Error "Failed to send message to user with error: $($_.exception.message)"
          exit
        }
        $ExistingSession = $ExistingSession + 1
      }
      # List User Session count
      Write-Output "Log off messages were sent to $ExistingSession user(s)"

      # Set all Available session hosts into drain mode to stop any more connections
      Write-Output "Setting all available hosts into Drain mode to stop any further connections whilst logging-off procedure is running"
      $forceLogoffSessionHosts = $allSessionHosts | Where-Object { $_.Status -eq "Available" }
      foreach ($SessionHost in $forceLogoffSessionHosts) {
        
        $SessionHostName = $SessionHost.Name
        $SessionHostName = $SessionHostName.Split("/")[1]
        $VMName = $SessionHostName.Split(".")[0]
        $VmInfo = Get-AzVM | Where-Object { $_.Name -eq $VMName }

        # Check to see if the Session host is in maintenance
        if ($VMInfo.Tags.ContainsKey($MaintenanceTagName) -and $VMInfo.Tags.ContainsValue($True)) {
          Write-Output "Host $VMName is in maintenance mode, so this host will be skipped"
          $NumberOfRunningHost = $NumberOfRunningHost - 1
          continue
        }
        try {
          Update-AzWvdSessionHost -ResourceGroupName $resourceGroupName -HostPoolName $HostpoolName -Name $SessionHostName -AllowNewSession:$False -ErrorAction SilentlyContinue | Out-Null
        }
        catch {
          Write-Error "Unable to set 'Allow New Sessions' to False on host $VMName with error: $($_.exception.message)"
          exit
        }
      }
            
      # Wait for n seconds to log off users
      Write-Output "Waiting for $LimitSecondsToForceLogOffUser seconds before logging off users..."
      Start-Sleep -Seconds $LimitSecondsToForceLogOffUser

      # Force Users to log off
      Write-Output "Forcing users to log off now..."

      try {
        $HostPoolUserSessions = Get-AzWvdUserSession -ResourceGroupName $resourceGroupName -HostPoolName $HostpoolName
      }
      catch {
        Write-Error "Failed to retrieve list of user sessions in hostpool $HostpoolName with error: $($_.exception.message)"
        exit
      }
      $ExistingSession = 0
      foreach ($Session in $HostPoolUserSessions) {

        $SessionHostName = $Session.Name
        $SessionHostName = $SessionHostName.Split("/")[1]
        $vmName = $SessionHostName.Split(".")[0]
        $SessionId = $Session.Id
        $SessionId = $SessionId.Split("/")[12]

        # Log off user
        try {
          Remove-AzWvdUserSession -ResourceGroupName $resourceGroupName -HostPoolName $HostpoolName -SessionHostName $SessionHostName -Id $SessionId | Out-Null
        }
        catch {
          Write-Error "Failed to log off user session $($Session.UserSessionid) on host $vmName with error: $($_.exception.message)"
          exit
        }
        $ExistingSession = $ExistingSession + 1
      }

      # List User Logoff count
      Write-Output "$ExistingSession user(s) were logged off"

      foreach ($SessionHost in $forceLogoffSessionHosts) {
        if ($NumberOfRunningHost -gt $offpeakMinimumNumberOfRDSH) {

          $SessionHostName = $SessionHost.Name
          $SessionHostName = $SessionHostName.Split("/")[1]
          $VMName = $SessionHostName.Split(".")[0]
          $VmInfo = Get-AzVM | Where-Object { $_.Name -eq $VMName }
          $vmDisk = Get-AzDisk | Where-Object { $_.Name -eq $vmInfo.StorageProfile.OsDisk.Name }

          # Wait for the drained sessions to update on the WVD service
          $HaveSessionsDrained = $false
          while (!$HaveSessionsDrained) {

            $SessionHostStatus = Get-AzWvdSessionHost -ResourceGroupName $resourceGroupName -HostPoolName $HostpoolName -SessionHostName $SessionHostName

            if ($SessionHostStatus.Session -eq 0) {
              $HaveSessionsDrained = $true
              Write-Output "Host $VMName now has 0 sessions"
            }
          }

          # Shutdown the Azure VM
          try {
            Write-Output "Stopping host $VMName..."
            Stop-AzVM -Name $VMName -ResourceGroupName $VmInfo.ResourceGroupName -Force
          }
          catch {
            Write-Error "Failed to stop host $VMName with error: $($_.exception.message)"
            exit
          }

          # Check if the session host is healthy before allowing new connections
          if ($SessionHost.UpdateState -eq "Succeeded") {
            # Ensure Azure VMs that are stopped have the allow new connections state set to True
            try {
              Update-AzWvdSessionHost -ResourceGroupName $resourceGroupName -HostPoolName $HostpoolName -Name $SessionHostName -AllowNewSession:$True -ErrorAction SilentlyContinue
            }
            catch {
              Write-Error "Unable to set 'Allow New Sessions' to True on host $VMName with error: $($_.exception.message)"
              exit 1
            }
          }

          # Wait after shutting down Host until it's Status returns as Unavailable
          $IsShutdownHostUnavailable = $false
          while (!$IsShutdownHostUnavailable) {

            $shutdownHost = Get-AzWvdSessionHost -ResourceGroupName $resourceGroupName -HostPoolName $HostpoolName -Name $SessionHostName

            if ($shutdownHost.Status -eq "Unavailable") {
              $IsShutdownHostUnavailable = $true
            }
          }

          # Change the Azure VM disk tier after shutting down to save on costs
          if ($vmDisk.Sku.Name -ne 'Standard_LRS') {
            try {
              $diskConfig = New-AzDiskUpdateConfig -SkuName 'Standard_LRS'
              Update-AzDisk -ResourceGroupName $resourceGroupName -DiskName $vmDisk.Name -DiskUpdate $diskConfig | Out-Null
            }
            catch {
              Write-Error "Failed to change disk $vmDisk.Name tier to $vmDiskType with error: $($_.exception.message)"
              exit
            }
          }
          # Decrement the number of running session host
          $NumberOfRunningHost = $NumberOfRunningHost - 1
        }
      }
    }
  }

  #Get Session Hosts again in case force Log Off users has changed their state
  $allSessionHosts = Get-AzWvdSessionHost -ResourceGroupName $resourceGroupName -HostPoolName $HostpoolName

  if ($NumberOfRunningHost -lt $offpeakMinimumNumberOfRDSH) {
    Write-Output "Current number of available running hosts ($NumberOfRunningHost) is less than the specified Off-Peak Minimum Number of running hosts ($offpeakMinimumNumberOfRDSH) - Need to start additional hosts"
    $global:offpeakMinRDSHcapacityTrigger = $True

    :offpeakMinStartupLoop foreach ($SessionHost in $AllSessionHosts) {

      if ($NumberOfRunningHost -ge $offpeakMinimumNumberOfRDSH) {
        Write-Output "The number of available running hosts should soon equal the specified Off-Peak Minimum Number of running hosts ($offpeakMinimumNumberOfRDSH)"
        break offpeakMinStartupLoop
      }

      # Check the session host status and if the session host is healthy before starting the host
      if (($SessionHost.Status -eq "NoHeartbeat" -or $SessionHost.Status -eq "Unavailable") -and ($SessionHost.UpdateState -eq "Succeeded")) {
        $SessionHostName = $SessionHost.Name
        $SessionHostName = $SessionHostName.Split("/")[1]
        $VMName = $SessionHostName.Split(".")[0]
        $VmInfo = Get-AzVM | Where-Object { $_.Name -eq $VMName }
        $vmDisk = Get-AzDisk | Where-Object { $_.Name -eq $vmInfo.StorageProfile.OsDisk.Name }

        # Check to see if the Session host is in maintenance
        if ($VMInfo.Tags.ContainsKey($MaintenanceTagName) -and $VMInfo.Tags.ContainsValue($True)) {
          Write-Output "Host $VMName is in maintenance mode, so this host will be skipped"
          continue
        }

        # Ensure Azure VMs that are stopped have the allowing new connections state set to True
        if ($SessionHost.AllowNewSession = $False) {
          try {
            Update-AzWvdSessionHost -ResourceGroupName $resourceGroupName -HostPoolName $HostpoolName -Name $SessionHostName -AllowNewSession:$True -ErrorAction SilentlyContinue | Out-Null
          }
          catch {
            Write-Error "Unable to set it to allow connections on host $VMName with error: $($_.exception.message)"
            exit 1
          }
        }
        
        # Change the Azure VM disk tier before starting
        if ($vmDisk.Sku.Name -ne $vmDiskType) {
          try {
            $diskConfig = New-AzDiskUpdateConfig -SkuName $vmDiskType
            Update-AzDisk -ResourceGroupName $resourceGroupName -DiskName $vmDisk.Name -DiskUpdate $diskConfig | Out-Null
          }
          catch {
            Write-Error "Failed to change disk $vmDisk.Name tier to $vmDiskType with error: $($_.exception.message)"
            exit
          }
        }

        # Start the Azure VM in Fast-Scale Mode for parallel processing
        try {
          Write-Output "Starting host $VMName..."
          Start-AzVM -Name $VMName -ResourceGroupName $VmInfo.ResourceGroupName -AsJob | Out-Null

        }
        catch {
          Write-Output "Failed to start host $VMName with error: $($_.exception.message)"
          exit
        }
        
        $NumberOfRunningHost = $NumberOfRunningHost + 1
        $global:spareCapacity = $True
      }
    }
  }
  else {
    
    :mainLoop foreach ($sessionHost in $allSessionHosts) {
  
      # Check if a hosts sessions have exceeded the Peak scale factor
      if ($sessionHost.Session -ge $SessionHostLimit) {
        $sessionHostName = $SessionHost.Name
        $sessionHostName = $SessionHostName.Split("/")[1]
        $VMName = $SessionHostName.Split(".")[0]
  
        # Check if a hosts sessions have exceeded the Peak scale factor
        if (($global:exceededHostCapacity -eq $False -or !$global:exceededHostCapacity) -and ($global:capacityTrigger -eq $False -or !$global:capacityTrigger)) {
          Write-Output "One or more hosts have surpassed the Scale Factor of $SessionHostLimit. Checking other active host capacities now..."
          $global:capacityTrigger = $True
        }
  
        :startupLoop  foreach ($sessionHost in $allSessionHosts) {
  
          # Check the existing session hosts for spare capacity before starting another host
          if ($sessionHost.Status -eq "Available" -and $sessionHost.Session -lt $SessionHostLimit -and $SessionHost.AllowNewSession -eq $True) {
            $sessionHostName = $SessionHost.Name
            $sessionHostName = $SessionHostName.Split("/")[1]
            $VMName = $SessionHostName.Split(".")[0]
  
            if ($global:exceededHostCapacity -eq $False -or !$global:exceededHostCapacity) {
              Write-Output "Found spare capacity so don't need to start another host"
              $global:exceededHostCapacity = $True
              $global:spareCapacity = $True
            }
            break startupLoop
          }
  
          # Check the session hosts status to determine it's healthy before starting it
          if (($SessionHost.Status -eq "NoHeartbeat" -or $SessionHost.Status -eq "Unavailable") -and ($SessionHost.UpdateState -eq "Succeeded")) {
            $SessionHostName = $SessionHost.Name
            $SessionHostName = $SessionHostName.Split("/")[1]
            $VMName = $SessionHostName.Split(".")[0]
            $VmInfo = Get-AzVM | Where-Object { $_.Name -eq $VMName }
            $vmDisk = Get-AzDisk | Where-Object { $_.Name -eq $vmInfo.StorageProfile.OsDisk.Name }
  
            # Check to see if the Session host is in maintenance mode
            if ($VMInfo.Tags.ContainsKey($MaintenanceTagName) -and $VMInfo.Tags.ContainsValue($True)) {
              Write-Output "Host $VMName is in maintenance mode, so this host will be skipped"
              continue
            }
  
            # Ensure the host has allow new connections set to True
            if ($SessionHost.AllowNewSession = $False) {
              try {
                Update-AzWvdSessionHost -ResourceGroupName $resourceGroupName -HostPoolName $HostpoolName -Name $SessionHostName -AllowNewSession:$True -ErrorAction SilentlyContinue | Out-Null
              }
              catch {
                Write-Error "Unable to set 'Allow New Sessions' to True on host $VMName with error: $($_.exception.message)"
                exit 1
              }
            }
  
            # Change the Azure VM disk tier before starting
            if ($vmDisk.Sku.Name -ne $vmDiskType) {
              try {
                $diskConfig = New-AzDiskUpdateConfig -SkuName $vmDiskType
                Update-AzDisk -ResourceGroupName $resourceGroupName -DiskName $vmDisk.Name -DiskUpdate $diskConfig | Out-Null
              }
              catch {
                Write-Error "Failed to change disk $vmDisk.Name tier to $vmDiskType with error: $($_.exception.message)"
                exit
              }
            }
  
            # Start the Azure VM
            try {
              Write-Output "There is not enough spare capacity on other active hosts. A new host will now be started..."
              Write-Output "Starting host $VMName..."
              Start-AzVM -Name $VMName -ResourceGroupName $VMInfo.ResourceGroupName | Out-Null
            }
            catch {
              Write-Error "Failed to start host $VMName with error: $($_.exception.message)"
              exit
            }
  
            # Wait for the session host to become available
            $isHostAvailable = $false
            while (!$isHostAvailable) {
  
              $sessionHostStatus = Get-AzWvdSessionHost -ResourceGroupName $resourceGroupName -HostPoolName $hostPoolName -Name $sessionHostName
  
              if ($SessionHostStatus.Status -eq "Available") {
                $isHostAvailable = $true
              }
            }
            $numberOfRunningHost = $numberOfRunningHost + 1
            $global:spareCapacity = $True
            Write-Output "Current number of available running hosts is now: $numberOfRunningHost"
            break mainLoop
  
          }
        }
      }
  
      # Get sessions status of all available hosts. Build list of any hosts available to be shut down
      $allSessionHosts = Get-AzWvdSessionHost -ResourceGroupName $resourceGroupName -HostPoolName $HostpoolName
      $activeHostsZeroSessions = [System.Collections.ArrayList]@()
      $sessionlessHostList = $allSessionHosts | Where-Object { $_.Session -eq 0 -and $_.Status -eq "Available" -and $_.AllowNewSession -eq $True }
      $activeHostsWithSessions = $allSessionHosts | Where-Object { $_.Session -gt 0 -and $_.Status -eq "Available" -and $_.AllowNewSession -eq $True }
      $shutdownSpareCapacity = $false
      foreach ($sessionlessHost in $sessionlessHostList) {
        $activeHostsZeroSessions.Add($sessionlessHost) | Out-Null
      }
  
      # If any available hosts are running with 0 sessions, run the shutdown check sequence
      if ($activeHostsZeroSessions) {
  
        # Check if available hosts with sessions have spare capacity      
        foreach ($activeHostWithSessions in $activeHostsWithSessions) {
  
          if ($activeHostWithSessions.Session -lt $sessionHostLimit) {
            $shutdownSpareCapacity = $true
          }
        }

        # Check if Off-Peak Minimum number of hosts is 0
        if ($offpeakMinimumNumberOfRDSH -eq 0) {
          # Check if this empty host is the last running host
          if ($allSessionHosts.Count -eq 0) {
            $shutdownSpareCapacity = $true
          }
        }

        # If no host with existing sessions has spare capacity, remove a host from $activeHostsZeroSessions array list
        if ($shutdownSpareCapacity -eq $false) {
          if ($offpeakMinimumNumberOfRDSH -ne 0) {
            $activeHostsZeroSessions.RemoveAt(0) 
          }
        }
          
        foreach ($activeHost in $activeHostsZeroSessions) {
            
          # Ensure there is at least the offpeakMinimumNumberOfRDSH sessions available
          if ($numberOfRunningHost -le $offpeakMinimumNumberOfRDSH) {
            Write-Output "Found no available resource to save as the number of available running hosts = $numberOfRunningHost and the specified Off-Peak minimum number of running hosts = $offpeakMinimumNumberOfRDSH"
            break mainLoop
          }
  
          # Check for session capacity on other active hosts before shutting the free host down
          else {
  
            $activeHostName = $activeHost.Name
            $activeHostName = $activeHostName.Split("/")[1]
            $vmName = $activeHostName.Split(".")[0]
            $vmInfo = Get-AzVM | Where-Object { $_.Name -eq $vmName }
            $vmDisk = Get-AzDisk | Where-Object { $_.Name -eq $vmInfo.StorageProfile.OsDisk.Name }
  
            # Check if the Session host is in maintenance
            if ($vmInfo.Tags.ContainsKey($MaintenanceTagName) -and $VMInfo.Tags.ContainsValue($True)) {
              Write-Output "Host $vmName is in maintenance mode, so this host will be skipped"
              continue
            }
  
            Write-Output "Identified free host $vmName with $($activeHost.Session) sessions that can be shut down to save resource"
  
            # Ensure the running Azure VM is set into drain mode
            try {
              Update-AzWvdSessionHost -ResourceGroupName $resourceGroupName -HostPoolName $HostpoolName -Name $ActiveHostName -AllowNewSession:$False -ErrorAction SilentlyContinue | Out-Null
            }
            catch {
              Write-Error "Unable to set 'Allow New Sessions' to False on host $VMName with error: $($_.exception.message)"
              exit
            }
            try {
              Write-Output "Stopping host $vmName..."
              Stop-AzVM -Name $vmName -ResourceGroupName $vmInfo.ResourceGroupName -Force | Out-Null
            }
            catch {
              Write-Error "Failed to stop host $VMName with error: $($_.exception.message)"
              exit
            }
            # Check if the session host server is healthy before enable allowing new connections
            if ($activeHost.UpdateState -eq "Succeeded") {
              # Ensure Azure VMs that are stopped have the allowing new connections state True
              try {
                Update-AzWvdSessionHost -ResourceGroupName $resourceGroupName -HostPoolName $HostpoolName -Name $ActiveHostName -AllowNewSession:$True -ErrorAction SilentlyContinue | Out-Null
              }
              catch {
                Write-Output "Unable to set 'Allow New Sessions' to True on host $VMName with error: $($_.exception.message)"
                exit
              }
            }
  
            # Wait after shutting down Host until it's Status returns as Unavailable
            $IsShutdownHostUnavailable = $false
            while (!$IsShutdownHostUnavailable) {
  
              $shutdownHost = Get-AzWvdSessionHost -ResourceGroupName $resourceGroupName -HostPoolName $HostpoolName -Name $ActiveHostName
  
              if ($shutdownHost.Status -eq "Unavailable") {
                $IsShutdownHostUnavailable = $true
              }
            }
  
            # Change the Azure VM disk tier after shutting down to save on costs
            if ($vmDisk.Sku.Name -ne 'Standard_LRS') {
              try {
                $diskConfig = New-AzDiskUpdateConfig -SkuName 'Standard_LRS'
                Update-AzDisk -ResourceGroupName $resourceGroupName -DiskName $vmDisk.Name -DiskUpdate $diskConfig | Out-Null
              }
              catch {
                Write-Error "Failed to change disk $vmDisk.Name tier to $vmDiskType with error: $($_.exception.message)"
                exit
              }
            }
  
            # Decrement the number of running session hosts
            $NumberOfRunningHost = $NumberOfRunningHost - 1
            Write-Output "Current number of available running hosts is now: $NumberOfRunningHost"
          }
        }
      }
    }     
  }
}

if (($global:spareCapacity -eq $False -or !$global:spareCapacity) -and ($global:capacityTrigger -eq $True)) { 
  Write-Warning "WARNING - All available running hosts have surpassed the Scale Factor of $SessionHostLimit and there are no additional hosts available to start"
}

if (($global:spareCapacity -eq $False -or !$global:spareCapacity) -and ($global:peakMinRDSHcapacityTrigger -eq $True)) { 
  Write-Warning "WARNING - Current number of available running hosts ($NumberOfRunningHost) is less than the specified Peak minimum number of running hosts ($peakMinimumNumberOfRDSH) but there are no additional hosts available to start"
}

if (($global:spareCapacity -eq $False -or !$global:spareCapacity) -and ($global:offpeakMinRDSHcapacityTrigger -eq $True)) { 
  Write-Warning "WARNING - Current number of available running hosts ($NumberOfRunningHost) is less than the specified Off-Peak minimum number of running hosts ($offpeakMinimumNumberOfRDSH) but there are no additional hosts available to start"
}

Write-Output "Waiting for any outstanding jobs to complete..."
Get-Job | Wait-Job -Timeout $jobTimeout | Out-Null

$timedoutJobs = Get-Job -State Running
$failedJobs = Get-Job -State Failed

foreach ($job in $timedoutJobs) {
  Write-Warning "Error - The job $($job.Name) timed out"
}

foreach ($job in $failedJobs) {
  Write-Error "Error - The job $($job.Name) failed"
}

Write-Output "All job checks completed"

# Get all user sessions
$currentUsers = Get-AzWvdUserSession -ResourceGroupName $resourceGroupName -HostPoolName $HostpoolName
$currentUserCount = $currentUsers.Count
$userDetail = $currentUsers | Select-Object UserPrincipalName, Name, SessionState | Sort-Object Name | Out-String


# Get number of running hosts regardless of Maintenance Mode
$RunningSessionHosts = Get-AzWvdSessionHost -ResourceGroupName $resourceGroupName -HostPoolName $HostpoolName
$NumberOfRunningSessionHost = 0
foreach ($RunningSessionHost in $RunningSessionHosts) {

  if ($RunningSessionHost.Status -eq "Available") {
    $NumberOfRunningSessionHost = $NumberOfRunningSessionHost + 1
  }
}

# Post data to Log Analytics
Write-Output "Posting data to Log Analytics"

$logMessage = @{ 
  hostPoolName_s                  = $HostpoolName;
  resourceGroupName_s             = $resourceGroupName;
  runningHosts_d                  = $NumberOfRunningSessionHost;
  availableRunningHosts_d         = $NumberOfRunningHost;
  userSessions_d                  = $currentUserCount;
  userDetail_s                    = $userDetail;
  workDays_s                      = $workDays;
  beginPeakTime_s                 = $beginPeakTime;
  endPeakTime_s                   = $endPeakTime;
  timeZone_s                      = $timeZone;
  peakLoadBalancingType_s         = $peakLoadBalancingType;
  offPeakLoadBalancingType_s      = $offPeakLoadBalancingType;
  peakMaxSessions_d               = $peakMaxSessions;
  offpeakMaxSessions_d            = $offPeakMaxSessions;
  peakScaleFactor_d               = $peakScaleFactor;
  offpeakScaleFactor_d            = $offpeakScaleFactor;
  peakMinimumNumberOfRDSH_d       = $peakMinimumNumberOfRDSH;
  offpeakMinimumNumberOfRDSH_d    = $offpeakMinimumNumberOfRDSH;
  limitSecondsToForceLogOffUser_d = $limitSecondsToForceLogOffUser
}
Add-LogEntry -LogMessageObj $logMessage -LogAnalyticsWorkspaceId $logAnalyticsWorkspaceId -LogAnalyticsPrimaryKey $logAnalyticsPrimaryKey -LogType $logName

Write-Output "-------------------- Ending script --------------------"
