<# 
.SYNOPSIS
    This script automates the powering on and off of session hosts within a WVD hostpool. 

.DESCRIPTION
    This script is designed to help organisations to both save compute costs for their WVD environment by ensuring only the required amount of resource is running at 
    the time and ensure that there are enough resources available to satisfy user density. The runbook is ran on a specified schedule, usually every 15 minutes, and 
    performs the following steps:
      1.	Receives all the parameters in from the scaling parameters file
      2.	Checks the current day and time against the specified ‘WorkDays’ and ‘Peak Start/End Times’
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
        c.	Shuts down the host if a & b both pass the test
      9.	Writes logs to Log Analytics

.NOTES
    Author  : Dave Pierson
    Version : 3.1.01

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

$aadTenantId = $Input.AADTenantId
$subscriptionID = $Input.SubscriptionID
$resourceGroupName = $Input.ResourceGroupName
$hostpoolName = $Input.HostPoolName
$workDays = $Input.WorkDays
$beginPeakTime = $Input.BeginPeakTime
$endPeakTime = $Input.EndPeakTime
$timeDifferenceInHours = $Input.TimeDifferenceInHours
$peakLoadBalancingType = $Input.PeakLoadBalancingType
$offPeakLoadBalancingType = $Input.OffPeakLoadBalancingType
$peakMaxSessions = $Input.PeakMaxSessions
$offpeakMaxSessions = $Input.OffPeakMaxSessions
$peakScaleFactor = $Input.PeakScaleFactor
$offpeakScaleFactor = $Input.OffpeakScaleFactor
$peakMinimumNumberOfRDSH = $Input.PeakMinimumNumberOfRDSH
$offpeakMinimumNumberOfRDSH = $Input.OffpeakMinimumNumberOfRDSH
$minimumNumberFastScale = $Input.MinimumNumberFastScale
$jobTimeout = $Input.JobTimeout
$limitSecondsToForceLogOffUser = $Input.LimitSecondsToForceLogOffUser
$logOffMessageTitle = $Input.LogOffMessageTitle
$logOffMessageBody = $Input.LogOffMessageBody
$maintenanceTagName = $Input.MaintenanceTagName
$logAnalyticsWorkspaceId = $Input.LogAnalyticsWorkspaceId
$logAnalyticsPrimaryKey = $Input.LogAnalyticsPrimaryKey
$connectionAssetName = $Input.ConnectionAssetName

Set-ExecutionPolicy -ExecutionPolicy Undefined -Scope Process -Force -Confirm:$false
Set-ExecutionPolicy -ExecutionPolicy Unrestricted -Scope LocalMachine -Force -Confirm:$false

# Setting ErrorActionPreference to stop script execution when error occurs
$ErrorActionPreference = "Stop"

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# Function for converting UTC to Local time
function Convert-UTCtoLocalTime {
  param(
    $timeDifferenceInHours
  )

  $universalTime = (Get-Date).ToUniversalTime()
  $timeDifferenceMinutes = 0
  if ($timeDifferenceInHours -match ":") {
    $timeDifferenceHours = $timeDifferenceInHours.Split(":")[0]
    $timeDifferenceMinutes = $timeDifferenceInHours.Split(":")[1]
  }
  else {
    $timeDifferenceHours = $timeDifferenceInHours
  }
  # Azure is using UTC time, justify it to the local time
  $convertedTime = $universalTime.AddHours($timeDifferenceHours).AddMinutes($timeDifferenceMinutes)
  return $convertedTime
}

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

# Construct Begin time and End time for the Peak/Off-Peak periods from UTC to local time
$timeDifference = [string]$timeDifferenceInHours
$currentDateTime = Convert-UTCtoLocalTime -TimeDifferenceInHours $timeDifference

# Collect the credentials from Azure Automation Account Assets
$connection = Get-AutomationConnection -Name $connectionAssetName

# Authenticate to Azure 
Clear-AzContext -Force
$azAuthentication = Connect-AzAccount -ApplicationId $connection.ApplicationId -TenantId $aadTenantId -CertificateThumbprint $connection.CertificateThumbprint -ServicePrincipal
if ($azAuthentication -eq $null) {
  Write-Error "Failed to authenticate to Azure using the Automation Account $($_.exception.message)"
  exit
} 
else {
  Write-Output "Successfully authenticated to Azure using the Automation Account"
}

# Set the Azure context with Subscription
$azContext = Set-AzContext -SubscriptionId $subscriptionID
if ($azContext -eq $null) {
  Write-Error "Subscription '$subscriptionID' does not exist. Ensure that you have entered the correct values"
  exit
} 
else {
  Write-Output "Set the Azure Context to the subscription named '$($azContext.Subscription.Name)' with Id '$($azContext.Subscription.Id)'"
}

# Convert Datetime format
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
if ($hostpoolInfo -eq $null) {
  Write-Error "Hostpoolname '$hostpoolName' does not exist. Ensure that you have entered the correct values"
  exit
}	

# Get todays day of week for comparing to Work Days
$today = (Get-Date).DayOfWeek

# Compare Work Days and Peak Hours, and set up appropriate load balancing type based on PeakLoadBalancingType & OffPeakLoadBalancingType
if (($currentDateTime -ge $beginPeakDateTime -and $currentDateTime -le $endPeakDateTime) -and ($workDays -contains $today)) {
  Write-Output "It is currently Peak hours"
  if ($hostpoolInfo.LoadBalancerType -ne $peakLoadBalancingType) {
    Write-Output "Changing Hostpool Load Balance Type to: $peakLoadBalancingType Load Balancing"

    if ($peakLoadBalancingType -eq "DepthFirst") {                
      Update-AzWvdHostPool -ResourceGroupName $resourceGroupName -Name $hostpoolName -LoadBalancerType 'DepthFirst' -MaxSessionLimit $hostpoolInfo.MaxSessionLimit | Out-Null
    }
    else {
      Update-AzWvdHostPool -ResourceGroupName $resourceGroupName -Name $hostpoolName -LoadBalancerType 'BreadthFirst' -MaxSessionLimit $hostpoolInfo.MaxSessionLimit | Out-Null
    }
  }
  # Compare MaxSessionLimit of hostpool to peakMaxSessions value and adjust if necessary
  if ($hostpoolInfo.MaxSessionLimit -ne $peakMaxSessions) {
    Write-Output "Changing Hostpool Peak MaxSessionLimit to: $peakMaxSessions"

    if ($peakLoadBalancingType -eq "DepthFirst") {
      Update-AzWvdHostPool -ResourceGroupName $resourceGroupName -Name $hostpoolName -LoadBalancerType 'DepthFirst' -MaxSessionLimit $peakMaxSessions | Out-Null
    }
    else {
      Update-AzWvdHostPool -ResourceGroupName $resourceGroupName -Name $hostpoolName -LoadBalancerType 'BreadthFirst' -MaxSessionLimit $peakMaxSessions | Out-Null
    }
  }
}
else {
  Write-Output "It is currently Off-Peak hours"
  if ($hostpoolInfo.LoadBalancerType -ne $offPeakLoadBalancingType) {
    Write-Output "Changing Hostpool Load Balance Type to: $offPeakLoadBalancingType Load Balancing"
        
    if ($offPeakLoadBalancingType -eq "DepthFirst") {                
      Update-AzWvdHostPool -ResourceGroupName $resourceGroupName -Name $hostpoolName -LoadBalancerType 'DepthFirst' -MaxSessionLimit $hostpoolInfo.MaxSessionLimit | Out-Null
    }
    else {
      Update-AzWvdHostPool -ResourceGroupName $resourceGroupName -Name $hostpoolName -LoadBalancerType 'BreadthFirst' -MaxSessionLimit $hostpoolInfo.MaxSessionLimit | Out-Null
    }
  }
  # Compare MaxSessionLimit of hostpool to offpeakMaxSessions value and adjust if necessary
  if ($hostpoolInfo.MaxSessionLimit -ne $offpeakMaxSessions) {
    Write-Output "Changing Hostpool Off-Peak MaxSessionLimit to: $offpeakMaxSessions"

    if ($peakLoadBalancingType -eq "DepthFirst") {
      Update-AzWvdHostPool -ResourceGroupName $resourceGroupName -Name $hostpoolName -LoadBalancerType 'DepthFirst' -MaxSessionLimit $offpeakMaxSessions | Out-Null
    }
    else {
      Update-AzWvdHostPool -ResourceGroupName $resourceGroupName -Name $hostpoolName -LoadBalancerType 'BreadthFirst' -MaxSessionLimit $offpeakMaxSessions | Out-Null
    }
  }
}

# Check for VM's with maintenance tag set to True & ensure connections are set as not allowed
Write-Output "Checking virtual machine maintenance tags and updating drain modes based on results"
$allSessionHosts = Get-AzWvdSessionHost -ResourceGroupName $resourceGroupName -HostPoolName $hostpoolName

foreach ($sessionHost in $allSessionHosts) {

  $sessionHostName = $sessionHost.Name
  $sessionHostName = $sessionHostName.Split("/")[1]
  $vmName = $sessionHostName.Split(".")[0]
  $vmInfo = Get-AzVM | Where-Object { $_.Name -eq $VMName }

  if ($vmInfo.Tags.ContainsKey($maintenanceTagName) -and $vmInfo.Tags.ContainsValue($True)) {
    Write-Output "The host $vmName is in Maintenance mode, so is not allowing any further connections"
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
if (($CurrentDateTime -ge $BeginPeakDateTime -and $CurrentDateTime -le $EndPeakDateTime) -and ($WorkDays -contains $today)) {

  # Calculate Scalefactor for each host.										  
  $ScaleFactorEachHost = $HostpoolMaxSessionLimit * $peakScaleFactor
  $SessionhostLimit = [math]::Floor($ScaleFactorEachHost)

  Write-Output "Checking current Host availability and workloads..."

  # Get all session hosts in the host pool
  $AllSessionHosts = Get-AzWvdSessionHost -ResourceGroupName $resourceGroupName -HostPoolName $HostpoolName | Sort-Object Status, Name
  if ($AllSessionHosts -eq $null) {
    Write-Error "No Session Hosts exist within the Hostpool '$HostpoolName'. Ensure that the Hostpool has hosts within it"
    exit
  }
  
  # Check the number of available running session hosts
  $NumberOfRunningHost = 0
  foreach ($SessionHost in $AllSessionHosts) {

    $SessionHostName = $SessionHost.Name
    $SessionHostName = $SessionHostName.Split("/")[1]
    $VMName = $SessionHostName.Split(".")[0]
    Write-Output "Host: $VMName, Current sessions: $($SessionHost.Session), Status: $($SessionHost.Status), Allow New Sessions: $($SessionHost.AllowNewSession)"

    if ($SessionHost.Status -eq "Available" -and $SessionHost.AllowNewSession -eq $True) {
      $NumberOfRunningHost = $NumberOfRunningHost + 1
    }
  }
  Write-Output "Current number of available running hosts: $NumberOfRunningHost"

  # Start more hosts if available host number is less than the specified Peak minimum number of hosts
  if ($NumberOfRunningHost -lt $peakMinimumNumberOfRDSH) {
    Write-Output "Current number of available running hosts ($NumberOfRunningHost) is less than the specified Peak Minimum Number of RDSH ($peakMinimumNumberOfRDSH) - Need to start additional hosts"

    $global:peakMinRDSHcapacityTrigger = $True

    :peakMinStartupLoop foreach ($SessionHost in $AllSessionHosts) {

      if ($NumberOfRunningHost -ge $peakMinimumNumberOfRDSH) {

        if ($minimumNumberFastScale -eq $True) {
          Write-Output "The number of available running hosts should soon equal the specified Peak Minimum Number of RDSH ($peakMinimumNumberOfRDSH)"
          break peakMinStartupLoop
        }
        else {
          Write-Output "The number of available running hosts ($NumberOfRunningHost) now equals the specified Peak Minimum Number of RDSH ($peakMinimumNumberOfRDSH)"
          break peakMinStartupLoop
        }
      }

      # Check the session hosts status to determine it's healthy before starting it
      if (($SessionHost.Status -eq "NoHeartbeat" -or $SessionHost.Status -eq "Unavailable") -and ($SessionHost.UpdateState -eq "Succeeded")) {
        $SessionHostName = $SessionHost.Name
        $SessionHostName = $SessionHostName.Split("/")[1]
        $VMName = $SessionHostName.Split(".")[0]
        $VmInfo = Get-AzVM | Where-Object { $_.Name -eq $VMName }

        # Check to see if the Session host is in maintenance mode
        if ($VMInfo.Tags.ContainsKey($MaintenanceTagName) -and $VMInfo.Tags.ContainsValue($True)) {
          Write-Output "Host $VMName is in Maintenance mode, so this host will be skipped"
          continue
        }

        # Ensure the host has allow new connections set to True
        if ($SessionHost.AllowNewSession = $False) {
          try {
            Update-AzWvdSessionHost -ResourceGroupName $resourceGroupName -HostPoolName $HostpoolName -Name $SessionHostName -AllowNewSession:$True -ErrorAction SilentlyContinue
          }
          catch {
            Write-Error "Unable to set 'Allow New Sessions' to True on host $VMName with error: $($_.exception.message)"
            exit 1
          }
        }
        if ($minimumNumberFastScale -eq $True) {

          # Start the Azure VM in Fast-Scale Mode for parallel processing
          try {
            Write-Output "Starting host $VMName in fast-scale mode..."
            Start-AzVM -Name $VMName -ResourceGroupName $VmInfo.ResourceGroupName -AsJob

          }
          catch {
            Write-Error "Failed to start host $VMName with error: $($_.exception.message)"
            exit
          }
        }
        if ($minimumNumberFastScale -eq $False) {

          # Start the Azure VM
          try {
            Write-Output "Starting host $VMName and waiting for it to complete..."
            Start-AzVM -Name $VMName -ResourceGroupName $VmInfo.ResourceGroupName

          }
          catch {
            Write-Error "Failed to start host $VMName with error: $($_.exception.message)"
            exit
          }
          # Wait for the session host to become available
          $IsHostAvailable = $false
          while (!$IsHostAvailable) {

            $SessionHostStatus = Get-AzWvdSessionHost -ResourceGroupName $resourceGroupName -HostPoolName $HostpoolName -Name $SessionHostName

            if ($SessionHostStatus.Status -eq "Available") {
              $IsHostAvailable = $true

            }
          }
        }
        $NumberOfRunningHost = $NumberOfRunningHost + 1
        $global:spareCapacity = $True
      }
    }
  }
  else {
    $AllSessionHosts = Get-AzWvdSessionHost -ResourceGroupName $resourceGroupName -HostPoolName $HostpoolName | Sort-Object Status, Name

    :mainLoop foreach ($SessionHost in $AllSessionHosts) {

      if ($SessionHost.Session -le $HostpoolMaxSessionLimit -or $SessionHost.Session -gt $HostpoolMaxSessionLimit) {
        if ($SessionHost.Session -ge $SessionHostLimit) {
          $SessionHostName = $SessionHost.Name
          $SessionHostName = $SessionHostName.Split("/")[1]
          $VMName = $SessionHostName.Split(".")[0]

          # Check if a hosts sessions have exceeded the Peak scale factor
          if (($global:exceededHostCapacity -eq $False -or !$global:exceededHostCapacity) -and ($global:capacityTrigger -eq $False -or !$global:capacityTrigger)) {
            Write-Output "One or more hosts have surpassed the Scale Factor of $SessionHostLimit. Checking other active host capacities now..."
            $global:capacityTrigger = $True
          }

          :startupLoop  foreach ($SessionHost in $AllSessionHosts) {

            # Check the existing session hosts spare capacity before starting another host
            if ($SessionHost.Status -eq "Available" -and ($SessionHost.Session -ge 0 -and $SessionHost.Session -lt $SessionHostLimit) -and $SessionHost.AllowNewSession -eq $True) {
              $SessionHostName = $SessionHost.Name
              $SessionHostName = $SessionHostName.Split("/")[1]
              $VMName = $SessionHostName.Split(".")[0]

              if ($global:exceededHostCapacity -eq $False -or !$global:exceededHostCapacity) {
                Write-Output "Host $VMName has spare capacity so don't need to start another host. Continuing now..."
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

              # Check to see if the Session host is in maintenance mode
              if ($VMInfo.Tags.ContainsKey($MaintenanceTagName) -and $VMInfo.Tags.ContainsValue($True)) {
                Write-Output "Host $VMName is in Maintenance mode, so this host will be skipped"
                continue
              }

              # Ensure the host has allow new connections set to True
              if ($SessionHost.AllowNewSession = $False) {
                try {
                  Update-AzWvdSessionHost -ResourceGroupName $resourceGroupName -HostPoolName $HostpoolName -Name $SessionHostName -AllowNewSession:$True -ErrorAction SilentlyContinue
                }
                catch {
                  Write-Error "Unable to set 'Allow New Sessions' to True on host $VMName with error: $($_.exception.message)"
                  exit 1
                }
              }

              # Start the Azure VM
              try {
                Write-Output "There is not enough spare capacity on other active hosts. A new host will now be started..."
                Write-Output "Starting host $VMName and waiting for it to complete..."
                Start-AzVM -Name $VMName -ResourceGroupName $VMInfo.ResourceGroupName
              }
              catch {
                Write-Error "Failed to start host $VMName with error: $($_.exception.message)"
                exit
              }

              # Wait for the session host to become available
              $IsHostAvailable = $false
              while (!$IsHostAvailable) {

                $SessionHostStatus = Get-AzWvdSessionHost -ResourceGroupName $resourceGroupName -HostPoolName $HostpoolName -Name $SessionHostName

                if ($SessionHostStatus.Status -eq "Available") {
                  $IsHostAvailable = $true
                }
              }
              $NumberOfRunningHost = $NumberOfRunningHost + 1
              $global:spareCapacity = $True
              Write-Output "Current number of Available Running Hosts is now: $NumberOfRunningHost"
              break mainLoop

            }
          }
        }
        # Shut down hosts utilizing unnecessary resource
        $ActiveHostsZeroSessions = Get-AzWvdSessionHost -ResourceGroupName $resourceGroupName -HostPoolName $HostpoolName | Where-Object { $_.Session -eq 0 -and $_.Status -eq "Available" -and $_.AllowNewSession -eq $True }
        $AllSessionHosts = Get-AzWvdSessionHost -ResourceGroupName $resourceGroupName -HostPoolName $HostpoolName | Sort-Object Status, Name
        :shutdownLoop foreach ($ActiveHost in $ActiveHostsZeroSessions) {
          
          $ActiveHostsZeroSessions = Get-AzWvdSessionHost -ResourceGroupName $resourceGroupName -HostPoolName $HostpoolName | Where-Object { $_.Session -eq 0 -and $_.Status -eq "Available" -and $_.AllowNewSession -eq $True }

          # Ensure there is at least the peakMinimumNumberOfRDSH sessions available
          if ($NumberOfRunningHost -le $peakMinimumNumberOfRDSH) {
            Write-Output "Found no available resource to save as the number of Available Running Hosts = $NumberOfRunningHost and the specified Peak Minimum Number of RDSH = $peakMinimumNumberOfRDSH"
            break mainLoop
          }

          # Check for session capacity on other active hosts before shutting the free host down
          else {
            $ActiveHostsZeroSessions = Get-AzWvdSessionHost -ResourceGroupName $resourceGroupName -HostPoolName $HostpoolName | Where-Object { $_.Session -eq 0 -and $_.Status -eq "Available" -and $_.AllowNewSession -eq $True }
            :shutdownLoopTier2 foreach ($ActiveHost in $ActiveHostsZeroSessions) {

              $AllSessionHosts = Get-AzWvdSessionHost -ResourceGroupName $resourceGroupName -HostPoolName $HostpoolName | Sort-Object Status, Name
              foreach ($SessionHost in $AllSessionHosts) {

                if ($SessionHost.Status -eq "Available" -and ($SessionHost.Session -ge 0 -and $SessionHost.Session -lt $SessionHostLimit -and $SessionHost.AllowNewSession -eq $True)) {
                  if ($SessionHost.Name -ne $ActiveHost.Name) {
                    $ActiveHostName = $ActiveHost.Name
                    $ActiveHostName = $ActiveHostName.Split("/")[1]
                    $VMName = $ActiveHostName.Split(".")[0]
                    $VmInfo = Get-AzVM | Where-Object { $_.Name -eq $VMName }

                    # Check if the Session host is in maintenance
                    if ($VMInfo.Tags.ContainsKey($MaintenanceTagName) -and $VMInfo.Tags.ContainsValue($True)) {
                      Write-Output "Host $VMName is in Maintenance mode, so this host will be skipped"
                      continue
                    }

                    Write-Output "Identified free host $VMName with $($ActiveHost.Session) sessions that can be shut down to save resource"

                    # Ensure the running Azure VM is set into drain mode
                    try {
                      Update-AzWvdSessionHost -ResourceGroupName $resourceGroupName -HostPoolName $HostpoolName -Name $ActiveHostName -AllowNewSession:$False -ErrorAction SilentlyContinue
                    }
                    catch {
                      Write-Error "Unable to set 'Allow New Sessions' to False on host $VMName with error: $($_.exception.message)"
                      exit
                    }
                    try {
                      Write-Output "Stopping host $VMName and waiting for it to complete..."
                      Stop-AzVM -Name $VMName -ResourceGroupName $VmInfo.ResourceGroupName -Force
                    }
                    catch {
                      Write-Error "Failed to stop host $VMName with error: $($_.exception.message)"
                      exit
                    }
                    # Check if the session host server is healthy before enable allowing new connections
                    if ($ActiveHost.UpdateState -eq "Succeeded") {
                      # Ensure Azure VMs that are stopped have the allowing new connections state True
                      try {
                        Update-AzWvdSessionHost -ResourceGroupName $resourceGroupName -HostPoolName $HostpoolName -Name $ActiveHostName -AllowNewSession:$True -ErrorAction SilentlyContinue
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

                    # Decrement the number of running session hosts
                    $NumberOfRunningHost = $NumberOfRunningHost - 1
                    Write-Output "Current number of Available Running Hosts is now: $NumberOfRunningHost"

                    break shutdownLoop
                  }
                }
              }     
            }
          }  
        }
      }
    }
  }
}
else {

  # Calculate Scalefactor for each host.										  
  $ScaleFactorEachHost = $HostpoolMaxSessionLimit * $offpeakScaleFactor
  $SessionhostLimit = [math]::Floor($ScaleFactorEachHost)

  Write-Output "Checking current Host availability and workloads..."

  # Get all session hosts in the host pool
  $AllSessionHosts = Get-AzWvdSessionHost -ResourceGroupName $resourceGroupName -HostPoolName $HostpoolName | Sort-Object Status, Name
  if ($AllSessionHosts -eq $null) {
    Write-Error "No Session Hosts exist within the Hostpool '$HostpoolName'. Ensure that the Hostpool has hosts within it"
    exit
  }

  # Check the number of running session hosts
  $NumberOfRunningHost = 0
  foreach ($SessionHost in $AllSessionHosts) {

    $SessionHostName = $SessionHost.Name
    $SessionHostName = $SessionHostName.Split("/")[1]
    $VMName = $SessionHostName.Split(".")[0]
    Write-Output "Host:$VMName, Current sessions:$($SessionHost.Session), Status:$($SessionHost.Status), Allow New Sessions:$($SessionHost.AllowNewSession)"

    if ($SessionHost.Status -eq "Available" -and $SessionHost.AllowNewSession -eq $True) {
      $NumberOfRunningHost = $NumberOfRunningHost + 1
    }
  }
  Write-Output "Current number of Available Running Hosts: $NumberOfRunningHost"

  # Check if it is within PeakToOffPeakTransitionTime after the end of Peak time and set the Peak to Off-Peak transition trigger if true
  $peakToOffPeakTransitionTrigger = $false

  if (($CurrentDateTime -ge $EndPeakDateTime) -and ($CurrentDateTime -le $peakToOffPeakTransitionTime)) {
    $peakToOffPeakTransitionTrigger = $True
  }

  # Check if user logoff is turned on in off peak
  if ($LimitSecondsToForceLogOffUser -ne 0 -and $peakToOffPeakTransitionTrigger -eq $True) {
    Write-Output "The Hostpool has recently transitioned to Off-Peak from Peak and force logging-off of users in Off-Peak is enabled. Checking if any resource can be saved..."

    if ($NumberOfRunningHost -gt $offpeakMinimumNumberOfRDSH) {
      Write-Output "The number of available running hosts is greater than the Off-Peak Minimum Number of RDSH. Logging-off procedure will now be started..."

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
            Write-Error "Failed to retrieve user sessions in hostPool $($HostpoolName) with error: $($_.exception.message)"
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
          Send-AzWvdUserSessionMessage -ResourceGroupName $resourceGroupName -HostPoolName $HostpoolName -SessionHostName $SessionHostName -UserSessionId $SessionId -MessageTitle $LogOffMessageTitle -MessageBody "$($LogOffMessageBody) - You will logged off in $($LimitSecondsToForceLogOffUser) seconds"
        }
        catch {
          Write-Error "Failed to send message to user with error: $($_.exception.message)"
          exit
        }
        $ExistingSession = $ExistingSession + 1
      }
      # List User Session count
      Write-Output "Logoff messages were sent to $ExistingSession user(s)"

      # Set all Available session hosts into drain mode to stop any more connections
      Write-Output "Setting all available hosts into Drain mode to stop any further connections whilst logging-off procedure is running..."
      $forceLogoffSessionHosts = Get-AzWvdSessionHost -ResourceGroupName $resourceGroupName -HostPoolName $HostpoolName | Where-Object { $_.Status -eq "Available" }
      foreach ($SessionHost in $forceLogoffSessionHosts) {
        
        $SessionHostName = $SessionHost.Name
        $SessionHostName = $SessionHostName.Split("/")[1]
        $VMName = $SessionHostName.Split(".")[0]
        $VmInfo = Get-AzVM | Where-Object { $_.Name -eq $VMName }

        # Check to see if the Session host is in maintenance
        if ($VMInfo.Tags.ContainsKey($MaintenanceTagName) -and $VMInfo.Tags.ContainsValue($True)) {
          Write-Output "Host $VMName is in Maintenance mode, so this host will be skipped"
          $NumberOfRunningHost = $NumberOfRunningHost - 1
          continue
        }
        try {
          Update-AzWvdSessionHost -ResourceGroupName $resourceGroupName -HostPoolName $HostpoolName -Name $SessionHostName -AllowNewSession:$False -ErrorAction SilentlyContinue
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
        Write-Error "Failed to retrieve list of user sessions in HostPool $HostpoolName with error: $($_.exception.message)"
        exit
      }
      $ExistingSession = 0
      foreach ($Session in $HostPoolUserSessions) {

        $SessionHostName = $Session.Name
        $SessionHostName = $SessionHostName.Split("/")[1]
        $SessionId = $Session.Id
        $SessionId = $SessionId.Split("/")[12]

        # Log off user
        try {
          Remove-AzWvdUserSession -ResourceGroupName $resourceGroupName -HostPoolName $HostpoolName -SessionHostName $SessionHostName -Id $SessionId
        }
        catch {
          Write-Error "Failed to log off user session $($Session.UserSessionid) on host $SessionHostName with error: $($_.exception.message)"
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
            Write-Output "Stopping host $VMName and waiting for it to complete..."
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
          # Decrement the number of running session host
          $NumberOfRunningHost = $NumberOfRunningHost - 1
        }
      }
    }
  }

  #Get Session Hosts again in case force Log Off users has changed their state
  $AllSessionHosts = Get-AzWvdSessionHost -ResourceGroupName $resourceGroupName -HostPoolName $HostpoolName | Sort-Object Status, Name

  if ($NumberOfRunningHost -lt $offpeakMinimumNumberOfRDSH) {
    Write-Output "Current number of available running hosts ($NumberOfRunningHost) is less than the specified Off-Peak Minimum Number of RDSH ($offpeakMinimumNumberOfRDSH) - Need to start additional hosts"
    $global:offpeakMinRDSHcapacityTrigger = $True

    :offpeakMinStartupLoop foreach ($SessionHost in $AllSessionHosts) {

      if ($NumberOfRunningHost -ge $offpeakMinimumNumberOfRDSH) {

        if ($minimumNumberFastScale -eq $True) {
          Write-Output "The number of available running hosts should soon equal the specified Off-Peak Minimum Number of RDSH ($offpeakMinimumNumberOfRDSH)"
          break offpeakMinStartupLoop
        }
        else {
          Write-Output "The number of available running hosts ($NumberOfRunningHost) now equals the specified Off-Peak Minimum Number of RDSH ($offpeakMinimumNumberOfRDSH)"
          break offpeakMinStartupLoop
        }
      }

      # Check the session host status and if the session host is healthy before starting the host
      if (($SessionHost.Status -eq "NoHeartbeat" -or $SessionHost.Status -eq "Unavailable") -and ($SessionHost.UpdateState -eq "Succeeded")) {
        $SessionHostName = $SessionHost.Name
        $SessionHostName = $SessionHostName.Split("/")[1]
        $VMName = $SessionHostName.Split(".")[0]
        $VmInfo = Get-AzVM | Where-Object { $_.Name -eq $VMName }

        # Check to see if the Session host is in maintenance
        if ($VMInfo.Tags.ContainsKey($MaintenanceTagName) -and $VMInfo.Tags.ContainsValue($True)) {
          Write-Output "Host $VMName is in Maintenance mode, so this host will be skipped"
          continue
        }

        # Ensure Azure VMs that are stopped have the allowing new connections state set to True
        if ($SessionHost.AllowNewSession = $False) {
          try {
            Update-AzWvdSessionHost -ResourceGroupName $resourceGroupName -HostPoolName $HostpoolName -Name $SessionHostName -AllowNewSession:$True -ErrorAction SilentlyContinue
          }
          catch {
            Write-Error "Unable to set it to allow connections on host $VMName with error: $($_.exception.message)"
            exit 1
          }
        }
        if ($minimumNumberFastScale -eq $True) {

          # Start the Azure VM in Fast-Scale Mode for parallel processing
          try {
            Write-Output "Starting host $VMName in fast-scale mode..."
            Start-AzVM -Name $VMName -ResourceGroupName $VmInfo.ResourceGroupName -AsJob

          }
          catch {
            Write-Output "Failed to start host $VMName with error: $($_.exception.message)"
            exit
          }
        }
        if ($minimumNumberFastScale -eq $False) {

          # Start the Azure VM
          try {
            Write-Output "Starting host $VMName and waiting for it to complete..."
            Start-AzVM -Name $VMName -ResourceGroupName $VmInfo.ResourceGroupName

          }
          catch {
            Write-Error "Failed to start host $VMName with error: $($_.exception.message)"
            exit
          }
          # Wait for the sessionhost to become available
          $IsHostAvailable = $false
          while (!$IsHostAvailable) {

            $SessionHostStatus = Get-AzWvdSessionHost -ResourceGroupName $resourceGroupName -HostPoolName $HostpoolName -Name $SessionHostName

            if ($SessionHostStatus.Status -eq "Available") {
              $IsHostAvailable = $true

            }
          }
        }
        $NumberOfRunningHost = $NumberOfRunningHost + 1
        $global:spareCapacity = $True
      }
    }
  }
  else {
    $AllSessionHosts = Get-AzWvdSessionHost -ResourceGroupName $resourceGroupName -HostPoolName $HostpoolName | Sort-Object Status, Name

    :mainLoop foreach ($SessionHost in $AllSessionHosts) {

      if ($SessionHost.Session -le $HostpoolMaxSessionLimit -or $SessionHost.Session -gt $HostpoolMaxSessionLimit) {
        if ($SessionHost.Session -ge $SessionHostLimit) {
          $SessionHostName = $SessionHost.Name
          $SessionHostName = $SessionHostName.Split("/")[1]
          $VMName = $SessionHostName.Split(".")[0]

          if (($global:exceededHostCapacity -eq $False -or !$global:exceededHostCapacity) -and ($global:capacityTrigger -eq $False -or !$global:capacityTrigger)) {
            Write-Output "One or more hosts have surpassed the Scale Factor of $SessionHostLimit. Checking other active host capacities now..."
            $global:capacityTrigger = $True
          }

          :startupLoop  foreach ($SessionHost in $AllSessionHosts) {
            # Check the existing session hosts and session availability before starting another session host
            if ($SessionHost.Status -eq "Available" -and ($SessionHost.Session -ge 0 -and $SessionHost.Session -lt $SessionHostLimit) -and $SessionHost.AllowNewSession -eq $True) {
              $SessionHostName = $SessionHost.Name
              $SessionHostName = $SessionHostName.Split("/")[1]
              $VMName = $SessionHostName.Split(".")[0]

              if ($global:exceededHostCapacity -eq $False -or !$global:exceededHostCapacity) {
                Write-Output "Host $VMName has spare capacity so don't need to start another host. Continuing now..."

                $global:exceededHostCapacity = $True
                $global:spareCapacity = $True
              }
              break startupLoop
            }

            # Check the session host status and if the session host is healthy before starting the host
            if (($SessionHost.Status -eq "NoHeartbeat" -or $SessionHost.Status -eq "Unavailable") -and ($SessionHost.UpdateState -eq "Succeeded")) {
              $SessionHostName = $SessionHost.Name
              $SessionHostName = $SessionHostName.Split("/")[1]
              $VMName = $SessionHostName.Split(".")[0]
              $VmInfo = Get-AzVM | Where-Object { $_.Name -eq $VMName }

              # Check if the session host is in maintenance
              if ($VMInfo.Tags.ContainsKey($MaintenanceTagName) -and $VMInfo.Tags.ContainsValue($True)) {
                Write-Output "Host $VMName is in Maintenance mode, so this host will be skipped"
                continue
              }

              # Ensure Azure VMs that are stopped have the allowing new connections state set to True
              if ($SessionHost.AllowNewSession = $False) {
                try {
                  Update-AzWvdSessionHost -ResourceGroupName $resourceGroupName -HostPoolName $HostpoolName -Name $SessionHostName -AllowNewSession:$True -ErrorAction SilentlyContinue
                }
                catch {
                  Write-Error "Unable to set 'Allow New Sessions' to True on Host $VMName with error: $($_.exception.message)"
                  exit 1
                }
              }

              # Start the Azure VM
              try {
                Write-Output "There is not enough spare capacity on other active hosts. A new host will now be started..."
                Write-Output "Starting host $VMName and waiting for it to complete..."
                Start-AzVM -Name $VMName -ResourceGroupName $VMInfo.ResourceGroupName
              }
              catch {
                Write-Error "Failed to start host $VMName with error: $($_.exception.message)"
                exit
              }
              # Wait for the sessionhost to become available
              $IsHostAvailable = $false
              while (!$IsHostAvailable) {

                $SessionHostStatus = Get-AzWvdSessionHost -ResourceGroupName $resourceGroupName -HostPoolName $HostpoolName -Name $SessionHostName

                if ($SessionHostStatus.Status -eq "Available") {
                  $IsHostAvailable = $true
                }
              }
              $NumberOfRunningHost = $NumberOfRunningHost + 1
              $global:spareCapacity = $True
              Write-Output "Current number of Available Running Hosts is now: $NumberOfRunningHost"
              break mainLoop
            }
          }
        }
        # Shut down hosts utilizing unnecessary resource
        $ActiveHostsZeroSessions = Get-AzWvdSessionHost -ResourceGroupName $resourceGroupName -HostPoolName $HostpoolName | Where-Object { $_.Session -eq 0 -and $_.Status -eq "Available" -and $_.AllowNewSession -eq $True }
        $AllSessionHosts = Get-AzWvdSessionHost -ResourceGroupName $resourceGroupName -HostPoolName $HostpoolName | Sort-Object Status, Name
        :shutdownLoop foreach ($ActiveHost in $ActiveHostsZeroSessions) {
          
          $ActiveHostsZeroSessions = Get-AzWvdSessionHost -ResourceGroupName $resourceGroupName -HostPoolName $HostpoolName | Where-Object { $_.Session -eq 0 -and $_.Status -eq "Available" -and $_.AllowNewSession -eq $True }

          # Ensure there is at least the offpeakMinimumNumberOfRDSH sessions available
          if ($NumberOfRunningHost -le $offpeakMinimumNumberOfRDSH) {
            Write-Output "Found no available resource to save as the number of Available Running Hosts = $NumberOfRunningHost and the specified Off-Peak Minimum Number of Hosts = $offpeakMinimumNumberOfRDSH"
            break mainLoop
          }

          # Check for session capacity on other active hosts before shutting the free host down
          else {
            $ActiveHostsZeroSessions = Get-AzWvdSessionHost -ResourceGroupName $resourceGroupName -HostPoolName $HostpoolName | Where-Object { $_.Session -eq 0 -and $_.Status -eq "Available" -and $_.AllowNewSession -eq $True }
            :shutdownLoopTier2 foreach ($ActiveHost in $ActiveHostsZeroSessions) {
              $AllSessionHosts = Get-AzWvdSessionHost -ResourceGroupName $resourceGroupName -HostPoolName $HostpoolName | Sort-Object Status, Name
              foreach ($SessionHost in $AllSessionHosts) {
                if ($SessionHost.Status -eq "Available" -and ($SessionHost.Session -ge 0 -and $SessionHost.Session -lt $SessionHostLimit -and $SessionHost.AllowNewSession -eq $True)) {
                  if ($SessionHost.Name -ne $ActiveHost.Name) {
                    $ActiveHostName = $ActiveHost.Name
                    $ActiveHostName = $ActiveHostName.Split("/")[1]
                    $VMName = $ActiveHostName.Split(".")[0]
                    $VmInfo = Get-AzVM | Where-Object { $_.Name -eq $VMName }

                    # Check if the Session host is in maintenance
                    if ($VMInfo.Tags.ContainsKey($MaintenanceTagName) -and $VMInfo.Tags.ContainsValue($True)) {
                      Write-Output "Host $VMName is in Maintenance mode, so this host will be skipped"
                      continue
                    }

                    Write-Output "Identified free Host $VMName with $($ActiveHost.Session) sessions that can be shut down to save resource"

                    # Ensure the running Azure VM is set as drain mode
                    try {
                      Update-AzWvdSessionHost -ResourceGroupName $resourceGroupName -HostPoolName $HostpoolName -Name $ActiveHostName -AllowNewSession:$False -ErrorAction SilentlyContinue
                    }
                    catch {
                      Write-Error "Unable to set 'Allow New Sessions' to False on Host $VMName with error: $($_.exception.message)"
                      exit
                    }
                    try {
                      Write-Output "Stopping host $VMName and waiting for it to complete ..."
                      Stop-AzVM -Name $VMName -ResourceGroupName $VmInfo.ResourceGroupName -Force
                    }
                    catch {
                      Write-Error "Failed to stop host $VMName with error: $($_.exception.message)"
                      exit
                    }
                    # Check if the session host server is healthy before enable allowing new connections
                    if ($SessionHost.UpdateState -eq "Succeeded") {
                      # Ensure Azure VMs that are stopped have the allowing new connections state True
                      try {
                        Update-AzWvdSessionHost -ResourceGroupName $resourceGroupName -HostPoolName $HostpoolName -Name $ActiveHostName -AllowNewSession:$True -ErrorAction SilentlyContinue
                      }
                      catch {
                        Write-Error "Unable to set 'Allow New Sessions' to True on Host $VMName with error: $($_.exception.message)"
                        exit
                      }
                    }
                    # Wait after shutting down ActiveHost until it's Status returns as Unavailable
                    $IsShutdownHostUnavailable = $false
                    while (!$IsShutdownHostUnavailable) {

                      $shutdownHost = Get-AzWvdSessionHost -ResourceGroupName $resourceGroupName -HostPoolName $HostpoolName -Name $ActiveHostName

                      if ($shutdownHost.Status -eq "Unavailable") {
                        $IsShutdownHostUnavailable = $true
                      }
                    }
                    # Decrement the number of running session host
                    $NumberOfRunningHost = $NumberOfRunningHost - 1
                    Write-Output "Current Number of Available Running Hosts is now: $NumberOfRunningHost"
                    break shutdownLoop
                  }
                }
              }     
            }
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
  Write-Warning "WARNING - Current number of available running hosts ($NumberOfRunningHost) is less than the specified Peak Minimum Number of RDSH ($peakMinimumNumberOfRDSH) but there are no additional hosts available to start"
}

if (($global:spareCapacity -eq $False -or !$global:spareCapacity) -and ($global:offpeakMinRDSHcapacityTrigger -eq $True)) { 
  Write-Warning "WARNING - Current number of available running hosts ($NumberOfRunningHost) is less than the specified Off-Peak Minimum Number of RDSH ($offpeakMinimumNumberOfRDSH) but there are no additional hosts available to start"
}

Write-Output "Waiting for any outstanding jobs to complete..."
Get-Job | Wait-Job -Timeout $jobTimeout

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
$CurrentActiveUsers = Get-AzWvdUserSession -ResourceGroupName $resourceGroupName -HostPoolName $HostpoolName | Select-Object UserPrincipalName, Name, SessionState | Sort-Object Name | Out-String

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
  hostpoolName_s = $HostpoolName;
  runningHosts_d = $NumberOfRunningSessionHost;
  availableRunningHosts_d = $NumberOfRunningHost;
  userSessions_s = "$CurrentActiveUsers"
}
Add-LogEntry -LogMessageObj $logMessage -LogAnalyticsWorkspaceId $logAnalyticsWorkspaceId -LogAnalyticsPrimaryKey $logAnalyticsPrimaryKey -LogType "WVDScalingTest_CL"

Write-Output "-------------------- Ending script --------------------"
