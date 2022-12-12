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
    Version : 2.0.4

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
  [string]$resourceGroupName,

  [Parameter(mandatory)]
  [string]$keyVaultName,

  [Parameter(mandatory)]
  [string]$logAnalyticsWorkspaceId,

  [Parameter(mandatory)]
  [string]$logAnalyticsPrimaryKey,

  [Parameter(mandatory)]
  [string]$imageResourceGroupName,

  [Parameter(mandatory)]
  [string]$imageACGName,

  [Parameter(mandatory)]
  [string]$imageACGDefintionName,

  [Parameter(mandatory)]
  [string]$bistechGUID,

  [int]$secondsToForceLogOffUser = 300
)
#endregion

#region Pre-Reqs
Set-ExecutionPolicy -ExecutionPolicy Undefined -Scope Process -Force -Confirm:$false
Set-ExecutionPolicy -ExecutionPolicy Unrestricted -Scope LocalMachine -Force -Confirm:$false

# Set Variables
$logName = 'AVDUpdateHostPool_CL'
$rollbackTriggered = $false
$gpuNVidia = $false
$gpuAMD = $false
$acceleratedNetworkingEnabled = $false

# Setting ErrorActionPreference to stop script execution when error occurs
$ErrorActionPreference = "Stop"

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
#endregion

#region Functions
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

#region Cleanup old Resource Group Deployments
$aaAccount = Get-AzAutomationAccount | Where-Object { $_.AutomationAccountName -eq 'AVDAutomationAccount' }
Write-Output "Starting update for resource group '$resourceGroupName'..."
Write-Output "Triggering 'automation_AVDResourceDeploymentCleaner_Runbook' to clean up previous resource group deployments..."
$params = @{"resourceGroupName" = "$resourceGroupName" }

Start-AzAutomationRunbook `
  -AutomationAccountName 'AVDAutomationAccount' `
  -Name 'automation_AVDResourceDeploymentCleaner_Runbook'`
  -ResourceGroupName $aaAccount.ResourceGroupName `
  -Parameters $params `
| Out-Null
#endregion

#region Get Values for Deployment
# Calculate vmInitialNumber
$hostpool = Get-AzWvdHostPool -ResourceGroupName $resourceGroupName
$sessionHosts = Get-AzWvdSessionHost -ResourceGroupName $resourceGroupName -HostPoolName $hostpool.Name | Sort-Object Name -Descending
$sanitizedNumberTable = @()
foreach ($sessionHost in $sessionHosts) {
  $vmNumberObj = $sessionHost.Name
  $vmNumberObj = $vmNumberObj.Split(".")[0]
  $vmNumberObj = $vmNumberObj.Split("-")[-1]
  if ($vmNumberObj.Length -eq 1) {
    $vmNumberObj = "00" + $vmNumberObj
  }
  if ($vmNumberObj.Length -eq 2) {
    $vmNumberObj = "0" + $vmNumberObj
  }
  $sanitizedNumberTable += $vmNumberObj
}
$vmInitialNumberObj = $sanitizedNumberTable | Sort-Object -Descending | Select-Object -First 1
[int]$vmInitialNumber = [int]$vmInitialNumberObj + 1

# Get VmSize - use current vm size in case size changed since initial hostpool deployment
$vmSize = $sessionHosts | Select-Object -First 1
$vmLocation = (Get-AzVm | Where-Object { $_.VmId -eq $vmSize.VirtualMachineId }).Location
$vmSize = (Get-AzVm | Where-Object { $_.VmId -eq $vmSize.VirtualMachineId }).HardwareProfile.VmSize

# Get supported capabilites of VM
$sku = Get-AzComputeResourceSku -Location $vmLocation | Where-Object { $_.Name -eq $vmSize }
$skuCapabilities = $sku.Capabilities
$acceleratedNetworkingCapable = $skuCapabilities | Where-Object { $_.Name -eq 'AcceleratedNetworkingEnabled' } | Select-Object Value -ExpandProperty Value
if ($acceleratedNetworkingCapable -eq 'True') { 
  $acceleratedNetworkingCapable = $true 
}
else { 
  $acceleratedNetworkingCapable = $false 
}

# Calculate number of hosts to deploy
[int]$vmNumberOfInstances = $sessionHosts.Count

# Start back at VM-0 once machine numbers will breach 1000
if (($vmInitialNumber + $vmNumberOfInstances) -ge 1000) {
  [int]$vmInitialNumber = 0
}

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
$secureBoot = $originalHostpoolDeployment.Parameters.secureBoot.Value | ConvertTo-Json
$vTPM = $originalHostpoolDeployment.Parameters.vTPM.Value | ConvertTo-Json
$hostpoolToken = New-AzWvdRegistrationInfo -ResourceGroupName $resourceGroupName -HostPoolName $hostpool.Name -ExpirationTime $((get-date).ToUniversalTime().AddDays(1).ToString('yyyy-MM-ddTHH:mm:ss.fffffffZ'))
$domainJoinPassword = Get-AzKeyVaultSecret -VaultName $keyVaultName -Name 'avd-domain-join'
$domainJoinPlain = Get-AzKeyVaultSecret -VaultName $keyVaultName -Name 'avd-domain-join' -AsPlainText
$dfeAutoOffboard = Get-AzKeyVaultSecret -VaultName $keyVaultName -Name 'dfe-auto-offboard' -AsPlainText -ErrorAction SilentlyContinue | ConvertFrom-Json
$dfeTenantId = Get-AzKeyVaultSecret -VaultName $keyVaultName -Name 'dfe-tenant-id' -AsPlainText -ErrorAction SilentlyContinue
$dfeAppId = Get-AzKeyVaultSecret -VaultName $keyVaultName -Name 'dfe-app-id' -AsPlainText -ErrorAction SilentlyContinue
$dfeAppSecret = Get-AzKeyVaultSecret -VaultName $keyVaultName -Name 'dfe-app-secret' -AsPlainText -ErrorAction SilentlyContinue
$deploymentId = [guid]::NewGuid()
$deploymentId = $deploymentId.Guid
$imageVersions = Get-AzGalleryImageVersion -ResourceGroupName $imageResourceGroupName -GalleryName $imageACGName -GalleryImageDefinitionName $imageACGDefintionName | Where-Object { $_.PublishingProfile.ExcludeFromLatest -eq $false } | Select-Object Id
$imageVersion = $imageVersions | Sort-Object Id -Descending | Select-Object -First 1 -ExpandProperty Id

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
   ((Get-Content -path $updateHostpoolParametersFilePath -Raw) -replace '<vmSize>', $vmSize ) | Set-Content -Path $updateHostpoolParametersFilePath
   ((Get-Content -path $updateHostpoolParametersFilePath -Raw) -replace '<vmInitialNumber>', $vmInitialNumber) | Set-Content -Path $updateHostpoolParametersFilePath
   ((Get-Content -path $updateHostpoolParametersFilePath -Raw) -replace '<vmNumberOfInstances>', $vmNumberOfInstances) | Set-Content -Path $updateHostpoolParametersFilePath
   ((Get-Content -path $updateHostpoolParametersFilePath -Raw) -replace '<vmNamePrefix>', $hostpoolTemplate.namePrefix) | Set-Content -Path $updateHostpoolParametersFilePath
   ((Get-Content -path $updateHostpoolParametersFilePath -Raw) -replace '<vmImageType>', $hostpoolTemplate.imageType) | Set-Content -Path $updateHostpoolParametersFilePath
   ((Get-Content -path $updateHostpoolParametersFilePath -Raw) -replace '<vmCustomImageSourceId>', $imageVersion) | Set-Content -Path $updateHostpoolParametersFilePath
   ((Get-Content -path $updateHostpoolParametersFilePath -Raw) -replace '<vmDiskType>', $hostpoolTemplate.osDiskType) | Set-Content -Path $updateHostpoolParametersFilePath
   ((Get-Content -path $updateHostpoolParametersFilePath -Raw) -replace '<existingVnetName>', $originalHostpoolDeployment.Parameters.existingVnetName.Value) | Set-Content -Path $updateHostpoolParametersFilePath
   ((Get-Content -path $updateHostpoolParametersFilePath -Raw) -replace '<existingSubnetName>', $originalHostpoolDeployment.Parameters.existingSubnetName.Value) | Set-Content -Path $updateHostpoolParametersFilePath
   ((Get-Content -path $updateHostpoolParametersFilePath -Raw) -replace '<virtualNetworkResourceGroupName>', $originalHostpoolDeployment.Parameters.virtualNetworkResourceGroupName.Value) | Set-Content -Path $updateHostpoolParametersFilePath
   ((Get-Content -path $updateHostpoolParametersFilePath -Raw) -replace '<deploymentId>', $deploymentId) | Set-Content -Path $updateHostpoolParametersFilePath
   ((Get-Content -path $updateHostpoolParametersFilePath -Raw) -replace '<ouPath>', $originalHostpoolDeployment.Parameters.ouPath.Value) | Set-Content -Path $updateHostpoolParametersFilePath
   ((Get-Content -path $updateHostpoolParametersFilePath -Raw) -replace '<domain>', $originalHostpoolDeployment.Parameters.domain.Value) | Set-Content -Path $updateHostpoolParametersFilePath
   ((Get-Content -path $updateHostpoolParametersFilePath -Raw) -replace '<securityType>', $originalHostpoolDeployment.Parameters.securityType.Value) | Set-Content -Path $updateHostpoolParametersFilePath
   ((Get-Content -path $updateHostpoolParametersFilePath -Raw) -replace '<secureBoot>', $secureBoot) | Set-Content -Path $updateHostpoolParametersFilePath
   ((Get-Content -path $updateHostpoolParametersFilePath -Raw) -replace '<vTPM>', $vTPM) | Set-Content -Path $updateHostpoolParametersFilePath

# Build object containing all new session hosts
$vmEndNumber = ($vmInitialNumber + $vmNumberOfInstances) - 1
$newSessionHostNumbers = $vmInitialNumber..$vmEndNumber
$newSessionHosts = @()
$newSessionHostsPreDomain = @()
$avdSessionHostNames = @()
foreach ($newSessionHostNumber in $newSessionHostNumbers) {
  $newSessionHost = $hostpoolTemplate.namePrefix + '-' + $newSessionHostNumber + '.' + $originalHostpoolDeployment.Parameters.domain.Value
  $newSessionHosts += $newSessionHost
  $newSessionHostPreDomain = $hostpoolTemplate.namePrefix + '-' + $newSessionHostNumber
  $newSessionHostsPreDomain += $newSessionHostPreDomain
  $avdSessionHostName = $hostpool.Name + '/' + $newSessionHost
  $avdSessionHostNames += $avdSessionHostName
}
#endregion

#region New Hosts
Write-Output "Deploying new session hosts..."
# Deploy hostpool updates
$deploymentName = 'UpdateHostpool-' + $deploymentId
$poolDeploymentSuccessful = $false
$updateHostpoolDeployment = New-AzResourceGroupDeployment `
  -Name $deploymentName `
  -ResourceGroupName $resourceGroupName `
  -TemplateUri $updateHostpoolTemplateUri `
  -TemplateParameterFile $updateHostpoolParametersFilePath `
  -administratorAccountPassword $domainJoinPassword.SecretValue `
  -vmAdministratorAccountPassword $domainJoinPassword.SecretValue `
  -ErrorAction SilentlyContinue

if ($updateHostpoolDeployment.ProvisioningState -eq "Succeeded") {
  $poolDeploymentSuccessful = $true
  Write-Output "Successfully added $vmNumberofInstances new session host(s) to host pool '$($hostpool.Name)'"
}
#endregion

#region Roll-Back on deployment failure
if ($poolDeploymentSuccessful -eq $false) {
  Write-Warning "One or more new session hosts failed to deploy correctly. The host pool upgrade process will now be rolled back"
  $rollbackTriggered = $true

  # Get reqs for domain removal
  $domainPass = ConvertTo-SecureString -String $domainJoinPlain -AsPlainText -Force

  # Remove failed session hosts from host pool & domain
  Write-Output "Starting removal of all newly deployed session hosts..."
  $domainRemovalSuccess = $false
  foreach ($newSessionHost in $newSessionHosts) {
    $newVMName = $newSessionHost.Split(".")[0]
  
    # Remove session host from domain
    Write-Output "Removing host '$newVMName' from domain..."
    $deploymentName = ($newVMName + '-RemoveFromDomain-' + (Get-Date -Format FileDateTimeUniversal))
    New-AzResourceGroupDeployment `
      -Name $deploymentName `
      -ResourceGroupName $resourceGroupName `
      -TemplateUri https://raw.githubusercontent.com/Bistech/Azure/master/WVD/Hostpool/removeVMsFromDomain.json `
      -VMName $newVMName `
      -Location $originalHostpoolDeployment.Parameters.vmLocation.Value `
      -DomainUser $originalHostpoolDeployment.Parameters.administratorAccountUsername.Value `
      -DomainPass $domainPass `
      -AsJob | Out-Null
  }
 
  Write-Output "Waiting for all domain removal jobs to complete..."
  Get-Job | Wait-Job | Out-Null
  Write-Output "All newly deployed hosts have been successfully removed from the domain"
  $domainRemovalSuccess = $true
 
  Write-Output "Removing newly deployed hosts from Azure..."
  $azureRemovalSuccess = $false
  foreach ($newSessionHostPreDomain in $newSessionHostsPreDomain) {

    # Remove session host from host pool (in case domain join failed)
    Remove-AzWvdSessionHost -ResourceGroupName $resourceGroupName -HostPoolName $hostpool.Name -Name $newSessionHostPreDomain -Force -ErrorAction SilentlyContinue | Out-Null
  }
  foreach ($newSessionHost in $newSessionHosts) {
    $newVMName = $newSessionHost.Split(".")[0]
 
    # Remove session host from host pool
    Remove-AzWvdSessionHost -ResourceGroupName $resourceGroupName -HostPoolName $hostpool.Name -Name $newSessionHost -Force -ErrorAction SilentlyContinue | Out-Null
 
    # Get the VM
    $vm = Get-AzVM -Name $newVMName -ResourceGroupName $resourceGroupName
 
    # Delete the VM
    Remove-AzVM -ResourceGroupName $resourceGroupName -Name $newVMName -Force | Out-Null
         
    # Delete VM NIC
    Get-AzNetworkInterface -ResourceId $vm.NetworkProfile.NetworkInterfaces.Id | Remove-AzNetworkInterface -Force | Out-Null
 
    # Delete VM OS Disk
    Remove-AzDisk -ResourceGroupName $resourceGroupName -DiskName $vm.StorageProfile.OsDisk.Name -Force | Out-Null
 
    Write-Output "Host '$newVMName' has successfully been removed from Azure"
  }
  Write-Output "All newly deployed hosts have been successfully removed from Azure"
  $azureRemovalSuccess = $true
  Write-Output "Host pool '$($hostpool.Name)' rollback has been completed successfully"
  Write-Error "Update failed for host pool '$($hostpool.Name)' and the deployment was rolled back" -ErrorAction Continue
 
  # Remove template parameter file
  Remove-Item $updateHostpoolParametersFilePath
}
#endregion

#region Check availability
if ($poolDeploymentSuccessful -eq $true) {
  # Put all new session hosts in drain mode
  foreach ($newSessionHostPreDomain in $newSessionHostsPreDomain) {
    Update-AzWvdSessionHost -ResourceGroupName $resourceGroupName -HostPoolName $hostpool.Name -Name $newSessionHostPreDomain -AllowNewSession:$false -ErrorAction SilentlyContinue | Out-Null
  }
  foreach ($newSessionHost in $newSessionHosts) {
    Update-AzWvdSessionHost -ResourceGroupName $resourceGroupName -HostPoolName $hostpool.Name -Name $newSessionHost -AllowNewSession:$false -ErrorAction SilentlyContinue | Out-Null
  }

  # Wait for all new session hosts to become available
  Write-Output "Waiting for new hosts to become available..."
  $poolAvailable = $false
  [int]$availableHosts = 0
  $availableStartTime = Get-Date
  $availableTimeoutTime = $availableStartTime.AddMinutes(10)
  foreach ($newSessionHost in $newSessionHosts) {
    $isHostAvailable = $false
    while ($(Get-Date) -le $availableTimeoutTime -and $isHostAvailable -eq $false) {
      $newVMStatus = Get-AzWvdSessionHost -ResourceGroupName $resourceGroupName -HostPoolName $hostpool.Name -Name $newSessionHost -ErrorAction SilentlyContinue
      if ($newVMStatus.Status -eq "Available") {
        $isHostAvailable = $true
        $availableHosts = $availableHosts + 1
      }
    }
  }

  # If all hosts still aren't available then reboot hosts that aren't to see if it fixes them
  if ($availableHosts -lt $vmNumberOfInstances) {
    $avdNewSessionHosts = Get-AzWvdSessionHost -ResourceGroupName $resourceGroupName -HostPoolName $hostpool.Name | Where-Object { $avdSessionHostNames -contains $_.Name }
    $notAvailableHosts = $avdNewSessionHosts | Where-Object { $_.Status -ne 'Available' }
    foreach ($notAvailableHost in $notAvailableHosts) {
      $notAvailableHostVMName = $notAvailableHost.Name.Split("/")[1]
      $notAvailableHostVMName = $notAvailableHostVMName.Split(".")[0]
      $vm = Get-AzVM | Where-Object { $_.Name -eq $notAvailableHostVMName }
      Restart-AzVM -Name $notAvailableHostVMName -ResourceGroupName $vm.ResourceGroupName -NoWait | Out-Null
      Write-Output "Host '$notAvailableHostVMName' has been rebooted as it is still not showing as available"
    }
  }

  # Wait for all new session hosts to become available
  [int]$availableHosts = 0
  $availableStartTime = Get-Date
  $availableTimeoutTime = $availableStartTime.AddMinutes(10)
  foreach ($newSessionHost in $newSessionHosts) {
    $isHostAvailable = $false
    while ($(Get-Date) -le $availableTimeoutTime -and $isHostAvailable -eq $false) {
      $newVMStatus = Get-AzWvdSessionHost -ResourceGroupName $resourceGroupName -HostPoolName $hostpool.Name -Name $newSessionHost -ErrorAction SilentlyContinue
      if ($newVMStatus.Status -eq "Available") {
        $isHostAvailable = $true
        $availableHosts = $availableHosts + 1
      }
    }
  }
   
  # Check to see if all hosts are available, if not call rollback
  if ($availableHosts -eq $vmNumberOfInstances) {
    $poolAvailable = $true
    Write-Output "All new hosts are now available"
  }
}
#endregion

#region Roll-Back on availability failure
if ($poolDeploymentSuccessful -eq $true -and $poolAvailable -eq $false) {
  Write-Warning "One or more session hosts failed to become available before the timeout period expired. The host pool upgrade process will now be rolled back"
  $rollbackTriggered = $true

  # Get reqs for domain removal
  $domainPass = ConvertTo-SecureString -String $domainJoinPlain -AsPlainText -Force

  # Remove failed session hosts from host pool & domain
  Write-Output "Starting removal of all newly deployed session hosts..."
  $domainRemovalSuccess = $false
  foreach ($newSessionHost in $newSessionHosts) {
    $newVMName = $newSessionHost.Split(".")[0]
 
    # Remove session host from domain
    Write-Output "Removing host '$newVMName' from domain..."
    $deploymentName = ($newVMName + '-RemoveFromDomain-' + (Get-Date -Format FileDateTimeUniversal))
    New-AzResourceGroupDeployment `
      -Name $deploymentName `
      -ResourceGroupName $resourceGroupName `
      -TemplateUri https://raw.githubusercontent.com/Bistech/Azure/master/WVD/Hostpool/removeVMsFromDomain.json `
      -VMName $newVMName `
      -Location $originalHostpoolDeployment.Parameters.vmLocation.Value `
      -DomainUser $originalHostpoolDeployment.Parameters.administratorAccountUsername.Value `
      -DomainPass $domainPass `
      -AsJob | Out-Null
  }

  Write-Output "Waiting for all domain removal jobs to complete..."
  Get-Job | Wait-Job | Out-Null
  Write-Output "All newly deployed hosts have been successfully removed from the domain"
  $domainRemovalSuccess = $true

  Write-Output "Removing newly deployed hosts from Azure..."
  $azureRemovalSuccess = $false
  foreach ($newSessionHost in $newSessionHosts) {
    $newVMName = $newSessionHost.Split(".")[0]

    # Remove session host
    Remove-AzWvdSessionHost -ResourceGroupName $resourceGroupName -HostPoolName $hostpool.Name -Name $newSessionHost -Force | Out-Null

    # Get the VM
    $vm = Get-AzVM -Name $newVMName -ResourceGroupName $resourceGroupName

    # Delete the VM
    Remove-AzVM -ResourceGroupName $resourceGroupName -Name $newVMName -Force | Out-Null
        
    # Delete VM NIC
    Get-AzNetworkInterface -ResourceId $vm.NetworkProfile.NetworkInterfaces.Id | Remove-AzNetworkInterface -Force | Out-Null

    # Delete VM OS Disk
    Remove-AzDisk -ResourceGroupName $resourceGroupName -DiskName $vm.StorageProfile.OsDisk.Name -Force | Out-Null

    Write-Output "Host '$newVMName' has successfully been removed from Azure"
  }
  Write-Output "All newly deployed hosts have been successfully removed from Azure"
  $azureRemovalSuccess = $true
  Write-Output "Host pool '$($hostpool.Name)' rollback has been completed successfully"
  Write-Error "Update failed for host pool '$($hostpool.Name)' and the deployment was rolled back" -ErrorAction Continue

  # Remove template parameter file
  Remove-Item $updateHostpoolParametersFilePath
}
#endregion

#region Log Analytics
if ($poolAvailable -eq $true) {
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
}
#endregion

#region GPU Extension
if ($poolAvailable -eq $true) {
  # Check if machines require GPU extension
  $nvidiaVms = @()
  $amdVms = @()
  $allVmSizes = Get-AzVMSize -Location $originalHostpoolDeployment.Parameters.vmLocation.Value
  foreach ($size in $allVmSizes) {
    if ($size.Name -match 'Standard_NV[0-9]{0,2}[a-z]{0,2}_v3$') { $nvidiaVms += $size }
    elseif ($size.Name -match 'Standard_NV[0-9]{0,2}$') { $nvidiaVms += $size }
    elseif ($size.Name -match 'Standard_NV[0-9]{0,2}_Promo$') { $nvidiaVms += $size }
    elseif ($size.Name -match 'Standard_NC[0-9]{0,2}$') { $nvidiaVms += $size }
    elseif ($size.Name -match 'Standard_NC[0-9]{0,2}_Promo$') { $nvidiaVms += $size }
    elseif ($size.Name -match 'Standard_NC[0-9]{0,2}r$') { $nvidiaVms += $size }
    elseif ($size.Name -match 'Standard_NC[0-9]{0,2}[a-z]{0,2}_v3$') { $nvidiaVms += $size }
    elseif ($size.Name -match 'Standard_NC[0-9]{0,2}[a-z]{0,2}_T4_v[0-9]$') { $nvidiaVms += $size }
    elseif ($size.Name -match 'Standard_NV[0-9]{0,2}[a-z]{0,2}_v4$') { $amdVms += $size }
  }

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
        -AsJob | Out-Null
    }
    Write-Output "Waiting for the GPU extension to be provisioned for new hosts..."
    Get-Job | Wait-Job | Out-Null
    Write-Output "All new hosts have successfully had the GPU extension installed"
  }
}
#endregion

#region Accelerated Networking
if ($poolAvailable -eq $true) {
  # Enable Accelerated Networking if SKU supports it
  if ($acceleratedNetworkingCapable -eq $true) {
    foreach ($newSessionHost in $newSessionHosts) {
      $newVMName = $newSessionHost.Split(".")[0]
      Stop-AzVM -Name $newVMName -ResourceGroupName $resourceGroupName -Force -NoWait -AsJob | Out-Null
    }
    Write-Output "Shutting down hosts to enable accelerated networking..."
    Get-Job | Wait-Job | Out-Null
    Write-Output "All new hosts have successfully been shut down"
    Write-Output "Enabling accelerated networking and restarting hosts..."

    foreach ($newSessionHost in $newSessionHosts) {
      $newVMName = $newSessionHost.Split(".")[0]
      $vm = Get-AzVM | Where-Object { $_.Name -eq $newVMName }
      $nic = Get-AzNetworkInterface -ResourceId $vm.NetworkProfile.NetworkInterfaces.Id
      $nic.EnableAcceleratedNetworking = $true
      $nic | Set-AzNetworkInterface | Out-Null
      Start-AzVM -Name $newVMName -ResourceGroupName $resourceGroupName -NoWait -AsJob | Out-Null
    }
    Get-Job | Wait-Job | Out-Null

    # Wait 2 minutes for machines to go available in AVD
    Start-Sleep -Seconds 120
    Write-Output "All new hosts have accelerated networking enabled"
    $acceleratedNetworkingEnabled = $true
  }
}
#endregion

#region Enable new hosts
if ($poolAvailable -eq $true) {
  Write-Output "Allowing sessions to connect to new hosts"
  foreach ($newSessionHost in $newSessionHosts) {
    $newVMName = $newSessionHost.Split(".")[0]
    Update-AzWvdSessionHost -ResourceGroupName $resourceGroupName -HostPoolName $hostpool.Name -Name $newSessionHost -AllowNewSession:$true -ErrorAction SilentlyContinue | Out-Null
    $vm = Get-AzVM | Where-Object { $_.Name -eq $newVmName }
    $vmTags = @{}
    $vmTags += $vm.Tags
    $vmTags | ForEach-Object { $_.VMMaintenance = "False"; $_ } | Out-Null
    Update-AzVM -VM $vm -ResourceGroupName $vm.ResourceGroupName -Tag $vmTags | Out-Null
  }
}
#endregion

#region Old Hosts
if ($poolAvailable -eq $true) {
  # Remove template parameter file
  Remove-Item $updateHostpoolParametersFilePath

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

    # Offboard original hosts from Defender for Endpoint if required
    if ($dfeAutoOffboard -eq $true) {

      # Get bearer token
      $dfeApi = 'https://api.securitycenter.microsoft.com'
      $oAuthUri = "https://login.microsoftonline.com/$dfeTenantId/oauth2/token"
      $authBody = [Ordered] @{
        resource      = "$dfeApi"
        client_id     = "$dfeAppId"
        client_secret = "$dfeAppSecret"
        grant_type    = 'client_credentials'
      }
      $authResponse = Invoke-RestMethod -Method Post -Uri $oAuthUri -Body $authBody -ErrorAction Continue
      $token = $authResponse.access_token

      # Create Offboarding headers
      $offboardheaders = @{
        "Authorization" = "Bearer $token"
        "Content-Type"  = "application/json"
      }
      $offboardBody = @{ "Comment" = "automation_AVDUpdateHostPool_Runbook automated offboarding" } | ConvertTo-Json

      # Get all machines from Defender for Endpoint
      $headers = @{Authorization = "Bearer $token" }
      $machines = Invoke-RestMethod -Method Get -Uri 'https://api.securitycenter.microsoft.com/api/machines' -Headers $headers
      $machines = $machines.value
      $machines = $machines | Select-Object id, computerDnsName

      # Offboard machines
      foreach ($originalHost in $originalSessionHosts) {
        $vmName = $originalHost.Split(".")[0]
        $machineIds = $machines | Where-Object { ($_.computerDnsName -eq $originalHost) -or ($_.computerDnsName -eq $vmName) }
        foreach ($machineId in $machineIds) {
          $id = $machineId.id
          try {
            $offboardUri = "https://api.securitycenter.microsoft.com/api/machines/$id/offboard"
            Invoke-RestMethod -Method Post -Uri $offboardUri -Headers $offboardheaders -Body $offboardBody | Out-Null
            Write-Output "Successfully requested offboarding of machine '$($machineId.computerDnsName)' with Id '$id' from Defender for Endpoint"
          }
          catch {
            Write-Output "Error requesting offboarding of machine '$($machineId.computerDnsName)' with Id '$id' from Defender for Endpoint. Code: $($_.Exception.Response.StatusCode.value__), Description: $($_.Exception.Response.StatusDescription)"
          }
        }
      }
    }

    # Remove original session hosts from host pool & domain
    Write-Output "Starting removal of all original session hosts..."
    $domainRemovalSuccess = $false
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
    $domainRemovalSuccess = $true

    Write-Output "Removing original hosts from Azure..."
    $azureRemovalSuccess = $false
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
    $azureRemovalSuccess = $true
    Write-Output "Host pool '$($hostpool.Name)' has been updated successfully"
  }
}
#endregion

#region Output results
# Convert boolean values to json
$poolDeploymentSuccessful = $poolDeploymentSuccessful | ConvertTo-Json
$poolAvailable = $poolAvailable | ConvertTo-Json
$gpuNVidia = $gpuNVidia | ConvertTo-Json
$gpuAMD = $gpuAMD | ConvertTo-Json
$acceleratedNetworkingEnabled = $acceleratedNetworkingEnabled | ConvertTo-Json
$domainRemovalSuccess = $domainRemovalSuccess | ConvertTo-Json
$azureRemovalSuccess = $azureRemovalSuccess | ConvertTo-Json
$rollbackTriggered = $rollbackTriggered | ConvertTo-Json

# Post data to Log Analytics
Write-Output "Posting data to Log Analytics"

$logMessage = @{ 
  hostPoolName_s                 = $hostpool.Name;
  resourceGroupName_s            = $resourceGroupName;
  updateType_s                   = $updateType;  
  hostsDeployedSuccess_b         = $poolDeploymentSuccessful;
  hostsAvailableSuccess_b        = $poolAvailable;
  gpuNVidiaDeployed_b            = $gpuNVidia;
  gpuAMDDeployed_b               = $gpuAMD;
  acceleratedNetworkingEnabled_b = $acceleratedNetworkingEnabled;
  domainRemovalSuccess_b         = $domainRemovalSuccess;
  azureRemovalSuccess_b          = $azureRemovalSuccess;
  rollbackTriggered_b            = $rollbackTriggered;
  bistechGUID_g                  = $bistechGUID
}
Add-LogEntry -LogMessageObj $logMessage -LogAnalyticsWorkspaceId $logAnalyticsWorkspaceId -LogAnalyticsPrimaryKey $logAnalyticsPrimaryKey -LogType $logName
#endregion
