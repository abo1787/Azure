<# 
.SYNOPSIS
    This script automates the updating of an AVD host pool 

.DESCRIPTION
    This script is designed to automate the process of updating an AVD host pool from a Shared Image Gallery.
    It will deploy new session hosts matching the number of existing hosts from the latest version in the SIG
    that the original host pool was deployed from. Depending on the update mode chosen it can then place the
    original hosts into drain mode, log off user sessions, and remove the old session host resource from the
    customer domain and Azure

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

#region Parameters
Param(
   [Parameter(mandatory)]
   [ValidateSet("Auto", "Semi-Auto", "Test")]
   [string]$updateType = "Test",

   [Parameter(mandatory)]
   [string]$resourceGroupNames,

   [Parameter(mandatory)]
   [string]$keyVaultName,

   [int]$secondsToForceLogOffUser = 300
)
$resourceGroupNames = $resourceGroupNames -split ","
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

#region Update Hostpools
foreach ($resourceGroupName in $resourceGroupNames) {
   Write-Output "Starting update for Resource Group '$resourceGroupName'..."
   #region Get Values for Deployment
   # Calculate vmInitialNumber
   $hostpool = Get-AzWvdHostPool -ResourceGroupName $resourceGroupName
   $sessionHosts = Get-AzWvdSessionHost -ResourceGroupName $resourceGroupName -HostPoolName $hostpool.Name | Sort-Object Name -Descending
   $vmInitialNumber = $sessionHosts | Select-Object -First 1
   $vmInitialNumber = $vmInitialNumber.Name
   $vmInitialNumber = $vmInitialNumber.Split(".")[0]
   $vmInitialNumber = $vmInitialNumber.Split("-")[-1]
   [int]$vmInitialNumber = [int]$vmInitialNumber + 1

   # Get the agent version of current hosts
   $agentVersion = $sessionHosts | Sort-Object LastUpdateTime | Select-Object -First 1 | Select-Object -ExpandProperty AgentVersion

   # Calculate number of hosts to deploy
   [int]$vmNumberOfInstances = $sessionHosts.Count

   # Get availability set if it exists
   $availabiltySet = Get-AzAvailabilitySet -ResourceGroupName $resourceGroupName
   if ($availabiltySet) {
      $availabiltyOption = 'AvailabilitySet'
      $availabilitySetName = $availabiltySet.Name
   }
   else {
      $availabiltyOption = 'None'
      $availabilitySetName = ''
   }

   # Get Log Analytics values
   $laWorkspace = Get-AzDiagnosticSetting -ResourceId $hostpool.Id -WarningAction Ignore
   $laWorkspaceName = $laWorkspace.WorkspaceId
   $laResourceGroup = $laWorkspaceName.Split("/")[4]
   $laWorkspaceName = $laWorkspaceName.Split("/")[8]
   $laWorkspaceId = Get-AzOperationalInsightsWorkspace -Name $laWorkspaceName -ResourceGroupName $laResourceGroup | Select-Object -ExpandProperty CustomerId
   $laWorkspaceId = $laWorkspaceId.Guid
   $laWorkspaceKeys = Get-AzOperationalInsightsWorkspaceSharedKey -Name $laWorkspaceName -ResourceGroupName $laResourceGroup -WarningAction Ignore
   $laWorkspaceKey = $laWorkspaceKeys.PrimarySharedKey
   $laPublicSettings = @{ "workspaceId" = "$laWorkspaceId" }
   $laProtectedSettings = @{ "workspaceKey" = "$laWorkspaceKey" }
   
   # Get remaining values required for deployment
   $hostpoolTemplate = $hostpool.VMTemplate | ConvertFrom-Json
   $originalHostpoolDeployment = Get-AzResourceGroupDeployment -ResourceGroupName $resourceGroupName | Where-Object { $_.DeploymentName -like "HostPool*" }
   $hostpoolToken = New-AzWvdRegistrationInfo -ResourceGroupName $resourceGroupName -HostPoolName $hostpool.Name -ExpirationTime $((get-date).ToUniversalTime().AddDays(1).ToString('yyyy-MM-ddTHH:mm:ss.fffffffZ'))
   $domainJoinPassword = Get-AzKeyVaultSecret -VaultName $keyVaultName -Name 'avd-domain-join'
   $domainJoinPlain = Get-AzKeyVaultSecret -VaultName $keyVaultName -Name 'avd-domain-join' -AsPlainText
   $deploymentId = [guid]::NewGuid()
   $deploymentId = $deploymentId.Guid

   # Download templates
   $updateHostpoolTemplateUri = "https://raw.githubusercontent.com/Bistech/Azure/master/WVD/Hostpool/addVMsToHostpoolTemplate.json"
   $updateHostpoolParametersUri = "https://raw.githubusercontent.com/Bistech/Azure/master/WVD/Hostpool/addVMsToHostpoolParameters.json"
   $updateHostpoolParametersFilePath = "C:\Windows\Temp\addVMsToHostpoolParameters.json"
   Invoke-WebRequest -Uri $updateHostpoolParametersUri -OutFile $updateHostpoolParametersFilePath -UseBasicParsing

   # Replace parameters in template with relevant data
   ((Get-Content -path $updateHostpoolParametersFilePath -Raw) -replace '<hostpoolName>', $hostpool.Name) | Set-Content -Path $updateHostpoolParametersFilePath
   ((Get-Content -path $updateHostpoolParametersFilePath -Raw) -replace '<hostpoolToken>', $hostpoolToken.Token) | Set-Content -Path $updateHostpoolParametersFilePath
   ((Get-Content -path $updateHostpoolParametersFilePath -Raw) -replace '<administratorAccountUsername>', $originalHostpoolDeployment.Parameters.administratorAccountUsername.Value) | Set-Content -Path $updateHostpoolParametersFilePath
   ((Get-Content -path $updateHostpoolParametersFilePath -Raw) -replace '<vmAdministratorAccountUsername>', $originalHostpoolDeployment.Parameters.vmAdministratorAccountUsername.Value) | Set-Content -Path $updateHostpoolParametersFilePath
   ((Get-Content -path $updateHostpoolParametersFilePath -Raw) -replace '<availabilityOption>', $availabiltyOption) | Set-Content -Path $updateHostpoolParametersFilePath
   ((Get-Content -path $updateHostpoolParametersFilePath -Raw) -replace '<availabilitySetName>', $availabilitySetName) | Set-Content -Path $updateHostpoolParametersFilePath
   ((Get-Content -path $updateHostpoolParametersFilePath -Raw) -replace '<vmResourceGroup>', $originalHostpoolDeployment.Parameters.vmResourceGroup.Value) | Set-Content -Path $updateHostpoolParametersFilePath
   ((Get-Content -path $updateHostpoolParametersFilePath -Raw) -replace '<vmLocation>', $originalHostpoolDeployment.Parameters.vmLocation.Value) | Set-Content -Path $updateHostpoolParametersFilePath
   ((Get-Content -path $updateHostpoolParametersFilePath -Raw) -replace '<vmSize>', $hostpoolTemplate.vmSize.id) | Set-Content -Path $updateHostpoolParametersFilePath
   ((Get-Content -path $updateHostpoolParametersFilePath -Raw) -replace '<vmInitialNumber>', $vmInitialNumber) | Set-Content -Path $updateHostpoolParametersFilePath
   ((Get-Content -path $updateHostpoolParametersFilePath -Raw) -replace '<vmNumberOfInstances>', $vmNumberOfInstances) | Set-Content -Path $updateHostpoolParametersFilePath
   ((Get-Content -path $updateHostpoolParametersFilePath -Raw) -replace '<vmNamePrefix>', $hostpoolTemplate.namePrefix) | Set-Content -Path $updateHostpoolParametersFilePath
   ((Get-Content -path $updateHostpoolParametersFilePath -Raw) -replace '<vmImageType>', $hostpoolTemplate.imageType) | Set-Content -Path $updateHostpoolParametersFilePath
   ((Get-Content -path $updateHostpoolParametersFilePath -Raw) -replace '<vmCustomImageSourceId>', $hostpoolTemplate.customImageId) | Set-Content -Path $updateHostpoolParametersFilePath
   ((Get-Content -path $updateHostpoolParametersFilePath -Raw) -replace '<vmDiskType>', $hostpoolTemplate.osDiskType) | Set-Content -Path $updateHostpoolParametersFilePath
   ((Get-Content -path $updateHostpoolParametersFilePath -Raw) -replace '<existingVnetName>', $originalHostpoolDeployment.Parameters.existingVnetName.Value) | Set-Content -Path $updateHostpoolParametersFilePath
   ((Get-Content -path $updateHostpoolParametersFilePath -Raw) -replace '<existingSubnetName>', $originalHostpoolDeployment.Parameters.existingSubnetName.Value) | Set-Content -Path $updateHostpoolParametersFilePath
   ((Get-Content -path $updateHostpoolParametersFilePath -Raw) -replace '<virtualNetworkResourceGroupName>', $originalHostpoolDeployment.Parameters.virtualNetworkResourceGroupName.Value) | Set-Content -Path $updateHostpoolParametersFilePath
   ((Get-Content -path $updateHostpoolParametersFilePath -Raw) -replace '<deploymentId>', $deploymentId) | Set-Content -Path $updateHostpoolParametersFilePath
   ((Get-Content -path $updateHostpoolParametersFilePath -Raw) -replace '<ouPath>', $originalHostpoolDeployment.Parameters.ouPath.Value) | Set-Content -Path $updateHostpoolParametersFilePath
   ((Get-Content -path $updateHostpoolParametersFilePath -Raw) -replace '<domain>', $originalHostpoolDeployment.Parameters.domain.Value) | Set-Content -Path $updateHostpoolParametersFilePath
   #endregion

   #region New Hosts
   Write-Output "Deploying new session hosts..."
   # Deploy hostpool updates
   $deploymentName = 'UpdateHostpool-' + $deploymentId
   $updateHostpoolDeployment = New-AzResourceGroupDeployment `
      -Name $deploymentName `
      -ResourceGroupName $resourceGroupName `
      -TemplateUri $updateHostpoolTemplateUri `
      -TemplateParameterFile $updateHostpoolParametersFilePath `
      -administratorAccountPassword $domainJoinPassword.SecretValue `
      -vmAdministratorAccountPassword $domainJoinPassword.SecretValue

   if ($updateHostpoolDeployment.ProvisioningState -eq "Succeeded") {
      Write-Output "Successfully added $vmNumberofInstances session host(s) to host pool '$($hostpool.Name)'"
   }

   # Build object containing all new session hosts
   $vmEndNumber = ($vmInitialNumber + $vmNumberOfInstances) - 1
   $newSessionHostNumbers = $vmInitialNumber..$vmEndNumber
   $newSessionHosts = @()
   $newSessionHostsPreDomain = @()
   foreach ($newSessionHostNumber in $newSessionHostNumbers) {
      $newSessionHost = $hostpoolTemplate.namePrefix + '-' + $newSessionHostNumber + '.' + $originalHostpoolDeployment.Parameters.domain.Value
      $newSessionHosts += $newSessionHost
      $newSessionHostPreDomain = $hostpoolTemplate.namePrefix + '-' + $newSessionHostNumber
      $newSessionHostsPreDomain += $newSessionHostPreDomain
   }

   # Put all new session hosts in drain mode
   foreach ($newSessionHostPreDomain in $newSessionHostsPreDomain) {
      Update-AzWvdSessionHost -ResourceGroupName $resourceGroupName -HostPoolName $hostpool.Name -Name $newSessionHostPreDomain -AllowNewSession:$false -ErrorAction SilentlyContinue | Out-Null
   }
   foreach ($newSessionHost in $newSessionHosts) {
      Update-AzWvdSessionHost -ResourceGroupName $resourceGroupName -HostPoolName $hostpool.Name -Name $newSessionHost -AllowNewSession:$false -ErrorAction SilentlyContinue | Out-Null
   }

   # Wait for all new session hosts to become available
   Write-Output "Waiting for new hosts to become available..."
   foreach ($newSessionHost in $newSessionHosts) {
      $isHostAvailable = $false
      while ($isHostAvailable -eq $false) {
         $newVMStatus = Get-AzWvdSessionHost -ResourceGroupName $resourceGroupName -HostPoolName $hostpool.Name -Name $newSessionHost -ErrorAction SilentlyContinue
         if ($newVMStatus.Status -eq "Available") {
            Write-Output "Host '$newSessionHost' is now available"
            $isHostAvailable = $true
         }
      }
   }
   Write-Output "All new hosts are now available"

   # Connect all new session hosts to Log Analytics
   foreach ($newSessionHost in $newSessionHosts) {
      $newVMName = $newSessionHost.Split(".")[0]
      Set-AzVMExtension `
         -ExtensionName "MicrosoftMonitoringAgent" `
         -ResourceGroupName $resourceGroupName `
         -VMName $newVmName `
         -Location $originalHostpoolDeployment.Parameters.vmLocation.Value `
         -Publisher "Microsoft.EnterpriseCloud.Monitoring" `
         -ExtensionType "MicrosoftMonitoringAgent" `
         -TypeHandlerVersion 1.0 `
         -Settings $laPublicSettings `
         -ProtectedSettings $laProtectedSettings `
         -AsJob | Out-Null
   }
   Write-Output "Waiting for new hosts to be connected to the Log Analytics Workspace..."
   Get-Job | Wait-Job | Out-Null
   Write-Output "All new hosts have successfully been connected to the Log Analytics Workspace"

   # Check if machines require GPU extension
   $nvidiaVms = @()
   $amdVms = @()
   $allVmSizes = Get-AzVMSize -Location $originalHostpoolDeployment.Parameters.vmLocation.Value
   foreach ($vmSize in $allVmSizes) {
      if ($vmSize.Name -match 'Standard_NV[0-9]{0,2}[a-z]{0,2}_v3$') { $nvidiaVms += $vmSize }
      elseif ($vmSize.Name -match 'Standard_NV[0-9]{0,2}$') { $nvidiaVms += $vmSize }
      elseif ($vmSize.Name -match 'Standard_NV[0-9]{0,2}_Promo$') { $nvidiaVms += $vmSize }
      elseif ($vmSize.Name -match 'Standard_NC[0-9]{0,2}$') { $nvidiaVms += $vmSize }
      elseif ($vmSize.Name -match 'Standard_NC[0-9]{0,2}_Promo$') { $nvidiaVms += $vmSize }
      elseif ($vmSize.Name -match 'Standard_NC[0-9]{0,2}r$') { $nvidiaVms += $vmSize }
      elseif ($vmSize.Name -match 'Standard_NC[0-9]{0,2}[a-z]{0,2}_v3$') { $nvidiaVms += $vmSize }
      elseif ($vmSize.Name -match 'Standard_NC[0-9]{0,2}[a-z]{0,2}_T4_v[0-9]$') { $nvidiaVms += $vmSize }
      elseif ($vmSize.Name -match 'Standard_NV[0-9]{0,2}[a-z]{0,2}_v4$') { $amdVms += $vmSize }
   }

   # Set VM size
   $vmSize = $hostpoolTemplate.vmSize.id

   # Set GPU extension requirement
   if ($nvidiaVms.Name -contains $vmSize) {
      $gpuNVidia = $true
   }
   if ($amdVms.Name -contains $vmSize) {
      $gpuAMD = $true
   }

   # If GPU extension required deploy relevant extension to each new VM
   if ($gpuNVidia -eq $true -or $gpuAMD -eq $true) {
      if ($gpuNVidia -eq $true) {
         $extensionType = "NvidiaGpuDriverWindows"
         $typeHandlerVersion = 1.4
      }
      if ($gpuAMD -eq $true) {
         $extensionType = "AmdGpuDriverWindows"
         $typeHandlerVersion = 1.0
      }
      foreach ($newSessionHost in $newSessionHosts) {
         $newVMName = $newSessionHost.Split(".")[0]
         Set-AzVMExtension `
            -ExtensionName $extensionType `
            -ResourceGroupName $resourceGroupName `
            -VMName $newVmName `
            -Location $originalHostpoolDeployment.Parameters.vmLocation.Value `
            -Publisher "Microsoft.HpcCompute" `
            -ExtensionType $extensionType `
            -TypeHandlerVersion $typeHandlerVersion `
            -AsJob
      }
      Write-Output "Waiting for the GPU extension to be provisioned for new hosts..."
      Get-Job | Wait-Job | Out-Null
      Write-Output "All new hosts have successfully had the GPU extension installed"
   }

   # Wait for all new session hosts to upgrade
   Write-Output "Waiting for new hosts to upgrade..."
   foreach ($newSessionHost in $newSessionHosts) {
      $hasUpgraded = $false
      while ($hasUpgraded -eq $false) {
         $newVMName = $newSessionHost.Split(".")[0]
         $newVMStatus = Get-AzWvdSessionHost -ResourceGroupName $resourceGroupName -HostPoolName $hostpool.Name -Name $newSessionHost
         if ($newVMStatus.Status -eq "Available" -and $newVMStatus.AgentVersion -eq $agentVersion) {
            Update-AzWvdSessionHost -ResourceGroupName $resourceGroupName -HostPoolName $hostpool.Name -Name $newSessionHost -AllowNewSession:$true -ErrorAction SilentlyContinue | Out-Null
            $vm = Get-AzVM | Where-Object { $_.Name -eq $newVmName }
            $vmTags = @{}
            $vmTags += $vm.Tags
            $vmTags | ForEach-Object { $_.VMMaintenance = "False"; $_ } | Out-Null
            Update-AzVM -VM $vm -ResourceGroupName $vm.ResourceGroupName -Tag $vmTags | Out-Null
            Write-Output "Host '$newSessionHost' has now upgraded"
            $hasUpgraded = $true
         }
      }
   }
   Write-Output "All new hosts have now upgraded"
   Write-Output "Allowing sessions to connect to new hosts"

   # Remove template parameter file
   Remove-Item $updateHostpoolParametersFilePath
   #endregion

   #region Old Hosts
   if ($updateType -eq 'Semi-Auto' -or $updateType -eq 'Auto') {
      # Put original session hosts into drain mode
      Write-Output "Setting original hosts into drain mode..."
      $originalSessionHostsToRemove = @()
      $originalSessionHosts = [System.Collections.ArrayList]@()
      foreach ($sessionHost in $sessionHosts) {
         $sessionHostName = $sessionHost.Name
         $sessionHostName = $sessionHostName.Split("/")[1]
         $vmName = $sessionHostName.Split(".")[0]
         $originalSessionHosts.Add($sessionHostName) | Out-Null
         $originalSessionHostsToRemove += $sessionHostName
         Update-AzWvdSessionHost -ResourceGroupName $resourceGroupName -HostPoolName $hostpool.Name -Name $sessionHostName -AllowNewSession:$false -ErrorAction SilentlyContinue | Out-Null
         $vm = Get-AzVM | Where-Object { $_.Name -eq $vmName }
         $vmTags = @{}
         $vmTags += $vm.Tags
         $vmTags | ForEach-Object { $_.VMMaintenance = "True"; $_ } | Out-Null
         Update-AzVM -VM $vm -ResourceGroupName $vm.ResourceGroupName -Tag $vmTags | Out-Null
      }
      # Get sessions to log off
      $userSessions = Get-AzWvdUserSession -ResourceGroupName $resourceGroupName -HostPoolName $hostpool.Name
      $logOffMessageTitle = "Important Message"
      $logOffMessageBody = "This machine is being powered down for system maintenance. `
      Please save your work and sign-out properly now. You can sign back in again straight away and will be moved to another machine. `
      You will be logged off in $secondsToForceLogOffUser seconds if you have not already signed out by then"

      Write-Output "Sending log-off messages to all users on original hosts..."
      foreach ($session in $userSessions) {
         $sessionHostName = $session.Name
         $sessionHostName = $sessionHostName.Split("/")[1]
         $sessionId = $session.Id
         $sessionId = $sessionId.Split("/")[12]

         # Notify users on original hosts to log off their sessions
         if ($originalSessionHosts -contains $sessionHostName) {
            try {
               Send-AzWvdUserSessionMessage -ResourceGroupName $resourceGroupName -HostPoolName $hostpool.Name -SessionHostName $sessionHostName -UserSessionId $sessionId -MessageTitle $LogOffMessageTitle -MessageBody $logOffMessageBody | Out-Null
            }
            catch {
               Write-Error "Failed to send message to user with error: $($_.exception.message)"
            }
         }
      }

      # Wait for user logoff timer to expire
      Write-Output "Waiting for user log-off timer to expire..."
      Start-Sleep -Seconds $secondsToForceLogOffUser

      # Get user sessions still on original hosts
      $userSessions = Get-AzWvdUserSession -ResourceGroupName $resourceGroupName -HostPoolName $hostpool.Name

      Write-Output "Log-off timer expired. Forcing any remaining users on original hosts to log-off now..."
      foreach ($session in $userSessions) {
         $sessionHostName = $session.Name
         $sessionHostName = $sessionHostName.Split("/")[1]
         $vmName = $sessionHostName.Split(".")[0]
         $sessionId = $session.Id
         $sessionId = $sessionId.Split("/")[12]

         # Log off users on original hosts
         if ($originalSessionHosts -contains $sessionHostName) {
            try {
               Remove-AzWvdUserSession -ResourceGroupName $resourceGroupName -HostPoolName $hostpool.Name -SessionHostName $sessionHostName -Id $sessionId | Out-Null
            }
            catch {
               Write-Error "Failed to log off user session $($session.UserSessionid) on host '$vmName' with error: $($_.exception.message)"
            }
         }
      }
   }

   if ($updateType -eq 'Semi-Auto') {

      # Add removal tag to VMs and shut down
      $maintenanceTagName = "DisableAutoUpdate"
      $removalTagName = "RemovalDate"
      $today = Get-Date
      $removalDate = $today.AddDays(14)
      $removalDate = Get-Date -Date $removalDate -Format yyyy-MM-dd

      foreach ($originalHost in $originalSessionHostsToRemove) {
         $vmName = $originalHost.Split(".")[0]
         $vmInfo = Get-AzVM -Name $vmName
         $vmStatus = Get-AzVM -Name $vmName -Status
         $tagTable = New-Object PSObject
         $vmInfo.Tags.GetEnumerator() | ForEach-Object { Add-Member -InputObject $tagTable -MemberType NoteProperty -Name $_.Key -Value $_.Value }

         if ($tagTable.$maintenanceTagName -eq $True) {
            Write-Output "The host '$vmName' has 'DisableAutoUpdate' set to 'True'. This host will not be removed automatically"
            $originalSessionHosts.Remove($originalHost) | Out-Null
            continue
         }
         else {
            $vmTags = @{}
            $vmTags += $vmInfo.Tags
            $vmTags | ForEach-Object { $_.$removalTagName = $removalDate; $_ } | Out-Null
            Update-AzVM -VM $vmInfo -ResourceGroupName $vmInfo.ResourceGroupName -Tag $vmTags | Out-Null
            Write-Output "Added removal date tag for host '$vmName' of '$removalDate'"
            Stop-AzVM -Name $vmName -ResourceGroupName $vmInfo.ResourceGroupName -Force | Out-Null
         }
      }
   }
   if ($updateType -eq 'Auto') {

      # Ensure all original session hosts are powered on so they can be removed from the domain
      $maintenanceTagName = "DisableAutoUpdate"

      Write-Output "Ensuring all original hosts to remove are powered on..."
      foreach ($originalHost in $originalSessionHostsToRemove) {
         $vmName = $originalHost.Split(".")[0]
         $vmInfo = Get-AzVM -Name $vmName
         $vmStatus = Get-AzVM -Name $vmName -Status
         $tagTable = New-Object PSObject
         $vmInfo.Tags.GetEnumerator() | ForEach-Object { Add-Member -InputObject $tagTable -MemberType NoteProperty -Name $_.Key -Value $_.Value }

         if ($tagTable.$maintenanceTagName -eq $True) {
            Write-Output "The host '$vmName' has 'DisableAutoUpdate' set to 'True'. This host will not be removed automatically"
            $originalSessionHosts.Remove($originalHost) | Out-Null
            continue
         }
         if ($vmStatus.PowerState -ne 'VM running') {
            Start-AzVM -Name $vmName -ResourceGroupName $resourceGroupName -AsJob | Out-Null
         }
      }

      # Get reqs for domain removal
      $domainPass = ConvertTo-SecureString -String $domainJoinPlain -AsPlainText -Force

      # Check all original hosts are now powered on
      Get-Job | Wait-Job | Out-Null
      Write-Output "All original hosts to remove are running"

      # Remove original session hosts from host pool & domain
      Write-Output "Starting removal of all original session hosts..."
      foreach ($originalHost in $originalSessionHosts) {
         $vmName = $originalHost.Split(".")[0]

         # Remove session host from domain
         Write-Output "Removing host '$vmName' from domain..."
         $deploymentName = ($vmName + '-RemoveFromDomain-' + (Get-Date -Format FileDateTimeUniversal))
         New-AzResourceGroupDeployment `
            -Name $deploymentName `
            -ResourceGroupName $resourceGroupName `
            -TemplateUri https://raw.githubusercontent.com/Bistech/Azure/master/WVD/Hostpool/removeVMsFromDomain.json `
            -VMName $vmName `
            -Location $originalHostpoolDeployment.Parameters.vmLocation.Value `
            -DomainUser $originalHostpoolDeployment.Parameters.administratorAccountUsername.Value `
            -DomainPass $domainPass `
            -AsJob | Out-Null
      }

      Write-Output "Waiting for all domain removal jobs to complete..."
      Get-Job | Wait-Job | Out-Null
      Write-Output "All original hosts have been successfully removed from the domain"

      Write-Output "Removing original hosts from Azure..."
      foreach ($originalHost in $originalSessionHosts) {
         $vmName = $originalHost.Split(".")[0]

         # Remove session host
         Remove-AzWvdSessionHost -ResourceGroupName $resourceGroupName -HostPoolName $hostpool.Name -Name $originalHost -Force | Out-Null

         # Get the VM
         $vm = Get-AzVM -Name $vmName -ResourceGroupName $resourceGroupName

         # Delete the VM
         Remove-AzVM -ResourceGroupName $resourceGroupName -Name $vmName -Force | Out-Null
        
         # Delete VM NIC
         Get-AzNetworkInterface -ResourceId $vm.NetworkProfile.NetworkInterfaces.Id | Remove-AzNetworkInterface -Force | Out-Null

         # Delete VM OS Disk
         Remove-AzDisk -ResourceGroupName $resourceGroupName -DiskName $vm.StorageProfile.OsDisk.Name -Force | Out-Null

         Write-Output "Host '$vmName' has successfully been removed from Azure"
      }
      Write-Output "All original hosts have been successfully removed from Azure"
      Write-Output "Host pool '$($hostpool.Name)' has been updated successfully"
   }
   Write-Output "Finished update for resource group '$resourceGroupName'"
   #endregion
}
Write-Output "All hostpools have successfully been updated"
#endregion