<# 
.SYNOPSIS
    This script automates the deployment of Mitel resources 

.DESCRIPTION
    This script is designed to automate the deployment of Mitel resources into a subscription. It will deploy
    the following based on the parameters it is given

    * Resource Groups
      .Network
      .Application
      .DMZ
    * Network Resources
      .Virtual Network
      .Subnet - Application
      .Subnet - DMZ
      .Network Security Group - Application
      .Network Security Group - DMZ
    * Application Resources
      .MiVoice Business
      .MiCollab
      .MiContact Centre
      .IVR Server
      .SQL
      .MiVoice Call Recorder
    * DMZ Resources
      .MiVoice Border Gateway

.NOTES
    Author   Dave Pierson
    Version  1.0.1

    # THIS SOFTWARE IS PROVIDED AS IS AND ANY EXPRESS OR IMPLIED WARRANTIES 
    # INCLUDING BUT NOT LIMITED TO THE IMPLIED WARRANTIES OF MERCHANTABILITY 
    # AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL 
    # THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT INDIRECT 
    # INCIDENTAL SPECIAL EXEMPLARY OR CONSEQUENTIAL DAMAGES (INCLUDING BUT 
    # NOT LIMITED TO PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE 
    # DATA OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY 
    # THEORY OF LIABILITY WHETHER IN CONTRACT STRICT LIABILITY OR TORT 
    # (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE 
    # OF THIS SOFTWARE EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
#>

#region Parameters

Param(

  [Parameter(mandatory)]
  [string]$vaultName

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

#region Retrieve Secrets
Write-Output "Retrieving secrets from keyvault..."
$secrets = Get-AzKeyVaultSecret -VaultName $vaultName
$secrets | ForEach-Object { New-Variable -Name $_.name -Value (Get-AzKeyVaultSecret -VaultName $_.VaultName -Name $_.Name -AsPlainText) }
$mslPassword = ConvertTo-SecureString -String $mslPassword -AsPlainText -Force
$windowsPassword = ConvertTo-SecureString -String $windowsPassword -AsPlainText -Force
Write-Output "All secrets retrieved"

# Set values
$prefixCaps = $customerPrefix.ToUpper()
$privateDNSLinkName = $vnetName + '-link'
switch ($mivbVersion) {
  "9.4 SP1" { $mivbMSLVersion = "11.0-102.0" }
  "9.4" { $mivbMSLVersion = "11.0-93.0" }
  "9.3.0.19" { $mivbMSLVersion = "11.0-90.0" }
}
switch ($teleworkerMBGVersion) {
  "11.4.0.227" { $teleworkerMBGMSLVersion = "11.0-97.0" }
  "11.3.0.68" { $teleworkerMBGMSLVersion = "11.0-90.0" }
}
switch ($sipMBGVersion) {
  "11.4.0.227" { $sipMBGMSLVersion = "11.0-97.0" }
  "11.3.0.68" { $sipMBGMSLVersion = "11.0-90.0" }
}
[string]$username = "AzureAdmin"
$mslCreds = New-Object System.Management.Automation.PSCredential ($username, $mslPassword);
$windowsCreds = New-Object System.Management.Automation.PSCredential ($username, $windowsPassword);
$jobTimeout = 420
#endregion

#region Resource Groups
$vnetResourceGroup = Get-AzResourceGroup -Name $vnetResourceGroupName -ErrorAction SilentlyContinue
if (!$vnetResourceGroup) {
  New-AzResourceGroup -Name $vnetResourceGroupName -Location $location | Out-Null
  Write-Output "Virtual network resource group '$vnetResourceGroupName' created"
  $vnetResourceGroup = Get-AzResourceGroup -Name $vnetResourceGroupName
}
$applicationResourceGroup = Get-AzResourceGroup -Name $applicationResourceGroupName -ErrorAction SilentlyContinue
if (!$applicationResourceGroup) {
  New-AzResourceGroup -Name $applicationResourceGroupName -Location $location | Out-Null
  Write-Output "Application resource group '$applicationResourceGroupName' created"
  $applicationResourceGroup = Get-AzResourceGroup -Name $applicationResourceGroupName
}
$dmzResourceGroup = Get-AzResourceGroup -Name $dmzResourceGroupName -ErrorAction SilentlyContinue
if (!$dmzResourceGroup) {
  New-AzResourceGroup -Name $dmzResourceGroupName -Location $location | Out-Null
  Write-Output "DMZ resource group '$dmzResourceGroupName' created"
  $dmzResourceGroup = Get-AzResourceGroup -Name $dmzResourceGroupName
}
#endregion

#region Storage Account
$storageAccount = Get-AzStorageAccount | Where-Object { $_.StorageAccountName -eq $storageAccountName } -ErrorAction SilentlyContinue
if (!$storageAccount) {
  New-AzStorageAccount `
    -Name $storageAccountName `
    -ResourceGroupName $vnetResourceGroup.ResourceGroupName `
    -Location $location `
    -SkuName Standard_LRS `
    -Kind StorageV2 `
    -EnableHttpsTrafficOnly $true | Out-Null

  Write-Output "Storage account '$storageAccountName' created"
  $storageAccount = Get-AzStorageAccount | Where-Object { $_.StorageAccountName -eq $storageAccountName }
}
$storageKey = (Get-AzStorageAccountKey -ResourceGroupName $vnetResourceGroup.ResourceGroupName -Name $storageAccount.StorageAccountName)[0].Value
$context = New-AzStorageContext -StorageAccountName $storageAccount.StorageAccountName -StorageAccountKey $storageKey
#endregion

#region Network Security Groups
$intNSG = Get-AzNetworkSecurityGroup | Where-Object { $_.Name -eq $intNSGName } -ErrorAction SilentlyContinue
if (!$intNSG) {

  $ruleInt01 = New-AzNetworkSecurityRuleConfig `
    -Name "Bistech-AVD-RDP" `
    -Description "Bistech AVD NAT Gateway Public IP RDP" `
    -Protocol Tcp `
    -SourcePortRange "*" `
    -DestinationPortRange "3389" `
    -SourceAddressPrefix "20.68.12.245/32" `
    -DestinationAddressPrefix "*" `
    -Access Allow `
    -Priority 101 `
    -Direction Inbound

  $ruleInt02 = New-AzNetworkSecurityRuleConfig `
    -Name "Bistech-AVD-SSH" `
    -Description "Bistech AVD NAT Gateway Public IP SSH" `
    -Protocol Tcp `
    -SourcePortRange "*" `
    -DestinationPortRange "22" `
    -SourceAddressPrefix "20.68.12.245/32" `
    -DestinationAddressPrefix "*" `
    -Access Allow `
    -Priority 102 `
    -Direction Inbound

  $ruleInt03 = New-AzNetworkSecurityRuleConfig `
    -Name ($prefixCaps + '-Overload-HTTPS') `
    -Description "Customer Overload Public IP HTTPS" `
    -Protocol Tcp `
    -SourcePortRange "*" `
    -DestinationPortRange "443" `
    -SourceAddressPrefix $customerInternetIp `
    -DestinationAddressPrefix "*" `
    -Access Allow `
    -Priority 103 `
    -Direction Inbound

  $ruleInt04 = New-AzNetworkSecurityRuleConfig `
    -Name ($prefixCaps + '-Overload-HTTP') `
    -Description "Customer Overload Public IP HTTP" `
    -Protocol Tcp `
    -SourcePortRange "*" `
    -DestinationPortRange "80" `
    -SourceAddressPrefix $customerInternetIp `
    -DestinationAddressPrefix "*" `
    -Access Allow `
    -Priority 104 `
    -Direction Inbound

  $ruleInt05 = New-AzNetworkSecurityRuleConfig `
    -Name ($prefixCaps + '-Overload-MiCC') `
    -Description "Customer Overload Public IP MiCC" `
    -Protocol Tcp `
    -SourcePortRange "*" `
    -DestinationPortRange ("5024-5026", "5030", "7001", "7003", "8083-8084", "42440") `
    -SourceAddressPrefix $customerInternetIp `
    -DestinationAddressPrefix "*" `
    -Access Allow `
    -Priority 105 `
    -Direction Inbound

  $ruleInt06 = New-AzNetworkSecurityRuleConfig `
    -Name ($prefixCaps + '-Overload-MiVCR') `
    -Description "Customer Overload Public IP MiVCR" `
    -Protocol Tcp `
    -SourcePortRange "*" `
    -DestinationPortRange ("8767-8768") `
    -SourceAddressPrefix $customerInternetIp `
    -DestinationAddressPrefix "*" `
    -Access Allow `
    -Priority 106 `
    -Direction Inbound

  New-AzNetworkSecurityGroup `
    -Name $intNSGName `
    -ResourceGroupName $vnetResourceGroup.ResourceGroupName `
    -Location $location `
    -SecurityRules $ruleInt01, $ruleInt02, $ruleInt03, $ruleInt04, $ruleInt05, $ruleInt06 | Out-Null

  Write-Output "Network security group '$intNSGName' created"
  $intNSG = Get-AzNetworkSecurityGroup | Where-Object { $_.Name -eq $intNSGName }
}

$dmzNSG = Get-AzNetworkSecurityGroup | Where-Object { $_.Name -eq $dmzNSGName } -ErrorAction SilentlyContinue
if (!$dmzNSG) {

  $ruleDmz01 = New-AzNetworkSecurityRuleConfig `
    -Name "HTTP" `
    -Description "Needed for Let’s Encrypt certificate challenges" `
    -Protocol Tcp `
    -SourcePortRange "*" `
    -DestinationPortRange "80" `
    -SourceAddressPrefix "*" `
    -DestinationAddressPrefix "*" `
    -Access Allow `
    -Priority 101 `
    -Direction Inbound

  $ruleDmz02 = New-AzNetworkSecurityRuleConfig `
    -Name "HTTPS" `
    -Description "Web" `
    -Protocol Tcp `
    -SourcePortRange "*" `
    -DestinationPortRange "443" `
    -SourceAddressPrefix "*" `
    -DestinationAddressPrefix "*" `
    -Access Allow `
    -Priority 102 `
    -Direction Inbound

  $ruleDmz03 = New-AzNetworkSecurityRuleConfig `
    -Name "SAC" `
    -Description "53xx Application Interface (Legacy)" `
    -Protocol Tcp `
    -SourcePortRange "*" `
    -DestinationPortRange "3998" `
    -SourceAddressPrefix "*" `
    -DestinationAddressPrefix "*" `
    -Access Allow `
    -Priority 103 `
    -Direction Inbound

  $ruleDmz04 = New-AzNetworkSecurityRuleConfig `
    -Name "MIR-Replay-Media" `
    -Description "Search & replay clients (incl. Player, File Man for export, etc.) to the API server" `
    -Protocol Tcp `
    -SourcePortRange "*" `
    -DestinationPortRange "4000" `
    -SourceAddressPrefix "*" `
    -DestinationAddressPrefix "*" `
    -Access Allow `
    -Priority 104 `
    -Direction Inbound

  $ruleDmz05 = New-AzNetworkSecurityRuleConfig `
    -Name "MIR-Replay-Server"`
    -Description "Replay server port for replay in the web" `
    -Protocol Tcp `
    -SourcePortRange "*" `
    -DestinationPortRange "4040" `
    -SourceAddressPrefix "*" `
    -DestinationAddressPrefix "*" `
    -Access Allow `
    -Priority 105 `
    -Direction Inbound

  $ruleDmz06 = New-AzNetworkSecurityRuleConfig `
    -Name "AWV" `
    -Description "Use for Analog and Web Video Web Conferencing" `
    -Protocol Tcp `
    -SourcePortRange "*" `
    -DestinationPortRange "4443" `
    -SourceAddressPrefix "*" `
    -DestinationAddressPrefix "*" `
    -Access Allow `
    -Priority 106 `
    -Direction Inbound

  $ruleDmz07 = New-AzNetworkSecurityRuleConfig `
    -Name "MIR-Client-Command" `
    -Description "CLIENTcommand to the API server (control channel)" `
    -Protocol Tcp `
    -SourcePortRange "*" `
    -DestinationPortRange "4711" `
    -SourceAddressPrefix "*" `
    -DestinationAddressPrefix "*" `
    -Access Allow `
    -Priority 107 `
    -Direction Inbound

  $ruleDmz08 = New-AzNetworkSecurityRuleConfig `
    -Name "SIP-SIP-TLS" `
    -Description "This is for SIP and SIP TLS" `
    -Protocol Tcp `
    -SourcePortRange "*" `
    -DestinationPortRange ("5060-5061") `
    -SourceAddressPrefix "*" `
    -DestinationAddressPrefix "*" `
    -Access Allow `
    -Priority 108 `
    -Direction Inbound

  $ruleDmz09 = New-AzNetworkSecurityRuleConfig `
    -Name "WebRTC" `
    -Description "This is for Web RTC" `
    -Protocol Tcp `
    -SourcePortRange "*" `
    -DestinationPortRange "5063" `
    -SourceAddressPrefix "*" `
    -DestinationAddressPrefix "*" `
    -Access Allow `
    -Priority 109 `
    -Direction Inbound

  $ruleDmz10 = New-AzNetworkSecurityRuleConfig `
    -Name "Minet" `
    -Description "Minet ports that need to be opened for signalling" `
    -Protocol Tcp `
    -SourcePortRange "*" `
    -DestinationPortRange ("6801-6802") `
    -SourceAddressPrefix "*" `
    -DestinationAddressPrefix "*" `
    -Access Allow `
    -Priority 110 `
    -Direction Inbound

  $ruleDmz11 = New-AzNetworkSecurityRuleConfig `
    -Name "IP-Console" `
    -Description "The ports that need to be opened for the IP Console" `
    -Protocol Tcp `
    -SourcePortRange "*" `
    -DestinationPortRange ("6806-6807") `
    -SourceAddressPrefix "*" `
    -DestinationAddressPrefix "*" `
    -Access Allow `
    -Priority 111 `
    -Direction Inbound

  $ruleDmz12 = New-AzNetworkSecurityRuleConfig `
    -Name "MBG-Clustering" `
    -Description "This port is being used for MBG Clustering over the internet" `
    -Protocol Tcp `
    -SourcePortRange "*" `
    -DestinationPortRange "6809" `
    -SourceAddressPrefix "*" `
    -DestinationAddressPrefix "*" `
    -Access Allow `
    -Priority 112 `
    -Direction Inbound

  $ruleDmz13 = New-AzNetworkSecurityRuleConfig `
    -Name "HTTPS-Phone-Avatar" `
    -Description "This port is being used for display Avatar on the phone" `
    -Protocol Tcp `
    -SourcePortRange "*" `
    -DestinationPortRange "6881" `
    -SourceAddressPrefix "*" `
    -DestinationAddressPrefix "*" `
    -Access Allow `
    -Priority 113 `
    -Direction Inbound

  $ruleDmz14 = New-AzNetworkSecurityRuleConfig `
    -Name "MICC-Port-Range1" `
    -Description "These ports are being used by MICC" `
    -Protocol Tcp `
    -SourcePortRange "*" `
    -DestinationPortRange ("35001-35008") `
    -SourceAddressPrefix "*" `
    -DestinationAddressPrefix "*" `
    -Access Allow `
    -Priority 114 `
    -Direction Inbound

  $ruleDmz15 = New-AzNetworkSecurityRuleConfig `
    -Name "MICC-Port-Range2" `
    -Description "These ports are being used by MICC" `
    -Protocol Tcp `
    -SourcePortRange "*" `
    -DestinationPortRange ("36000-36004") `
    -SourceAddressPrefix "*" `
    -DestinationAddressPrefix "*" `
    -Access Allow `
    -Priority 115 `
    -Direction Inbound

  $ruleDmz16 = New-AzNetworkSecurityRuleConfig `
    -Name "MiCollab-Client" `
    -Description "Used by MiCollab Client softphone" `
    -Protocol Tcp `
    -SourcePortRange "*" `
    -DestinationPortRange "36008" `
    -SourceAddressPrefix "*" `
    -DestinationAddressPrefix "*" `
    -Access Allow `
    -Priority 116 `
    -Direction Inbound

  $ruleDmz17 = New-AzNetworkSecurityRuleConfig `
    -Name "TFTP" `
    -Description "Used for TFTP" `
    -Protocol Udp `
    -SourcePortRange "*" `
    -DestinationPortRange "69" `
    -SourceAddressPrefix "*" `
    -DestinationAddressPrefix "*" `
    -Access Allow `
    -Priority 117 `
    -Direction Inbound

  $ruleDmz18 = New-AzNetworkSecurityRuleConfig `
    -Name "SIP" `
    -Description "Used for UDP SIP protocol" `
    -Protocol Udp `
    -SourcePortRange "*" `
    -DestinationPortRange "5060" `
    -SourceAddressPrefix "*" `
    -DestinationAddressPrefix "*" `
    -Access Allow `
    -Priority 118 `
    -Direction Inbound

  $ruleDmz19 = New-AzNetworkSecurityRuleConfig `
    -Name "TNA" `
    -Description "Used by the Telework Network Analyser tool" `
    -Protocol Udp `
    -SourcePortRange "*" `
    -DestinationPortRange "2000" `
    -SourceAddressPrefix "*" `
    -DestinationAddressPrefix "*" `
    -Access Allow `
    -Priority 119 `
    -Direction Inbound

  $ruleDmz20 = New-AzNetworkSecurityRuleConfig `
    -Name "Phone-TFTP" `
    -Description "Used by phones to TFTP their software loads" `
    -Protocol Udp `
    -SourcePortRange "*" `
    -DestinationPortRange "2001" `
    -SourceAddressPrefix "*" `
    -DestinationAddressPrefix "*" `
    -Access Allow `
    -Priority 120 `
    -Direction Inbound

  $ruleDmz21 = New-AzNetworkSecurityRuleConfig `
    -Name "Voice-SRTP" `
    -Description "Used for Voice SRTP" `
    -Protocol Udp `
    -SourcePortRange "*" `
    -DestinationPortRange ("20002-29999") `
    -SourceAddressPrefix "*" `
    -DestinationAddressPrefix "*" `
    -Access Allow `
    -Priority 121 `
    -Direction Inbound

  $ruleDmz22 = New-AzNetworkSecurityRuleConfig `
    -Name "Video-SRTP" `
    -Description "Used for Video SRTP" `
    -Protocol Udp `
    -SourcePortRange "*" `
    -DestinationPortRange ("30000-30999") `
    -SourceAddressPrefix "*" `
    -DestinationAddressPrefix "*" `
    -Access Allow `
    -Priority 122 `
    -Direction Inbound

  $ruleDmz23 = New-AzNetworkSecurityRuleConfig `
    -Name "WebRTC-Media" `
    -Description "Used for WebRTC Media" `
    -Protocol Udp `
    -SourcePortRange "*" `
    -DestinationPortRange ("32000-32499") `
    -SourceAddressPrefix "*" `
    -DestinationAddressPrefix "*" `
    -Access Allow `
    -Priority 123 `
    -Direction Inbound

  $ruleDmz24 = New-AzNetworkSecurityRuleConfig `
    -Name "GammaMedia" `
    -Description "Gamma Voice Traffic Range" `
    -Protocol Udp `
    -SourcePortRange "*" `
    -DestinationPortRange ("6000-40000") `
    -SourceAddressPrefix "151.2.128.0/19" `
    -DestinationAddressPrefix "*" `
    -Access Allow `
    -Priority 124 `
    -Direction Inbound

  New-AzNetworkSecurityGroup `
    -Name $dmzNSGName `
    -ResourceGroupName $vnetResourceGroup.ResourceGroupName `
    -Location $location `
    -SecurityRules $ruleDmz01, $ruleDmz02, $ruleDmz03, $ruleDmz04, $ruleDmz05, $ruleDmz06, $ruleDmz07, $ruleDmz08, $ruleDmz09, $ruleDmz10, $ruleDmz11, $ruleDmz12, $ruleDmz13, $ruleDmz14, $ruleDmz15, $ruleDmz16, $ruleDmz17, $ruleDmz18, $ruleDmz19, $ruleDmz20, $ruleDmz21, $ruleDmz22, $ruleDmz23, $ruleDmz24 | Out-Null

  Write-Output "Network security group '$dmzNSGName' created"
  $dmzNSG = Get-AzNetworkSecurityGroup  | Where-Object { $_.Name -eq $dmzNSGName }
}
#endregion

#region Virtual Network
$vnet = Get-AzVirtualNetwork -Name $vnetName -ResourceGroupName $vnetResourceGroupName -ErrorAction SilentlyContinue
if (!$vnet) {

  $intSubnet = New-AzVirtualNetworkSubnetConfig `
    -Name $intSubnetName `
    -AddressPrefix $intAddressSubnet `
    -NetworkSecurityGroupId $intNSG.Id -WarningAction Ignore

  $dmzSubnet = New-AzVirtualNetworkSubnetConfig `
    -Name $dmzSubnetName `
    -AddressPrefix $dmzAddressSubnet `
    -NetworkSecurityGroupId $dmzNSG.Id -WarningAction Ignore

  New-AzVirtualNetwork `
    -Name $vnetName `
    -ResourceGroupName $vnetResourceGroupName `
    -Location $location `
    -AddressPrefix $vnetAddressSpace `
    -Subnet $intSubnet, $dmzSubnet | Out-Null

  Write-Output "Virtual network '$vnetName' created"
  $vnet = Get-AzVirtualNetwork -Name $vnetName -ResourceGroupName $vnetResourceGroupName
}
$intSubnetId = ($vnet.Subnets | Where-Object { $_.Name -eq $intSubnetName }).Id
$dmzSubnetId = ($vnet.Subnets | Where-Object { $_.Name -eq $dmzSubnetName }).Id
#endregion

#region Private DNS Zone
$privateDNSZone = Get-AzPrivateDnsZone | Where-Object { $_.Name -eq $privateDNSZoneName } -ErrorAction SilentlyContinue
if (!$privateDNSZone) {

  New-AzPrivateDnsZone `
    -Name $privateDNSZoneName `
    -ResourceGroupName `
    $vnet.ResourceGroupName | Out-Null

  Write-Output "Private DNS zone '$privateDNSZoneName' created"
  $privateDNSZone = Get-AzPrivateDnsZone | Where-Object { $_.Name -eq $privateDNSZoneName }

  New-AzPrivateDnsVirtualNetworkLink `
    -Name $privateDNSLinkName `
    -ResourceGroupName $vnet.ResourceGroupName `
    -ZoneName $privateDNSZone.Name `
    -VirtualNetworkId $vnet.Id `
    -EnableRegistration | Out-Null

  Write-Output "Private DNS zone virtual link '$privateDNSLinkName' created"
}
#endregion

#region Transfer VHDs

#region MSL

# Create container
$container = Get-AzStorageContainer -Name "msl" -Context $context -ErrorAction SilentlyContinue
if (!$container) {
  New-AzStorageContainer -Name "msl" -Context $context | Out-Null
  Write-Output "Created container 'msl' in storage account '$storageAccountName'"
}

# Check existing container for VHDs
$mslVersionsTransferred = @()
$mslVersionsTransferredSanitized = @()
Get-AzStorageBlob -Container 'msl' -Context $context | ForEach-Object { $mslVersionsTransferred += $_.Name }
foreach ($version in $mslVersionsTransferred) {
  $versionName = $version -Replace '-1.vhd'
  $versionName = $versionName -Replace 'msl-'
  $mslVersionsTransferredSanitized += $versionName
}

# MiVB
if ($deployMivb -eq $true) {
  Write-Output "MSL version '$mivbMSLVersion' required for MiVB version '$mivbVersion'"
  if ($mslVersionsTransferredSanitized -notcontains $mivbMSLVersion) {
    $deployMSLUri = $deployUri + '/msl/msl-' + $mivbMSLVersion + '-1.vhd' + $deployUriSAS
    Write-Output "Copying MSL version '$mivbMSLVersion' to storage account now..."
    $destBlob = Start-AzStorageBlobCopy -AbsoluteUri $deployMSLUri -DestContainer "msl" -DestBlob ('msl-' + $mivbMSLVersion + '-1.vhd') -DestContext $context
    $destBlob | Get-AzStorageBlobCopyState -WaitForComplete | Out-Null
    $mslVersionsTransferredSanitized += $mivbMSLVersion
    Write-Output "Finished copying MSL version '$mivbMSLVersion' to storage account"
  }
  else {
    Write-Output "MSL version '$mivbMSLVersion' is already present in the storage account. Skipping download"
  }
  $mivbUri = $storageAccount.PrimaryEndpoints.Blob + 'msl/msl-' + $mivbMSLVersion + '-1.vhd'
}

# Teleworker MBG
if ($deployTeleworkerMBG -eq $true) {
  Write-Output "MSL version '$teleworkerMBGMSLVersion' required for Teleworker MBG version '$teleworkerMBGVersion'"
  if ($mslVersionsTransferredSanitized -notcontains $teleworkerMBGMSLVersion) {
    $deployMSLUri = $deployUri + '/msl/msl-' + $teleworkerMBGMSLVersion + '-1.vhd' + $deployUriSAS
    Write-Output "Copying MSL version '$teleworkerMBGMSLVersion' to storage account now..."
    $destBlob = Start-AzStorageBlobCopy -AbsoluteUri $deployMSLUri -DestContainer "msl" -DestBlob ('msl-' + $teleworkerMBGMSLVersion + '-1.vhd') -DestContext $context
    $destBlob | Get-AzStorageBlobCopyState -WaitForComplete | Out-Null
    $mslVersionsTransferredSanitized += $teleworkerMBGMSLVersion
    Write-Output "Finished copying MSL version '$teleworkerMBGMSLVersion' to storage account"
  }
  else {
    Write-Output "MSL version '$teleworkerMBGMSLVersion' is already present in the storage account. Skipping download"
  }
  $teleworkerMBGUri = $storageAccount.PrimaryEndpoints.Blob + 'msl/msl-' + $teleworkerMBGMSLVersion + '-1.vhd'
}

# SIP MBG
if ($deploySIPMBG -eq $true) {
  Write-Output "MSL version '$sipMBGMSLVersion' required for SIP MBG version '$sipMBGVersion'"
  if ($mslVersionsTransferredSanitized -notcontains $sipMBGMSLVersion) {
    $deployMSLUri = $deployUri + '/msl/msl-' + $sipMBGMSLVersion + '-1.vhd' + $deployUriSAS
    Write-Output "Copying MSL version '$sipMBGMSLVersion' to storage account now..."
    $destBlob = Start-AzStorageBlobCopy -AbsoluteUri $deployMSLUri -DestContainer "msl" -DestBlob ('msl-' + $sipMBGMSLVersion + '-1.vhd') -DestContext $context
    $destBlob | Get-AzStorageBlobCopyState -WaitForComplete | Out-Null
    $mslVersionsTransferredSanitized += $sipMBGMSLVersion
    Write-Output "Finished copying MSL version '$sipMBGMSLVersion' to storage account"
  }
  else {
    Write-Output "MSL version '$sipMBGMSLVersion' is already present in the storage account. Skipping download"
  }
  $sipMBGUri = $storageAccount.PrimaryEndpoints.Blob + 'msl/msl-' + $sipMBGMSLVersion + '-1.vhd'
}
#endregion

#region MiCollab

# Create container
$container = Get-AzStorageContainer -Name "micollab" -Context $context -ErrorAction SilentlyContinue
if (!$container) {
  New-AzStorageContainer -Name "micollab" -Context $context | Out-Null
  Write-Output "Created container 'micollab' in storage account '$storageAccountName'"
}

# Check existing container for VHDs
$micollabVersionsTransferred = @()
$micollabVersionsTransferredSanitized = @()
Get-AzStorageBlob -Container 'micollab' -Context $context | ForEach-Object { $micollabVersionsTransferred += $_.Name }
foreach ($version in $micollabVersionsTransferred) {
  $versionName = $version -Replace '-01.vhd'
  $versionName = $versionName -Replace 'micollab-'
  $micollabVersionsTransferredSanitized += $versionName
}

# MiCollab
if ($deployMicollab -eq $true) {
  Write-Output "MiCollab version '$micollabVersion' required"
  if ($micollabVersionsTransferredSanitized -notcontains $micollabVersion) {
    $deployMicollabUri = $deployUri + '/micollab/micollab-' + $micollabVersion + '-01.vhd' + $deployUriSAS
    Write-Output "Copying MiCollab version '$micollabVersion' to storage account now..."
    $destBlob = Start-AzStorageBlobCopy -AbsoluteUri $deployMicollabUri -DestContainer "micollab" -DestBlob ('micollab-' + $micollabVersion + '-01.vhd') -DestContext $context
    $destBlob | Get-AzStorageBlobCopyState -WaitForComplete | Out-Null
    $micollabVersionsTransferredSanitized += $micollabVersion
    Write-Output "Finished copying MiCollab version '$micollabVersion' to storage account"
  }
  else {
    Write-Output "MiCollab version '$micollabVersion' is already present in the storage account. Skipping download"
  }
  $micollabUri = $storageAccount.PrimaryEndpoints.Blob + 'micollab/micollab-' + $micollabVersion + '-01.vhd'
}
#endregion

#endregion

#region Application

#region MiVB
if ($deployMivb -eq $true) {

  # Create NIC
  $mivbLanNic = Get-AzNetworkInterface -Name $mivbLanNicName -ResourceGroupName $applicationResourceGroup.ResourceGroupName -ErrorAction SilentlyContinue
  if (!$mivbLanNic) {
    $mivbLanNic = New-AzNetworkInterface `
      -Name $mivbLanNicName `
      -ResourceGroupName $applicationResourceGroup.ResourceGroupName `
      -Location $location `
      -SubnetId $intSubnetId `
      -NetworkSecurityGroupId $intNSG.Id `
      -IpConfigurationName "ipconfig1" `
      -EnableAcceleratedNetworking

    Write-Output "MiVoice Business network interface '$mivbLanNicName' created"
  }

  # Create Image
  $image = Get-AzImage -Name $mivbImageName -ResourceGroupName $applicationResourceGroup.ResourceGroupName -ErrorAction SilentlyContinue
  if (!$image) {
    $imageConfig = New-AzImageConfig -Location $location
    Set-AzImageOsDisk -Image $imageConfig -OsType Linux -OsState Generalized -BlobUri $mivbUri -DiskSizeGB $mivbOSDiskSize | Out-Null
    $image = New-AzImage `
      -ImageName $mivbImageName `
      -Image $imageConfig `
      -ResourceGroupName $applicationResourceGroup.ResourceGroupName

    Write-Output "MiVoice Business image '$mivbImageName' created"
  }

  # Create VM Config
  $vm = Get-AzVM -Name $mivbName -ResourceGroupName $applicationResourceGroup.ResourceGroupName -ErrorAction SilentlyContinue
  if (!$vm) {
    $vmConfig = New-AzVMConfig -VMName $mivbName -VMSize $mivbVMSize
    $vmConfig = Set-AzVMOperatingSystem `
      -VM $vmConfig `
      -Linux `
      -ComputerName $mivbName `
      -Credential $mslCreds `
      -CustomData $customData
    $vmConfig = Add-AzVMNetworkInterface -VM $vmConfig -Id $mivbLanNic.Id -DeleteOption Detach
    $vmConfig = Set-AzVMSourceImage -VM $vmConfig -Id $image.Id
    $vmConfig = Set-AzVMOSDisk `
      -VM $vmConfig `
      -Name $mivbOsDiskName `
      -StorageAccountType Standard_LRS `
      -DiskSizeInGB $mivbOSDiskSize `
      -CreateOption FromImage `
      -Caching ReadWrite `
      -DeleteOption Detach
    $vmConfig = Set-AzVMBootDiagnostic `
      -VM $vmConfig `
      -Enable `
      -ResourceGroupName $vnet.ResourceGroupName `
      -StorageAccountName $storageAccount.StorageAccountName

    # Create VM
    $vm = New-AzVM `
      -ResourceGroupName $applicationResourceGroup.ResourceGroupName `
      -Location $location `
      -VM $vmConfig

    Write-Output "MiVoice Business VM '$mivbName' created"
  }
}
#endregion

#region MiCollab
if ($deployMicollab -eq $true) {

  # Create NIC
  $micollabLanNic = Get-AzNetworkInterface -Name $micollabLanNicName -ResourceGroupName $applicationResourceGroup.ResourceGroupName -ErrorAction SilentlyContinue
  if (!$micollabLanNic) {
    $micollabLanNic = New-AzNetworkInterface `
      -Name $micollabLanNicName `
      -ResourceGroupName $applicationResourceGroup.ResourceGroupName `
      -Location $location `
      -SubnetId $intSubnetId `
      -NetworkSecurityGroupId $intNSG.Id `
      -IpConfigurationName "ipconfig1" `
      -EnableAcceleratedNetworking

    Write-Output "MiCollab network interface '$micollabLanNicName' created"
  }

  # Create Image
  $image = Get-AzImage -Name $micollabImageName -ResourceGroupName $applicationResourceGroup.ResourceGroupName -ErrorAction SilentlyContinue
  if (!$image) {
    $imageConfig = New-AzImageConfig -Location $location
    Set-AzImageOsDisk -Image $imageConfig -OsType Linux -OsState Generalized -BlobUri $micollabUri -DiskSizeGB $micollabOSDiskSize | Out-Null
    $image = New-AzImage `
      -ImageName $micollabImageName `
      -Image $imageConfig `
      -ResourceGroupName $applicationResourceGroup.ResourceGroupName

    Write-Output "MiCollab image '$micollabImageName' created"
  }

  # Create VM Config
  $vm = Get-AzVM -Name $micollabName -ResourceGroupName $applicationResourceGroup.ResourceGroupName -ErrorAction SilentlyContinue
  if (!$vm) {
    $vmConfig = New-AzVMConfig -VMName $micollabName -VMSize $micollabVMSize
    $vmConfig = Set-AzVMOperatingSystem `
      -VM $vmConfig `
      -Linux `
      -ComputerName $micollabName `
      -Credential $mslCreds `
      -CustomData $customData
    $vmConfig = Add-AzVMNetworkInterface -VM $vmConfig -Id $micollabLanNic.Id -DeleteOption Detach
    $vmConfig = Set-AzVMSourceImage -VM $vmConfig -Id $image.Id
    $vmConfig = Set-AzVMOSDisk `
      -VM $vmConfig `
      -Name $micollabOsDiskName `
      -StorageAccountType Standard_LRS `
      -DiskSizeInGB $micollabOSDiskSize `
      -CreateOption FromImage `
      -Caching ReadWrite `
      -DeleteOption Detach
    $vmConfig = Set-AzVMBootDiagnostic `
      -VM $vmConfig `
      -Enable `
      -ResourceGroupName $vnet.ResourceGroupName `
      -StorageAccountName $storageAccount.StorageAccountName

    # Create VM
    $vm = New-AzVM `
      -ResourceGroupName $applicationResourceGroup.ResourceGroupName `
      -Location $location `
      -VM $vmConfig

    Write-Output "MiCollab VM '$micollabName' created"
  }
}
#endregion

#region MiCC
if ($deployMicc -eq $true) {

  # Create NIC
  $miccLanNic = Get-AzNetworkInterface -Name $miccLanNicName -ResourceGroupName $applicationResourceGroup.ResourceGroupName -ErrorAction SilentlyContinue
  if (!$miccLanNic) {
    $miccLanNic = New-AzNetworkInterface `
      -Name $miccLanNicName `
      -ResourceGroupName $applicationResourceGroup.ResourceGroupName `
      -Location $location `
      -SubnetId $intSubnetId `
      -NetworkSecurityGroupId $intNSG.Id `
      -IpConfigurationName "ipconfig1" `
      -EnableAcceleratedNetworking

    Write-Output "MiContact Centre network interface '$miccLanNicName' created"
  }

  # Create VM Config
  $vm = Get-AzVM -Name $miccName -ResourceGroupName $applicationResourceGroup.ResourceGroupName -ErrorAction SilentlyContinue
  if (!$vm) {
    $vmConfig = New-AzVMConfig -VMName $miccName -VMSize $miccVMSize
    $vmConfig = Set-AzVMOperatingSystem `
      -VM $vmConfig `
      -Windows `
      -ComputerName "micc" `
      -Credential $windowsCreds `
      -ProvisionVMAgent
    $vmConfig = Add-AzVMNetworkInterface -VM $vmConfig -Id $miccLanNic.Id -DeleteOption Detach
    $vmConfig = Set-AzVMSourceImage `
      -VM $vmConfig `
      -PublisherName "MicrosoftWindowsServer" `
      -Offer "WindowsServer" `
      -Skus $miccVersion `
      -Version "latest"
    $vmConfig = Set-AzVMSecurityProfile `
      -VM $vmConfig `
      -SecurityType TrustedLaunch
    $vmConfig = Set-AzVMUefi `
      -VM $vmConfig `
      -EnableVtpm $true `
      -EnableSecureBoot $true
    $vmConfig = Set-AzVMOSDisk `
      -VM $vmConfig `
      -Name $miccOsDiskName `
      -StorageAccountType Premium_LRS `
      -DiskSizeInGB $miccOSDiskSize `
      -CreateOption FromImage `
      -Caching ReadWrite `
      -DeleteOption Detach
    $vmConfig = Set-AzVMBootDiagnostic `
      -VM $vmConfig `
      -Enable `
      -ResourceGroupName $vnet.ResourceGroupName `
      -StorageAccountName $storageAccount.StorageAccountName

    # Create VM
    $vm = New-AzVM `
      -ResourceGroupName $applicationResourceGroup.ResourceGroupName `
      -Location $location `
      -VM $vmConfig

    Write-Output "MiContact Centre VM '$miccName' created"
  }
}
#endregion

#region SQL
if ($deploySQL -eq $true) {

  # Create NIC
  $sqlLanNic = Get-AzNetworkInterface -Name $sqlLanNicName -ResourceGroupName $applicationResourceGroup.ResourceGroupName -ErrorAction SilentlyContinue
  if (!$sqlLanNic) {
    $sqlLanNic = New-AzNetworkInterface `
      -Name $sqlLanNicName `
      -ResourceGroupName $applicationResourceGroup.ResourceGroupName `
      -Location $location `
      -SubnetId $intSubnetId `
      -NetworkSecurityGroupId $intNSG.Id `
      -IpConfigurationName "ipconfig1" `
      -EnableAcceleratedNetworking

    Write-Output "SQL Server network interface '$sqlLanNicName' created"
  }

  # Create VM Config
  $vm = Get-AzVM -Name $sqlName -ResourceGroupName $applicationResourceGroup.ResourceGroupName -ErrorAction SilentlyContinue
  if (!$vm) {
    $vmConfig = New-AzVMConfig -VMName $sqlName -VMSize $sqlVMSize
    $dataDiskConfig = New-AzDiskConfig `
      -SkuName StandardSSD_LRS `
      -Location $location `
      -CreateOption Empty `
      -DiskSizeGB $sqlDataDiskSize
    $sqlDataDisk = New-AzDisk `
      -DiskName $sqlDataDiskName `
      -Disk $dataDiskConfig `
      -ResourceGroupName $applicationResourceGroup.ResourceGroupName
    Write-Output "SQL Server data disk '$sqlDataDiskName' created"
    $vmConfig = Set-AzVMOperatingSystem `
      -VM $vmConfig `
      -Windows `
      -ComputerName "sql" `
      -Credential $windowsCreds `
      -ProvisionVMAgent
    $vmConfig = Add-AzVMNetworkInterface -VM $vmConfig -Id $sqlLanNic.Id -DeleteOption Detach
    $vmConfig = Set-AzVMSourceImage `
      -VM $vmConfig `
      -PublisherName "MicrosoftWindowsServer" `
      -Offer "WindowsServer" `
      -Skus $sqlVersion `
      -Version "latest"
    $vmConfig = Set-AzVMSecurityProfile `
      -VM $vmConfig `
      -SecurityType TrustedLaunch
    $vmConfig = Set-AzVMUefi `
      -VM $vmConfig `
      -EnableVtpm $true `
      -EnableSecureBoot $true
    $vmConfig = Set-AzVMOSDisk `
      -VM $vmConfig `
      -Name $sqlOsDiskName `
      -StorageAccountType Premium_LRS `
      -DiskSizeInGB $sqlOSDiskSize `
      -CreateOption FromImage `
      -Caching ReadWrite `
      -DeleteOption Detach
    $vmConfig = Add-AzVMDataDisk `
      -VM $vmConfig `
      -Name $sqlDataDiskName `
      -CreateOption Attach `
      -ManagedDiskId $sqlDataDisk.Id `
      -Lun 0
    $vmConfig = Set-AzVMBootDiagnostic `
      -VM $vmConfig `
      -Enable `
      -ResourceGroupName $vnet.ResourceGroupName `
      -StorageAccountName $storageAccount.StorageAccountName

    # Create VM
    $vm = New-AzVM `
      -ResourceGroupName $applicationResourceGroup.ResourceGroupName `
      -Location $location `
      -VM $vmConfig

    Write-Output "SQL Server VM '$sqlName' created"
  }
}
#endregion

#region IVR
if ($deployIVR -eq $true) {

  # Create NIC
  $ivrLanNic = Get-AzNetworkInterface -Name $ivrLanNicName -ResourceGroupName $applicationResourceGroup.ResourceGroupName -ErrorAction SilentlyContinue
  if (!$ivrLanNic) {
    $ivrLanNic = New-AzNetworkInterface `
      -Name $ivrLanNicName `
      -ResourceGroupName $applicationResourceGroup.ResourceGroupName `
      -Location $location `
      -SubnetId $intSubnetId `
      -NetworkSecurityGroupId $intNSG.Id `
      -IpConfigurationName "ipconfig1" `
      -EnableAcceleratedNetworking

    Write-Output "IVR Server network interface '$ivrLanNicName' created"
  }

  # Create VM Config
  $vm = Get-AzVM -Name $ivrName -ResourceGroupName $applicationResourceGroup.ResourceGroupName -ErrorAction SilentlyContinue
  if (!$vm) {
    $vmConfig = New-AzVMConfig -VMName $ivrName -VMSize $ivrVMSize
    $vmConfig = Set-AzVMOperatingSystem `
      -VM $vmConfig `
      -Windows `
      -ComputerName "ivr-01" `
      -Credential $windowsCreds `
      -ProvisionVMAgent
    $vmConfig = Add-AzVMNetworkInterface -VM $vmConfig -Id $ivrLanNic.Id -DeleteOption Detach
    $vmConfig = Set-AzVMSourceImage `
      -VM $vmConfig `
      -PublisherName "MicrosoftWindowsServer" `
      -Offer "WindowsServer" `
      -Skus $ivrVersion `
      -Version "latest"
    $vmConfig = Set-AzVMSecurityProfile `
      -VM $vmConfig `
      -SecurityType TrustedLaunch
    $vmConfig = Set-AzVMUefi `
      -VM $vmConfig `
      -EnableVtpm $true `
      -EnableSecureBoot $true
    $vmConfig = Set-AzVMOSDisk `
      -VM $vmConfig `
      -Name $ivrOsDiskName `
      -StorageAccountType Premium_LRS `
      -DiskSizeInGB $ivrOSDiskSize `
      -CreateOption FromImage `
      -Caching ReadWrite `
      -DeleteOption Detach
    $vmConfig = Set-AzVMBootDiagnostic `
      -VM $vmConfig `
      -Enable `
      -ResourceGroupName $vnet.ResourceGroupName `
      -StorageAccountName $storageAccount.StorageAccountName

    # Create VM
    $vm = New-AzVM `
      -ResourceGroupName $applicationResourceGroup.ResourceGroupName `
      -Location $location `
      -VM $vmConfig

    Write-Output "IVR Server VM '$ivrName' created"
  }
}
#endregion

#region MiVCR
if ($deployMivcr -eq $true) {

  # Create NIC
  $mivcrLanNic = Get-AzNetworkInterface -Name $mivcrLanNicName -ResourceGroupName $applicationResourceGroup.ResourceGroupName -ErrorAction SilentlyContinue
  if (!$mivcrLanNic) {
    $mivcrLanNic = New-AzNetworkInterface `
      -Name $mivcrLanNicName `
      -ResourceGroupName $applicationResourceGroup.ResourceGroupName `
      -Location $location `
      -SubnetId $intSubnetId `
      -NetworkSecurityGroupId $intNSG.Id `
      -IpConfigurationName "ipconfig1" `
      -EnableAcceleratedNetworking

    Write-Output "MiVoice Call Recorder network interface '$mivcrLanNicName' created"
  }

  # Create VM Config
  $vm = Get-AzVM -Name $mivcrName -ResourceGroupName $applicationResourceGroup.ResourceGroupName -ErrorAction SilentlyContinue
  if (!$vm) {
    $vmConfig = New-AzVMConfig -VMName $mivcrName -VMSize $mivcrVMSize
    $vmConfig = Set-AzVMOperatingSystem `
      -VM $vmConfig `
      -Windows `
      -ComputerName "mivcr" `
      -Credential $windowsCreds `
      -ProvisionVMAgent
    $vmConfig = Add-AzVMNetworkInterface -VM $vmConfig -Id $mivcrLanNic.Id -DeleteOption Detach
    $vmConfig = Set-AzVMSourceImage `
      -VM $vmConfig `
      -PublisherName "MicrosoftWindowsServer" `
      -Offer "WindowsServer" `
      -Skus $mivcrVersion `
      -Version "latest"
    $vmConfig = Set-AzVMSecurityProfile `
      -VM $vmConfig `
      -SecurityType TrustedLaunch
    $vmConfig = Set-AzVMUefi `
      -VM $vmConfig `
      -EnableVtpm $true `
      -EnableSecureBoot $true
    $vmConfig = Set-AzVMOSDisk `
      -VM $vmConfig `
      -Name $mivcrOsDiskName `
      -StorageAccountType Premium_LRS `
      -DiskSizeInGB $mivcrOSDiskSize `
      -CreateOption FromImage `
      -Caching ReadWrite `
      -DeleteOption Detach
    $vmConfig = Set-AzVMBootDiagnostic `
      -VM $vmConfig `
      -Enable `
      -ResourceGroupName $vnet.ResourceGroupName `
      -StorageAccountName $storageAccount.StorageAccountName

    # Create VM
    $vm = New-AzVM `
      -ResourceGroupName $applicationResourceGroup.ResourceGroupName `
      -Location $location `
      -VM $vmConfig

    Write-Output "MiVoice Call Recorder VM '$mivcrName' created"
  }
}
#endregion

#endregion

#region DMZ

#region MBG - Teleworker
if ($deployTeleworkerMBG -eq $true) {

  # Create NIC - LAN
  $teleworkerMBGLanNic = Get-AzNetworkInterface -Name $teleworkerMBGLanNicName -ResourceGroupName $dmzResourceGroup.ResourceGroupName -ErrorAction SilentlyContinue
  if (!$teleworkerMBGLanNic) {
    $teleworkerMBGLanNic = New-AzNetworkInterface `
      -Name $teleworkerMBGLanNicName `
      -ResourceGroupName $dmzResourceGroup.ResourceGroupName `
      -Location $location `
      -SubnetId $dmzSubnetId `
      -NetworkSecurityGroupId $dmzNSG.Id `
      -IpConfigurationName "ipconfig1" `
      -EnableAcceleratedNetworking

    Write-Output "Teleworker MiVoice Border Gateway LAN network interface '$teleworkerMBGLanNicName' created"
  }

  # Create NIC - DMZ
  $teleworkerMBGPublicIPAddress = Get-AzPublicIpAddress -Name $teleworkerMBGDMZPublicIPAddressName -ResourceGroupName $dmzResourceGroup.ResourceGroupName -ErrorAction SilentlyContinue
  if (!$teleworkerMBGPublicIPAddress) {
    $teleworkerMBGPublicIPAddress = New-AzPublicIpAddress `
      -Name $teleworkerMBGDMZPublicIPAddressName `
      -ResourceGroupName $dmzResourceGroup.ResourceGroupName `
      -Location $location `
      -AllocationMethod Static `
      -IpAddressVersion IPv4 `
      -Sku Basic `
      -IdleTimeoutInMinutes 4 `
      -WarningAction Ignore
  }

  $teleworkerMBGDMZNic = Get-AzNetworkInterface -Name $teleworkerMBGDMZNicName -ResourceGroupName $dmzResourceGroup.ResourceGroupName -ErrorAction SilentlyContinue
  if (!$teleworkerMBGDMZNic) {
    $teleworkerMBGDMZNic = New-AzNetworkInterface `
      -Name $teleworkerMBGDMZNicName `
      -ResourceGroupName $dmzResourceGroup.ResourceGroupName `
      -Location $location `
      -SubnetId $dmzSubnetId `
      -NetworkSecurityGroupId $dmzNSG.Id `
      -IpConfigurationName "ipconfig1" `
      -PublicIpAddressId $teleworkerMBGPublicIPAddress.Id

    Write-Output "Teleworker MiVoice Border Gateway DMZ network interface '$teleworkerMBGDMZNicName' created"
  }

  # Create Image
  $image = Get-AzImage -Name $teleworkerMBGImageName -ResourceGroupName $dmzResourceGroup.ResourceGroupName -ErrorAction SilentlyContinue
  if (!$image) {
    $imageConfig = New-AzImageConfig -Location $location
    Set-AzImageOsDisk -Image $imageConfig -OsType Linux -OsState Generalized -BlobUri $teleworkerMBGUri -DiskSizeGB $teleworkerMBGOSDiskSize | Out-Null
    $image = New-AzImage `
      -ImageName $teleworkerMBGImageName `
      -Image $imageConfig `
      -ResourceGroupName $dmzResourceGroup.ResourceGroupName

    Write-Output "Teleworker MiVoice Border Gateway image '$teleworkerMBGImageName' created"
  }

  # Create VM Config
  $vm = Get-AzVM -Name $teleworkerMBGName -ResourceGroupName $dmzResourceGroup.ResourceGroupName -ErrorAction SilentlyContinue
  if (!$vm) {
    $vmConfig = New-AzVMConfig -VMName $teleworkerMBGName -VMSize $teleworkerMBGVMSize
    $vmConfig = Set-AzVMOperatingSystem `
      -VM $vmConfig `
      -Linux `
      -ComputerName $teleworkerMBGName `
      -Credential $mslCreds `
      -CustomData $customData
    $vmConfig = Add-AzVMNetworkInterface -VM $vmConfig -Id $teleworkerMBGLanNic.Id -DeleteOption Detach -Primary
    $vmConfig = Add-AzVMNetworkInterface -VM $vmConfig -Id $teleworkerMBGDMZNic.Id -DeleteOption Detach
    $vmConfig = Set-AzVMSourceImage -VM $vmConfig -Id $image.Id
    $vmConfig = Set-AzVMOSDisk `
      -VM $vmConfig `
      -Name $teleworkerMBGOsDiskName `
      -StorageAccountType Standard_LRS `
      -DiskSizeInGB $teleworkerMBGOSDiskSize `
      -CreateOption FromImage `
      -Caching ReadWrite `
      -DeleteOption Detach
    $vmConfig = Set-AzVMBootDiagnostic `
      -VM $vmConfig `
      -Enable `
      -ResourceGroupName $vnet.ResourceGroupName `
      -StorageAccountName $storageAccount.StorageAccountName

    # Create VM
    $vm = New-AzVM `
      -ResourceGroupName $dmzResourceGroup.ResourceGroupName `
      -Location $location `
      -VM $vmConfig

    Write-Output "Teleworker MiVoice Border Gateway VM '$teleworkerMBGImageName' created"
  }
}
#endregion

#region MBG - SIP
if ($deploySIPMBG -eq $true) {

  # Create NIC - LAN
  $sipMBGLanNic = Get-AzNetworkInterface -Name $sipMBGLanNicName -ResourceGroupName $dmzResourceGroup.ResourceGroupName -ErrorAction SilentlyContinue
  if (!$sipMBGLanNic) {
    $sipMBGLanNic = New-AzNetworkInterface `
      -Name $sipMBGLanNicName `
      -ResourceGroupName $dmzResourceGroup.ResourceGroupName `
      -Location $location `
      -SubnetId $dmzSubnetId `
      -NetworkSecurityGroupId $dmzNSG.Id `
      -IpConfigurationName "ipconfig1" `
      -EnableAcceleratedNetworking

    Write-Output "SIP MiVoice Border Gateway LAN network interface '$sipMBGLanNicName' created"
  }

  # Create NIC - DMZ
  $sipMBGPublicIPAddress = Get-AzPublicIpAddress -Name $sipMBGDMZPublicIPAddressName -ResourceGroupName $dmzResourceGroup.ResourceGroupName -ErrorAction SilentlyContinue
  if (!$sipMBGPublicIPAddress) {
    $sipMBGPublicIPAddress = New-AzPublicIpAddress `
      -Name $sipMBGDMZPublicIPAddressName `
      -ResourceGroupName $dmzResourceGroup.ResourceGroupName `
      -Location $location `
      -AllocationMethod Static `
      -IpAddressVersion IPv4 `
      -Sku Basic `
      -IdleTimeoutInMinutes 4 `
      -WarningAction Ignore
  }

  $sipMBGDMZNic = Get-AzNetworkInterface -Name $sipMBGDMZNicName -ResourceGroupName $dmzResourceGroup.ResourceGroupName -ErrorAction SilentlyContinue
  if (!$sipMBGDMZNic) {
    $sipMBGDMZNic = New-AzNetworkInterface `
      -Name $sipMBGDMZNicName `
      -ResourceGroupName $dmzResourceGroup.ResourceGroupName `
      -Location $location `
      -SubnetId $dmzSubnetId `
      -NetworkSecurityGroupId $dmzNSG.Id `
      -IpConfigurationName "ipconfig1" `
      -PublicIpAddressId $sipMBGPublicIPAddress.Id

    Write-Output "SIP MiVoice Border Gateway DMZ network interface '$sipMBGDMZNicName' created"
  }

  # Create Image
  $image = Get-AzImage -Name $sipMBGImageName -ResourceGroupName $dmzResourceGroup.ResourceGroupName -ErrorAction SilentlyContinue
  if (!$image) {
    $imageConfig = New-AzImageConfig -Location $location
    Set-AzImageOsDisk -Image $imageConfig -OsType Linux -OsState Generalized -BlobUri $sipMBGUri -DiskSizeGB $sipMBGOSDiskSize | Out-Null
    $image = New-AzImage `
      -ImageName $sipMBGImageName `
      -Image $imageConfig `
      -ResourceGroupName $dmzResourceGroup.ResourceGroupName

    Write-Output "SIP MiVoice Border Gateway image '$sipMBGImageName' created"
  }

  # Create VM Config
  $vm = Get-AzVM -Name $sipMBGName -ResourceGroupName $dmzResourceGroup.ResourceGroupName -ErrorAction SilentlyContinue
  if (!$vm) {
    $vmConfig = New-AzVMConfig -VMName $sipMBGName -VMSize $sipMBGVMSize
    $vmConfig = Set-AzVMOperatingSystem `
      -VM $vmConfig `
      -Linux `
      -ComputerName $sipMBGName `
      -Credential $mslCreds `
      -CustomData $customData
    $vmConfig = Add-AzVMNetworkInterface -VM $vmConfig -Id $sipMBGLanNic.Id -DeleteOption Detach -Primary
    $vmConfig = Add-AzVMNetworkInterface -VM $vmConfig -Id $sipMBGDMZNic.Id -DeleteOption Detach
    $vmConfig = Set-AzVMSourceImage -VM $vmConfig -Id $image.Id
    $vmConfig = Set-AzVMOSDisk `
      -VM $vmConfig `
      -Name $sipMBGOsDiskName `
      -StorageAccountType Standard_LRS `
      -DiskSizeInGB $sipMBGOSDiskSize `
      -CreateOption FromImage `
      -Caching ReadWrite `
      -DeleteOption Detach
    $vmConfig = Set-AzVMBootDiagnostic `
      -VM $vmConfig `
      -Enable `
      -ResourceGroupName $vnet.ResourceGroupName `
      -StorageAccountName $storageAccount.StorageAccountName

    # Create VM
    $vm = New-AzVM `
      -ResourceGroupName $dmzResourceGroup.ResourceGroupName `
      -Location $location `
      -VM $vmConfig

    Write-Output "SIP MiVoice Border Gateway VM '$sipMBGImageName' created"
  }
}
#endregion

#endregion

#region Cleanup
Write-Output "Cleaning up images..."
if ($deployMivb -eq $true) {
  Remove-AzImage -ResourceGroupName $applicationResourceGroup.ResourceGroupName -ImageName $mivbImageName -Force -AsJob
}
if ($deployMicollab -eq $true) {
  Remove-AzImage -ResourceGroupName $applicationResourceGroup.ResourceGroupName -ImageName $micollabImageName -Force -AsJob
}
if ($deployTeleworkerMBG -eq $true) {
  Remove-AzImage -ResourceGroupName $dmzResourceGroup.ResourceGroupName -ImageName $teleworkerMBGImageName -Force -AsJob
}
if ($deploySIPMBG -eq $true) {
  Remove-AzImage -ResourceGroupName $dmzResourceGroup.ResourceGroupName -ImageName $sipMBGImageName -Force -AsJob
}
Get-Job | Wait-Job -Timeout $jobTimeout | Out-Null
Write-Output "Deployment complete"
#endregion