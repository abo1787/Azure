<# 
.SYNOPSIS
    This script automates the removal of old AVD hosts 

.DESCRIPTION
    This script is designed to automate the process of removing old hosts from an AVD host pool.
    It is designed to work alongside the 'automation_AVDUpdateHostPool.ps1' runbook.

.NOTES
    Author  : Dave Pierson
    Version : 1.1.0

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

#region Parameters
Param(

   [Parameter(mandatory)]
   [string]$keyVaultName,

   [int]$secondsToForceLogOffUser = 300

)
#endregion

#region Pre-Reqs
Set-ExecutionPolicy -ExecutionPolicy Undefined -Scope Process -Force -Confirm:$false
Set-ExecutionPolicy -ExecutionPolicy Unrestricted -Scope LocalMachine -Force -Confirm:$false

# Setting ErrorActionPreference to stop script execution when error occurs
$ErrorActionPreference = "Stop"

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
#endregion

#region Authenticate
$azAuthentication = Connect-AzAccount -Identity
if (!$azAuthentication) {
   Write-Error "Failed to authenticate to Azure using the Automation Account Managed Identity $($_.exception.message)"
   exit
} 
else {
   Write-Output "Successfully authenticated to Azure using the Automation Account"
}
#endregion

#region Get Values
$domainJoinPlain = Get-AzKeyVaultSecret -VaultName $keyVaultName -Name 'avd-domain-join' -AsPlainText
$domainPass = ConvertTo-SecureString -String $domainJoinPlain -AsPlainText -Force
$removalTagName = "RemovalDate"
$today = Get-Date -Format yyyy-MM-dd
#endregion

#region Get Hosts to Remove
# Get all VMs
$allVMs = Get-AzVM
$hostsToRemove = @()
foreach ($vm in $allVMs) {
   $tagTable = New-Object PSObject
   $vm.Tags.GetEnumerator() | ForEach-Object { Add-Member -InputObject $tagTable -MemberType NoteProperty -Name $_.Key -Value $_.Value }

   # Add any VMs with the Removal Tag and todays date into array
   if ($tagTable.$removalTagName -eq $today) {
      Write-Output "The host '$($vm.Name)' has it's removal date listed as today. This host will be removed"
      $hostsToRemove += $vm
   }
}
if (!$hostsToRemove) {
   Write-Output "There are no eligible hosts to be removed"
   exit
}
#endregion

#region Drain Hosts and Remove Sessions
# Ensure hosts to remove are in drain mode and have VMMaintenance tag set to True
$userSessionsToRemove = @()
foreach ($hostToRemove in $hostsToRemove) {
   $hostpool = Get-AzWvdHostPool -ResourceGroupName $hostToRemove.ResourceGroupName
   $sessionHost = Get-AzWvdSessionHost -ResourceGroupName $hostToRemove.ResourceGroupName -HostPoolName $hostpool.Name | Where-Object { $_.Name -like "*$($hostToRemove.Name)*" }
   $sessionHostName = $sessionHost.Name
   $sessionHostName = $sessionHostName.Split("/")[1]
   $userSessions = Get-AzWvdUserSession -ResourceGroupName $hostToRemove.ResourceGroupName -HostPoolName $hostpool.Name -SessionHostName $sessionHostName
   $userSessionsToRemove += $userSessions
   Update-AzWvdSessionHost -ResourceGroupName $hostToRemove.ResourceGroupName -HostPoolName $hostpool.Name -Name $sessionHostName -AllowNewSession:$false -ErrorAction SilentlyContinue | Out-Null
   $vmTags = @{}
   $vmTags += $hostToRemove.Tags
   $vmTags | ForEach-Object { $_.VMMaintenance = "True"; $_ } | Out-Null
   Update-AzVM -VM $hostToRemove -ResourceGroupName $hostToRemove.ResourceGroupName -Tag $vmTags | Out-Null
}

# Check to remove any sessions on the hosts being removed
$logOffMessageTitle = "Important Message"
$logOffMessageBody = "This machine is being powered down for system maintenance. `
  Please save your work and sign-out properly now. You can sign back in again straight away and will be moved to another machine. `
  You will be logged off in $secondsToForceLogOffUser seconds if you have not already signed out by then"

if ($userSessionsToRemove) {
   Write-Output "Sending log-off messages to all users on hosts being removed..."
   foreach ($session in $userSessionsToRemove) {
      $sessionHostName = $session.Name
      $sessionHostName = $sessionHostName.Split("/")[1]
      $sessionId = $session.Id
      $userSessionId = $sessionId.Split("/")[12]
      $resourceGroupName = $sessionId.Split("/")[4]
      $hostpoolName = $sessionId.Split("/")[8]

      # Notify users to log off their sessions
      try {
         Send-AzWvdUserSessionMessage -ResourceGroupName $resourceGroupName -HostPoolName $hostpoolName -SessionHostName $sessionHostName -UserSessionId $userSessionId -MessageTitle $LogOffMessageTitle -MessageBody $logOffMessageBody | Out-Null
      }
      catch {
         Write-Warning "Failed to send message to user with error: $($_.exception.message)"
      }
   }

   # Wait for user logoff timer to expire
   Write-Output "Waiting for user log-off timer to expire..."
   Start-Sleep -Seconds $secondsToForceLogOffUser

   Write-Output "Log-off timer expired. Forcing any remaining users on original hosts to log-off now..."
   foreach ($session in $userSessionsToRemove) {
      $sessionHostName = $session.Name
      $sessionHostName = $sessionHostName.Split("/")[1]
      $sessionId = $session.Id
      $userSessionId = $sessionId.Split("/")[12]
      $resourceGroupName = $sessionId.Split("/")[4]
      $hostpoolName = $sessionId.Split("/")[8]

      # Notify users to log off their sessions
      try {
         Remove-AzWvdUserSession -ResourceGroupName $resourceGroupName -HostPoolName $hostpoolName -SessionHostName $sessionHostName -Id $userSessionId | Out-Null
      }
      catch {
         Write-Warning "Failed to log off user session $($session.UserSessionid) on host '$vmName' with error: $($_.exception.message)"
      }
   }
}
#endregion

#region Domain Removal
# Ensure all hosts to be removed are powered on so they can be removed from the domain
Write-Output "Ensuring all hosts to remove are powered on..."
foreach ($hostToRemove in $hostsToRemove) {
   $hostStatus = Get-AzVM -Name $hostToRemove.Name -Status

   if ($hostStatus.PowerState -ne 'VM running') {
      Start-AzVM -Name $hostToRemove.Name -ResourceGroupName $hostToRemove.ResourceGroupName -AsJob | Out-Null
   }
}

# Check all original hosts are now powered on
Get-Job | Wait-Job | Out-Null
Write-Output "All hosts to remove are powered on..."

# Remove original session hosts from host pool & domain
Write-Output "Starting removal of hosts..."
foreach ($hostToRemove in $hostsToRemove) {

   $hostpool = Get-AzWvdHostPool -ResourceGroupName $hostToRemove.ResourceGroupName
   $originalHostpoolDeployment = Get-AzResourceGroupDeployment -ResourceGroupName $hostToRemove.ResourceGroupName | Where-Object { $_.DeploymentName -like "HostPool*" }

   # Remove session host from domain
   Write-Output "Removing host '$($hostToRemove.Name)' from domain..."
   $deploymentName = ($hostToRemove.Name + '-RemoveFromDomain-' + (Get-Date -Format FileDateTimeUniversal))
   New-AzResourceGroupDeployment `
      -Name $deploymentName `
      -ResourceGroupName $hostToRemove.ResourceGroupName `
      -TemplateUri https://raw.githubusercontent.com/Bistech/Azure/master/WVD/Hostpool/removeVMsFromDomain.json `
      -VMName $hostToRemove.Name `
      -Location $hostToRemove.Location `
      -DomainUser $originalHostpoolDeployment.Parameters.administratorAccountUsername.Value `
      -DomainPass $domainPass `
      -AsJob | Out-Null
}

Write-Output "Waiting for all domain removal jobs to complete..."
Get-Job | Wait-Job | Out-Null
Write-Output "All hosts have been successfully removed from the domain"
#endregion

#region Azure Removal
Write-Output "Removing hosts from Azure..."
foreach ($hostToRemove in $hostsToRemove) {
   $hostpool = Get-AzWvdHostPool -ResourceGroupName $hostToRemove.ResourceGroupName
   $sessionHostName = $hostToRemove.Name + "." + $originalHostpoolDeployment.Parameters.domain.Value

   # Remove session host
   Remove-AzWvdSessionHost -ResourceGroupName $hostToRemove.ResourceGroupName -HostPoolName $hostpool.Name -Name $sessionHostName -Force | Out-Null

   # Delete the VM
   Remove-AzVM -ResourceGroupName $hostToRemove.ResourceGroupName -Name $hostToRemove.Name -Force | Out-Null
        
   # Delete VM NIC
   Get-AzNetworkInterface -ResourceId $hostToRemove.NetworkProfile.NetworkInterfaces.Id | Remove-AzNetworkInterface -Force | Out-Null

   # Delete VM OS Disk
   Remove-AzDisk -ResourceGroupName $hostToRemove.ResourceGroupName -DiskName $hostToRemove.StorageProfile.OsDisk.Name -Force | Out-Null

   Write-Output "Host '$($hostToRemove.Name)' has successfully been removed from Azure"
}

Write-Output "All hosts have been successfully removed from Azure"
Write-Output "AVD host removal complete"
#endregion
