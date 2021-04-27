<# 
.SYNOPSIS
    This script calculates WVD cost savings for a hostpool from using Bistech Automation 

.DESCRIPTION
    This script will gather billing information for the VM's within a hostpool (resource group) and calculate the customer cost savings achieved by using Bistech's
    Automation product. It will also compare using automation to reserved instances so you can track if moving to reserved instances would be more cost effective based
    on the customers usage hours.

.NOTES
    Author  : Dave Pierson
    Version : 1.4.0

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
    $webHookName = $webHookData.WebhookName
    $webHookHeaders = $webHookData.RequestHeader
    $webHookBody = $webHookData.RequestBody

    # Collect individual headers. Input converted from JSON.
    $from = $webHookHeaders.From
    $input = (ConvertFrom-Json -InputObject $webHookBody)
}
else {
    Write-Error -Message "Runbook was not started from it's Webhook so the script was terminated" -ErrorAction Stop
}

# Set variables from WebHook body objects
$aadTenantId = $Input.AADTenantId
$subscriptionID = $Input.SubscriptionID
$resourceGroupName = $Input.ResourceGroupName
$logAnalyticsWorkspaceId = $Input.LogAnalyticsWorkspaceId
$logAnalyticsPrimaryKey = $Input.LogAnalyticsPrimaryKey
$connectionAssetName = $Input.ConnectionAssetName
$hostpoolName = $Input.HostPoolName
$vmDiskType = $Input.VmDiskType

# Set Log Analytics log name
$logName = 'WVDCostAnalysisTest2_CL'

Set-ExecutionPolicy -ExecutionPolicy Undefined -Scope Process -Force -Confirm:$false
Set-ExecutionPolicy -ExecutionPolicy Unrestricted -Scope LocalMachine -Force -Confirm:$false

# Set ErrorActionPreference to stop script execution when error occurs
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
  
# Retrieve the RunAs account credentials from the Azure Automation Account Assets
$connection = Get-AutomationConnection -Name $ConnectionAssetName
  
# Authenticate to Azure 
Clear-AzContext -Force
$azAuthentication = Connect-AzAccount -ApplicationId $connection.ApplicationId -TenantId $aadTenantId -CertificateThumbprint $connection.CertificateThumbprint -ServicePrincipal
if ($azAuthentication -eq $null) {
    Write-Error "Failed to authenticate to Azure using the Automation Account $($_.exception.message)"
} 
else {
    Write-Output "Successfully authenticated to Azure using the Automation Account"
}
  
# Set the Azure context with Subscription
$azContext = Set-AzContext -SubscriptionId $subscriptionID
if ($azContext -eq $null) {
    Write-Error "Subscription ID '$subscriptionID' does not exist. Ensure that you have entered the correct values in the automation settings file"
} 
else {
    Write-Output "Set the Azure Context to the subscription named '$($azContext.Subscription.Name)' with Id '$($azContext.Subscription.Id)'"
}

# Get the appropriate VM size from querying the VMs in the resource group
$vms = Get-AzVM -ResourceGroupName $resourceGroupName
$vmSize = $vms | Select-Object -First 1
$vmLocation = $vmSize.Location
$vmSize = $vmSize.HardwareProfile.VmSize
$skuName = $vmSize -replace 'Standard_'
$skuName = $skuName -replace '_', ' '

# Get the disk tier from querying the disks in the resource group
$diskSize = Get-AzDisk -ResourceGroupName $resourceGroupName | Select-Object -First 1
$diskSize = $diskSize.Tier -replace "[^0-9]"
$standardHDD = 'S' + $diskSize + ' Disks'
$standardSSD = 'E' + $diskSize + ' Disks'
$premiumSSD = 'P' + $diskSize + ' Disks'
$diskTiers = @($standardHDD, $standardSSD, $premiumSSD)
$retailDiskPrices = @()

# Get Azure price list for disks matching VM disk tier
Write-Output "Retrieving Disk prices..."
foreach ($diskTier in $diskTiers) {
    try {
        $azureDiskSku = Invoke-WebRequest -Uri "https://prices.azure.com/api/retail/prices?`$filter=serviceFamily eq 'Storage' and armRegionName eq '$vmLocation' and meterName eq '$diskTier'" -UseBasicParsing
        $azureDiskSku = $azureDiskSku | ConvertFrom-Json
        $retailDiskPrices += $azureDiskSku.items
    }
    catch {
        Write-Error "An error was received from the endpoint whilst querying the Azure Retail Prices API so the script was terminated"
    }

    if (!$azureDiskSku.Items) {
        Write-Error "Azure Retail Prices API has not returned any data for disk type '$diskTier' in location '$vmLocation' and meter name '$diskTier' so the script was terminated"
    }
}

# Calculate hourly costs for Disk Tiers
$standardHDDCostUSD = $retailDiskPrices | Where-Object { $_.productName -eq 'Standard HDD Managed Disks' } | Select-Object -ExpandProperty unitPrice
$hourlyStandardHDDCostUSD = $standardHDDCostUSD / 730
$standardSSDCostUSD = $retailDiskPrices | Where-Object { $_.productName -eq 'Standard SSD Managed Disks' } | Select-Object -ExpandProperty unitPrice
$hourlyStandardSSDCostUSD = $standardSSDCostUSD / 730
$premiumSSDCostUSD = $retailDiskPrices | Where-Object { $_.productName -eq 'Premium SSD Managed Disks' } | Select-Object -ExpandProperty unitPrice
$hourlyPremiumSSDCostUSD = $premiumSSDCostUSD / 730

# Get Meter Id for each Disk Tier
$standardHDDMeterId = $retailDiskPrices | Where-Object { $_.productName -eq 'Standard HDD Managed Disks' } | Select-Object -ExpandProperty meterId
$standardSSDMeterId = $retailDiskPrices | Where-Object { $_.productName -eq 'Standard SSD Managed Disks' } | Select-Object -ExpandProperty meterId
$premiumSSDMeterId = $retailDiskPrices | Where-Object { $_.productName -eq 'Premium SSD Managed Disks' } | Select-Object -ExpandProperty meterId

# Get Azure price list for all reserved VM instance SKUs matching VM size
Write-Output "Retrieving Reserved Instance prices for machine type '$vmSize'..."
try {
    $reservedAzurePriceSkus = Invoke-WebRequest -Uri "https://prices.azure.com/api/retail/prices?`$filter=armSkuName eq '$vmSize' and armRegionName eq '$vmLocation' and priceType eq 'Reservation' and skuName eq '$skuName'" -UseBasicParsing
    $reservedAzurePriceSkus = $reservedAzurePriceSkus | ConvertFrom-Json
}
catch {
    Write-Error "An error was received from the endpoint whilst querying the Azure Retail Prices API so the script was terminated"
}

if (!$reservedAzurePriceSkus.Items) {
    Write-Error "Azure Retail Prices API has not returned any data for machine type '$vmSize' in location '$vmLocation' with price type of 'Reservation' and SKU name '$skuName' so the script was terminated"
}

# Calculate hourly costs for reserved VM instances
$reservedVMCostUSD1YearTerm = $reservedAzurePriceSkus.Items | Where-Object { $_.reservationTerm -eq '1 Year' } | Select-Object -ExpandProperty retailPrice
$hourlyReservedCostUSD1YearTerm = $reservedVMCostUSD1YearTerm / 8760
$reservedVMCostUSD3YearTerm = $reservedAzurePriceSkus.Items | Where-Object { $_.reservationTerm -eq '3 Years' } | Select-Object -ExpandProperty retailPrice
$hourlyReservedCostUSD3YearTerm = $reservedVMCostUSD3YearTerm / 26280

# Get Azure price list for PAYG VM instances matching VM size
Write-Output "Retrieving PAYG prices for machine type '$vmSize'..."
try {
    $azurePrices = Invoke-WebRequest -Uri "https://prices.azure.com/api/retail/prices?`$filter=armSkuName eq '$vmSize' and armRegionName eq '$vmLocation' and priceType eq 'Consumption' and skuName eq '$skuName'" -UseBasicParsing
    $azurePrices = $azurePrices | ConvertFrom-Json
}
catch {
    Write-Error "An error was received from the endpoint whilst querying the Azure Retail Prices API so the script was terminated"
}

if (!$azurePrices.Items) {
    Write-Error "Azure Retail Prices API has not returned any data for machine type '$vmSize' in location '$vmLocation' with price type of 'Consumption' and SKU name '$skuName' so the script was terminated"
}

# Get meter id associated (using Linux pricing due to WVD)
$meterId = $azurePrices.Items | Where-Object { $_.productName -NotLike '*Windows' -and $_.serviceName -eq 'Virtual Machines' -and $_.serviceFamily -eq 'Compute' } | Select-Object -ExpandProperty meterId
$retailHourlyPriceUSD = $azurePrices.Items | Where-Object { $_.productName -NotLike '*Windows' -and $_.serviceName -eq 'Virtual Machines' -and $_.serviceFamily -eq 'Compute' } | Select-Object -ExpandProperty unitPrice

# Set billing day to day before yesterday
$yesterday = (Get-Date).AddDays(-2)
$billingDay = Get-Date $yesterday -Format yyyy-MM-dd

# Get token for API call
$azContext = Get-AzContext
$subscriptionId = $azContext.Subscription.Id
$azProfile = [Microsoft.Azure.Commands.Common.Authentication.Abstractions.AzureRmProfileProvider]::Instance.Profile
$profileClient = New-Object -TypeName Microsoft.Azure.Commands.ResourceManager.Common.RMProfileClient -ArgumentList ($azProfile)
$token = $profileClient.AcquireAccessToken($azContext.Subscription.TenantId)
$authHeader = @{
    'Content-Type'  = 'application/json'
    'Authorization' = 'Bearer ' + $token.AccessToken
}

# Invoke the REST API and pull in billing data for previous day
Write-Output "Retrieving billing data for billing day $billingDay..."
$billingUri = "https://management.azure.com/subscriptions/$subscriptionId/providers/Microsoft.Consumption/usageDetails?`startDate=$billingDay&endDate=$billingDay&api-version=2019-10-01"
try {
    $billingInfo = Invoke-WebRequest -Uri $billingUri -Method Get -Headers $authHeader -UseBasicParsing
    $billingInfo = $billingInfo | ConvertFrom-Json
}
catch {
    Write-Error "An error was received from the endpoint whilst querying the Microsoft Consumption API so the script was terminated"
}

$vmCosts = @()
$vmCosts += $billingInfo.value.properties | Where-Object { $_.meterId -Like $meterId -and $_.resourceGroup -eq $resourceGroupName } | Select-Object date, instanceName, resourceGroupName, meterId, meterName, unitPrice, quantity, paygCostInUSD, paygCostInBillingCurrency, exchangeRate, reservationId, reservationName, term
$diskCosts = @()
$diskCosts += $billingInfo.value.properties | Where-Object { ($_.meterId -Like $standardHDDMeterId -or $_.meterId -Like $standardSSDMeterId -or $_.meterId -Like $premiumSSDMeterId) -and $_.resourceGroup -eq $resourceGroupName } | Select-Object date, instanceName, resourceGroupName, meterId, meterName, unitPrice, quantity, paygCostInUSD, paygCostInBillingCurrency, exchangeRate, reservationId, reservationName, term

while ($billingInfo.nextLink) {
    $nextLink = $billingInfo.nextLink
    try {
        $billingInfo = Invoke-WebRequest -Uri $nextLink -Method Get -Headers $authHeader -UseBasicParsing
        $billingInfo = $billingInfo | ConvertFrom-Json
    }
    catch {
        Write-Error "An error was received from the endpoint whilst querying the Microsoft Consumption API for the next page so the script was terminated"
    }
    $vmCosts += $billingInfo.value.properties | Where-Object { $_.meterId -Like $meterId -and $_.resourceGroup -eq $resourceGroupName } | Select-Object date, instanceName, resourceGroupName, meterId, meterName, unitPrice, quantity, paygCostInUSD, paygCostInBillingCurrency, exchangeRate, reservationId, reservationName, term
    $diskCosts += $billingInfo.value.properties | Where-Object { ($_.meterId -Like $standardHDDMeterId -or $_.meterId -Like $standardSSDMeterId -or $_.meterId -Like $premiumSSDMeterId) -and $_.resourceGroup -eq $resourceGroupName } | Select-Object date, instanceName, resourceGroupName, meterId, meterName, unitPrice, quantity, paygCostInUSD, paygCostInBillingCurrency, exchangeRate, reservationId, reservationName, term
}

# Check that billing data returned includes data for the machine type contained in resource group
if (!$vmCosts -and !$diskCosts) {
    Write-Error "No billing data has been returned for machine type '$vmSize' on $billingDay so the script was terminated"
}

# Check for any reserved instances of the machine type contained in resource group
Write-Output "Checking if any reserved instances of machine type '$vmSize' were applied to any VMs on date $billingDay..."
$reservedInstances1YearTerm = 0
$reservedInstances3YearTerm = 0
$appliedReservations = $vmCosts | Where-Object { $_.Term } | Select-Object date, instanceName, resourceGroupName, meterId, meterName, unitPrice, reservationId, reservationName, term
$appliedReservationsInstances = @()

if ($appliedReservations) {
    foreach ($appliedReservation in $appliedReservations) {
        if ($appliedReservation.Term -eq "1Year") { 
            $reservedInstances1YearTerm = $reservedInstances1YearTerm + 1
            $appliedReservationsInstances += $appliedReservation.instanceName
        }
        else { 
            $reservedInstances3YearTerm = $reservedInstances3YearTerm + 1
            $appliedReservationsInstances += $appliedReservation.instanceName
        }
    }
}
if ($reservedInstances1YearTerm) {
    Write-Output "Found x$reservedInstances1YearTerm 1-Year reserved instances were applied for machine type '$vmSize'"
}
if ($reservedInstances3YearTerm) {
    Write-Output "Found x$reservedInstances3YearTerm 3-Year reserved instances were applied for machine type '$vmSize'"
}
if (!$reservedInstances1YearTerm -and !$reservedInstances3YearTerm) {
    Write-Output "No reserved instances were applied for machine type '$vmSize'"
}

# Calculate usage hours to subtract from applied reserved instances
$reservedHoursToSubtract = 0
foreach ($appliedReservationsInstance in $appliedReservationsInstances) {

    $reservedHoursToSubtract = $vmCosts | Where-Object { $_.instanceName -eq $appliedReservationsInstance } | Select-Object quantity -ExpandProperty quantity
    $totalReservedHoursToSubtract = $totalReservedHoursToSubtract + $reservedHoursToSubtract
}

# Check correct exchange rate is available
$conversionRate = $vmCosts.exchangeRate | Sort-Object | Select-Object -First 1
            
# If all VMs have had reserved instances applied then exchange rate wont be correct and will show as 1. If so try and retrieve exchange rate from Log Analytics
if (!$conversionRate -or $conversionRate -eq 1) {
    Write-Warning "All VMs had reserved instances applied so the correct exchange rate has not been returned. Querying Log Analytics for latest exchange rate data..."
    $exchangeRateQuery = Invoke-AzOperationalInsightsQuery -WorkspaceId $logAnalyticsWorkspaceId -Query "$logName | where TimeGenerated > ago(31d)" -ErrorAction SilentlyContinue

    if (!$exchangeRateQuery) {
        Write-Warning "An error was received from the endpoint whilst querying Log Analytics. Cost analysis cannot be performed without the exchange rate so the script was terminated"
        Write-Warning "Error message: $($error[0].Exception.Message)"
    }
    $exchangeRateQuery = $exchangeRateQuery.Results | Sort-Object billingDay_s -Descending | Select-Object -First 1
    $conversionRate = $exchangeRateQuery.exchangeRate_d

    if (!$conversionRate -or $conversionRate -eq 1) {
        Write-Error "The exchange rate could not be found in either Billing or Log Analytics. Cost analysis cannot be performed without the exchange rate so the script was terminated"
    }
}

# Check correct hourly cost is available
$hourlyVMCostUSD = $vmCosts.unitPrice | Sort-Object | Select-Object -First 1

# If all VMs have had reserved instances applied then hourly cost will show as 0. If so set hourly cost returned from Retail Prices API
if (!$hourlyVMCostUSD) {
    $hourlyVMCostUSD = $retailHourlyPriceUSD
    Write-Warning "All VMs had reserved instances applied so the PAYG hourly cost for VM size '$vmSize' has not been returned. Setting hourly cost returned from Retail Prices API"
}

# Filter billing data for compute type and retrieve costs
Write-Output "Successfully retrieved billing data for date $billingDay, calculating costs..."
$hourlyVMCostBillingCurrency = $hourlyVMCostUSD * $conversionRate
$hourlyReservedCostBillingCurrency1YearTerm = $hourlyReservedCostUSD1YearTerm * $conversionRate
$hourlyReservedCostBillingCurrency3YearTerm = $hourlyReservedCostUSD3YearTerm * $conversionRate
$usageHours = $vmCosts.quantity | Measure-Object -Sum | Select-Object -ExpandProperty Sum
$billingDayComputeSpendUSD = $vmCosts.quantity | Measure-Object -Sum | Select-Object -ExpandProperty Sum
$billingDayComputeSpendUSD = $billingDayComputeSpendUSD - $totalReservedHoursToSubtract
$billingDayComputeSpendUSD = $billingDayComputeSpendUSD * $hourlyVMCostUSD
$billingDayComputeSpend = $billingDayComputeSpendUSD * $conversionRate

# Convert disk costs to billing currency
$hourlyStandardHDDCostBillingCurrency = $hourlyStandardHDDCostUSD * $conversionRate
$hourlyStandardSSDCostBillingCurrency = $hourlyStandardSSDCostUSD * $conversionRate
$hourlyPremiumSSDCostBillingCurrency = $hourlyPremiumSSDCostUSD * $conversionRate
$standardHDDCostBillingCurrency = $standardHDDCostUSD * $conversionRate
$standardSSDCostBillingCurrency = $standardSSDCostUSD * $conversionRate
$premiumSSDCostBillingCurrency = $premiumSSDCostUSD * $conversionRate

# Calculate daily costs for disks
$dailyStandardHDDCostUSD = $hourlyStandardHDDCostUSD * 24
$dailyStandardHDDCostBillingCurrency = $dailyStandardHDDCostUSD * $conversionRate
$dailyStandardSSDCostUSD = $hourlyStandardSSDCostUSD * 24
$dailyStandardSSDCostBillingCurrency = $dailyStandardSSDCostUSD * $conversionRate
$dailyPremiumSSDCostUSD = $hourlyPremiumSSDCostUSD * 24
$dailyPremiumSSDCostBillingCurrency = $dailyPremiumSSDCostUSD * $conversionRate

# Collect disk usage hours by Tier
foreach ($diskCost in $diskCosts) {
    if ($diskCost.meterId -eq $standardHDDMeterId) {
        $diskUsageHoursStandardHDD = $diskUsageHoursStandardHDD + $diskCost.quantity
    }
    if ($diskCost.meterId -eq $standardSSDMeterId) {
        $diskUsageHoursStandardSSD = $diskUsageHoursStandardSSD + $diskCost.quantity
    }
    if ($diskCost.meterId -eq $premiumSSDMeterId) {
        $diskUsageHoursPremiumSSD = $diskUsageHoursPremiumSSD + $diskCost.quantity 
    }
}

# Calculate disk usage costs by Tier
$diskUsageCostsStandardHDDUSD = $diskUsageHoursStandardHDD * $standardHDDCostUSD
$diskUsageCostsStandardHDDBillingCurrency = $diskUsageHoursStandardHDD * $standardHDDCostBillingCurrency
$diskUsageCostsStandardSSDUSD = $diskUsageHoursStandardSSD * $standardSSDCostUSD
$diskUsageCostsStandardSSDBillingCurrency = $diskUsageHoursStandardSSD * $standardSSDCostBillingCurrency
$diskUsagecostsPremiumSSDUSD = $diskUsageHoursPremiumSSD * $premiumSSDCostUSD
$diskUsagecostsPremiumSSDBillingCurrency = $diskUsageHoursPremiumSSD * $premiumSSDCostBillingCurrency

# Calculate total spend on disks
$billingDayDiskSpendUSD = $diskUsageCostsStandardHDDUSD + $diskUsageCostsStandardSSDUSD + $diskUsagecostsPremiumSSDUSD
$billingDayDiskSpendBillingCurrency = $billingDayDiskSpendUSD * $conversionRate

# Calculate daily costs for hosts running 24hours
$payGDailyRunHoursPriceUSD = $hourlyVMCostUSD * 24
$payGDailyRunHoursPriceBillingCurrency = $payGDailyRunHoursPriceUSD * $conversionRate
$dailyReservedHoursPriceUSD1YearTerm = $hourlyReservedCostUSD1YearTerm * 24
$dailyReservedHoursPriceBillingCurrency1YearTerm = $dailyReservedHoursPriceUSD1YearTerm * $conversionRate
$dailyReservedHoursPriceUSD3YearTerm = $hourlyReservedCostUSD3YearTerm * 24
$dailyReservedHoursPriceBillingCurrency3YearTerm = $dailyReservedHoursPriceUSD3YearTerm * $conversionRate

# Get VM count from hostpool and calculate hours runtime if all machines were powered on 24/7 - we have to use the Hostpool to enumerate vms
# rather than billing as powered off hosts will not show on the billing data due to no compute charge
$allVms = Get-AzWvdSessionHost -ResourceGroupName $resourceGroupName -HostPoolName $hostpoolName
$fullDailyRunHours = $allVms.Count * 24

# Get cost per VM and calculate recommendations for Reserved Instances
$vmCostTable = @()
foreach ($vm in $allVms) {
    $vmUsageHours = $vmCosts | Where-Object { $_.instanceName -eq $vm.ResourceId } | Select-Object instanceName, quantity, term

    if ($vmUsageHours) {
        if ($vmUsageHours.term -eq '1Year') {
            $vmCostUSD = $dailyReservedHoursPriceUSD1YearTerm
            $vmCostBillingCurrency = $dailyReservedHoursPriceBillingCurrency1YearTerm
            $vmCostTable += New-Object -TypeName psobject -Property @{instanceName = $vmUsageHours.instanceName; usageHours = $vmUsageHours.quantity; costUSD = $vmCostUSD; costBillingCurrency = $vmCostBillingCurrency }
        }
        elseif ($vmUsageHours.term -eq '3Years') {
            $vmCostUSD = $dailyReservedHoursPriceUSD3YearTerm
            $vmCostBillingCurrency = $dailyReservedHoursPriceBillingCurrency3YearTerm
            $vmCostTable += New-Object -TypeName psobject -Property @{instanceName = $vmUsageHours.instanceName; usageHours = $vmUsageHours.quantity; costUSD = $vmCostUSD; costBillingCurrency = $vmCostBillingCurrency }
        }
        else {
            $vmCostUSD = $vmUsageHours.quantity * $hourlyVMCostUSD
            $vmCostBillingCurrency = $vmCostUSD * $conversionRate
            $vmCostTable += New-Object -TypeName psobject -Property @{instanceName = $vmUsageHours.instanceName; usageHours = $vmUsageHours.quantity; costUSD = $vmCostUSD; costBillingCurrency = $vmCostBillingCurrency }
        }
    }
}

foreach ($vm in $allVms) {
    if ($vmCostTable.instanceName -notcontains $vm.ResourceId) {
        $vmName = $vm.ResourceId | Out-String
        $vmName = $vmName.Split("/")[8]
        $vmName = $vmName.Trim()
        $missingVm = $vm.ResourceId
        $vmCostTable += New-Object -TypeName psobject -Property @{instanceName = $missingVm; usageHours = 0; costUSD = 0; costBillingCurrency = 0 }
    }
}

$recommendedReserved1YearTerm = 0
$recommendedReserved3YearTerm = 0
$recommendedSavingsUSDReserved1YearTerm = 0
$recommendedSavingsUSDReserved3YearTerm = 0
$recommendedSavingsBillingCurrencyReserved1YearTerm = 0
$recommendedSavingsBillingCurrencyReserved3YearTerm = 0

foreach ($vmCost in $vmCostTable) {
    if ($vmCost.costUSD -ge $dailyReservedHoursPriceUSD1YearTerm) {
        $vmName = $vmCost.instanceName | Out-String
        $vmName = $vmName.Split("/")[8]
        $vmName = $vmName.Trim()
        $overSpendUSD = $vmCost.costUSD - $dailyReservedHoursPriceUSD1YearTerm
        $overSpendBillingCurrency = $vmCost.costBillingCurrency - $dailyReservedHoursPriceBillingCurrency1YearTerm
        $overSpendUSD = [math]::Round($overSpendUSD, 2)
        $overSpendBillingCurrency = [math]::Round($overSpendBillingCurrency, 2)
        $recommendedSavingsUSDReserved1YearTerm = $recommendedSavingsUSDReserved1YearTerm + $overSpendUSD
        $recommendedSavingsBillingCurrencyReserved1YearTerm = $recommendedSavingsBillingCurrencyReserved1YearTerm + $overSpendBillingCurrency
        $recommendedReserved1YearTerm = $recommendedReserved1YearTerm + 1
    }
    if ($vmCost.costUSD -ge $dailyReservedHoursPriceUSD3YearTerm) {
        $vmName = $vmCost.instanceName | Out-String
        $vmName = $vmName.Split("/")[8]
        $vmName = $vmName.Trim()
        $overSpendUSD = $vmCost.costUSD - $dailyReservedHoursPriceUSD3YearTerm
        $overSpendBillingCurrency = $vmCost.costBillingCurrency - $dailyReservedHoursPriceBillingCurrency3YearTerm
        $overSpendUSD = [math]::Round($overSpendUSD, 2)
        $overSpendBillingCurrency = [math]::Round($overSpendBillingCurrency, 2)
        $recommendedSavingsUSDReserved3YearTerm = $recommendedSavingsUSDReserved3YearTerm + $overSpendUSD
        $recommendedSavingsBillingCurrencyReserved3YearTerm = $recommendedSavingsBillingCurrencyReserved3YearTerm + $overSpendBillingCurrency
        $recommendedReserved3YearTerm = $recommendedReserved3YearTerm + 1
    }
}

# Calculate costs for all hosts running PAYG 24/7
$fullPAYGDailyRunHoursPriceUSD = $fullDailyRunHours * $hourlyVMCostUSD
$fullPAYGDailyRunHoursPriceBillingCurrency = $fullDailyRunHours * $hourlyVMCostBillingCurrency

# Calculate costs for all VMs running as Reserved Instances
$fullDailyReservedHoursPriceUSD1YearTerm = $fullDailyRunHours * $hourlyReservedCostUSD1YearTerm
$fullDailyReservedHoursPriceUSD3YearTerm = $fullDailyRunHours * $hourlyReservedCostUSD3YearTerm
$fullDailyReservedHoursPriceBillingCurrency1YearTerm = $fullDailyRunHours * $hourlyReservedCostBillingCurrency1YearTerm
$fullDailyReservedHoursPriceBillingCurrency3YearTerm = $fullDailyRunHours * $hourlyReservedCostBillingCurrency3YearTerm

# Calculate costs for applied Reserved Instances and add to Billing Spend
$billingCost1YearTermUSD = $reservedInstances1YearTerm * $hourlyReservedCostUSD1YearTerm * 24
$billingCost3YearTermUSD = $reservedInstances3YearTerm * $hourlyReservedCostUSD3YearTerm * 24
$billingCost1YearTermBillingCurrency = $reservedInstances1YearTerm * $hourlyReservedCostBillingCurrency1YearTerm * 24
$billingCost3YearTermBillingCurrency = $reservedInstances3YearTerm * $hourlyReservedCostBillingCurrency3YearTerm * 24
$billingDayComputeSpend = $billingDayComputeSpend + $billingCost1YearTermBillingCurrency + $billingCost3YearTermBillingCurrency
$billingDayComputeSpendUSD = $billingDayComputeSpendUSD + $billingCost1YearTermUSD + $billingCost3YearTermUSD 

# Calculate savings from applied Reserved Instances
$reservationSavings1YearTermUSD = (($hourlyVMCostUSD * 24) * $reservedInstances1YearTerm) - $billingCost1YearTermUSD
$reservationSavings3YearTermUSD = (($hourlyVMCostUSD * 24) * $reservedInstances3YearTerm) - $billingCost3YearTermUSD
$reservationSavings1YearTermBillingCurrency = (($hourlyVMCostBillingCurrency * 24) * $reservedInstances1YearTerm) - $billingCost1YearTermBillingCurrency
$reservationSavings3YearTermBillingCurrency = (($hourlyVMCostBillingCurrency * 24) * $reservedInstances3YearTerm) - $billingCost3YearTermBillingCurrency

# Calculate savings from auto-changing disk performance
if ($vmDiskType -eq 'Standard_LRS') {
    $diskSavingsUSD = 0
    $fullDailyDiskCostsUSD = $dailyStandardHDDCostUSD * $allVms.Count
} 
if ($vmDiskType -eq 'StandardSSD_LRS') {
    $diskSavingsUSD = ($dailyStandardSSDCostUSD * $allVms.Count) - $diskUsageCostsStandardSSDUSD + $diskUsageCostsStandardHDDUSD
    $fullDailyDiskCostsUSD = $dailyStandardSSDCostUSD * $allVms.Count
}
if ($vmDiskType -eq 'PremiumSSD_LRS') {
    $diskSavingsUSD = ($dailyPremiumSSDCostUSD * $allVms.Count) - $diskUsagecostsPremiumSSDUSD + $diskUsageCostsStandardHDDUSD
    $fullDailyDiskCostsUSD = $dailyPremiumSSDCostUSD * $allVms.Count
}
$diskSavingsBillingCurrency = $diskSavingsUSD * $conversionRate
$fullDailyDiskCostsBillingCurrency = $fullDailyDiskCostsUSD * $conversionRate

# Convert final figures to 2 decimal places
$fullPAYGDailyRunHoursPriceUSD = [math]::Round($fullPAYGDailyRunHoursPriceUSD, 2)
$fullPAYGDailyRunHoursPriceBillingCurrency = [math]::Round($fullPAYGDailyRunHoursPriceBillingCurrency, 2)
$fullDailyReservedHoursPriceUSD1YearTerm = [math]::Round($fullDailyReservedHoursPriceUSD1YearTerm, 2)
$fullDailyReservedHoursPriceUSD3YearTerm = [math]::Round($fullDailyReservedHoursPriceUSD3YearTerm, 2)
$fullDailyReservedHoursPriceBillingCurrency1YearTerm = [math]::Round($fullDailyReservedHoursPriceBillingCurrency1YearTerm, 2)
$fullDailyReservedHoursPriceBillingCurrency3YearTerm = [math]::Round($fullDailyReservedHoursPriceBillingCurrency3YearTerm, 2)
$billingCost1YearTermUSD = [math]::Round($billingCost1YearTermUSD, 2)
$billingCost3YearTermUSD = [math]::Round($billingCost3YearTermUSD, 2)
$billingCost1YearTermBillingCurrency = [math]::Round($billingCost1YearTermBillingCurrency, 2)
$billingCost3YearTermBillingCurrency = [math]::Round($billingCost3YearTermBillingCurrency, 2)
$billingDayComputeSpend = [math]::Round($billingDayComputeSpend, 2)
$billingDayComputeSpendUSD = [math]::Round($billingDayComputeSpendUSD, 2)
$reservationSavings1YearTermUSD = [math]::Round($reservationSavings1YearTermUSD, 2)
$reservationSavings3YearTermUSD = [math]::Round($reservationSavings3YearTermUSD, 2)
$reservationSavings1YearTermBillingCurrency = [math]::Round($reservationSavings1YearTermBillingCurrency, 2)
$reservationSavings3YearTermBillingCurrency = [math]::Round($reservationSavings3YearTermBillingCurrency, 2)
$diskSavingsUSD = [math]::Round($diskSavingsUSD, 2)
$diskSavingsBillingCurrency = [math]::Round($diskSavingsBillingCurrency, 2)
$billingDayDiskSpendUSD = [math]::Round($billingDayDiskSpendUSD, 2)
$billingDayDiskSpendBillingCurrency = [math]::Round($billingDayDiskSpendBillingCurrency, 2)
$fullDailyDiskCostsUSD = [math]::Round($fullDailyDiskCostsUSD, 2)
$fullDailyDiskCostsBillingCurrency = [math]::Round($fullDailyDiskCostsBillingCurrency, 2)

# Calculate total savings from Autoscaling + applied Reserved Instances
$automationHoursSaved = $fullDailyRunHours - $usageHours
$automationHoursSaved = [math]::Round($automationHoursSaved, 2)
$totalSavingsReservedInstancesUSD = $reservationSavings1YearTermUSD + $reservationSavings3YearTermUSD
$totalSavingsReservedInstancesBillingCurrency = $reservationSavings1YearTermBillingCurrency + $reservationSavings3YearTermBillingCurrency
$totalSavingsReservedInstancesBillingCurrency = [math]::Round($totalSavingsReservedInstancesBillingCurrency, 2)
$totalSavingsUSD = ($fullPAYGDailyRunHoursPriceUSD + $fullDailyDiskCostsUSD) - $billingDayComputeSpendUSD - $diskSavingsUSD
$totalSavingsBillingCurrency = ($fullPAYGDailyRunHoursPriceBillingCurrency + $fullDailyDiskCostsBillingCurrency) - $billingDayComputeSpend - $diskSavingsBillingCurrency

# Compare daily cost vs all VMs running as Reserved Instances
$allReservedSavings1YearTermUSD = $billingDayComputeSpendUSD - $fullDailyReservedHoursPriceUSD1YearTerm
$allReservedSavings3YearTermUSD = $billingDayComputeSpendUSD - $fullDailyReservedHoursPriceUSD3YearTerm
$allReservedSavings1YearTermBillingCurrency = $billingDayComputeSpend - $fullDailyReservedHoursPriceBillingCurrency1YearTerm
$allReservedSavings3YearTermBillingCurrency = $billingDayComputeSpend - $fullDailyReservedHoursPriceBillingCurrency3YearTerm

# Post data to Log Analytics
$logMessage = @{ 
    billingDay_s                                         = $billingDay;
    resourceGroupName_s                                  = $resourceGroupName;
    billingDayComputeSpendUSD_d                          = $billingDayComputeSpendUSD;
    billingDayComputeSpend_d                             = $billingDayComputeSpend;
    hoursSaved_d                                         = $automationHoursSaved; 
    savingsFromAppliedReservedInstancesUSD_d             = $totalSavingsReservedInstancesUSD;
    savingsFromAppliedReservedInstancesBillingCurrency_d = $totalSavingsReservedInstancesBillingCurrency;
    totalAutomationSavingsToPAYGUSD_d                    = $totalSavingsUSD;
    totalAutomationSavingsToPAYGBillingCurrency_d        = $totalSavingsBillingCurrency;
    ifAllReservedSavings1YearTermUSD_d                   = $allReservedSavings1YearTermUSD;
    ifAllReservedSavings3YearTermUSD_d                   = $allReservedSavings3YearTermUSD;
    ifAllReservedSavings1YearTermBillingCurrency_d       = $allReservedSavings1YearTermBillingCurrency;
    ifAllReservedSavings3YearTermBillingCurrency_d       = $allReservedSavings3YearTermBillingCurrency;
    usageHours_d                                         = $usageHours;
    hostPoolName_s                                       = $hostpoolName;
    exchangeRate_d                                       = $conversionRate;
    totalVms_d                                           = $allVms.Count;
    recommendedReserved1YearTerm_d                       = $recommendedReserved1YearTerm;
    recommendedReserved3YearTerm_d                       = $recommendedReserved3YearTerm;
    recommendedSavingsUSDReserved1YearTerm_d             = $recommendedSavingsUSDReserved1YearTerm;
    recommendedSavingsUSDReserved3YearTerm_d             = $recommendedSavingsUSDReserved3YearTerm;
    recommendedSavingsBillingCurrencyReserved1YearTerm_d = $recommendedSavingsBillingCurrencyReserved1YearTerm;
    recommendedSavingsBillingCurrencyReserved3YearTerm_d = $recommendedSavingsBillingCurrencyReserved3YearTerm;
    billingDayDiskSpendUSD_d                             = $billingDayDiskSpendUSD;
    billingDayDiskSpend_d                                = $billingDayDiskSpendBillingCurrency
}

Add-LogEntry -LogMessageObj $logMessage -LogAnalyticsWorkspaceId $logAnalyticsWorkspaceId -LogAnalyticsPrimaryKey $logAnalyticsPrimaryKey -LogType $logName
Write-Output "Posted cost analysis data for date $billingDay to Log Analytics"

# Check to see if any Cost Analysis logs are missing for the last 31 days
Write-Output "Checking for any missing cost analysis data in the last 31 days..."

# Query Log Analytics Cost Analysis log file for the last 31 days
$logAnalyticsQuery = Invoke-AzOperationalInsightsQuery -WorkspaceId $logAnalyticsWorkspaceId -Query "$logName | where TimeGenerated > ago(31d)" -ErrorAction SilentlyContinue

if (!$logAnalyticsQuery) {
    Write-Warning "An error was received from the endpoint whilst querying Log Analytics. Checks for any missing cost analysis data in the last 31 days will not be performed"
    Write-Warning "Error message: $($error[0].Exception.Message)"
}

if ($logAnalyticsQuery) {
    $loggedDays = $logAnalyticsQuery.Results.billingDay_s | foreach { Get-Date -Date $_ -Format yyyy-MM-dd }
    $startDate = -32
    $daysToCheck = $startDate..-3 | ForEach-Object { (Get-Date).AddDays($_).ToString('yyyy-MM-dd') }
    $missingDays = @()

    # Check for any missing days in Log Analytics Cost Analysis log file within the last 31 days
    foreach ($dayToCheck in $daysToCheck) {
        if ($loggedDays -notcontains $dayToCheck) {
            $missingDays += $dayToCheck
        }
    }

    # If there are any missing days then retrieve billing data for the missing days and post data to Log Analytics
    if ($missingDays) {
        foreach ($missingDay in $missingDays) {

            Write-Warning "Found no cost analysis data for date $missingDay. Retrieving billing data..."

            # Get token for API call
            $azContext = Get-AzContext
            $subscriptionId = $azContext.Subscription.Id
            $azProfile = [Microsoft.Azure.Commands.Common.Authentication.Abstractions.AzureRmProfileProvider]::Instance.Profile
            $profileClient = New-Object -TypeName Microsoft.Azure.Commands.ResourceManager.Common.RMProfileClient -ArgumentList ($azProfile)
            $token = $profileClient.AcquireAccessToken($azContext.Subscription.TenantId)
            $authHeader = @{
                'Content-Type'  = 'application/json'
                'Authorization' = 'Bearer ' + $token.AccessToken
            }
            # Invoke the REST API and pull in billing data for missing day
            $billingUri = "https://management.azure.com/subscriptions/$subscriptionId/providers/Microsoft.Consumption/usageDetails?`startDate=$missingDay&endDate=$missingDay&api-version=2019-10-01"
            try {
                $billingInfo = Invoke-WebRequest -Uri $billingUri -Method Get -Headers $authHeader -UseBasicParsing
                $billingInfo = $billingInfo | ConvertFrom-Json
            }
            catch {
                Write-Error "An error was received from the endpoint whilst querying the Microsoft Consumption API so the script was terminated"
            }

            $vmCosts = @()
            $vmCosts += $billingInfo.value.properties | Where-Object { $_.meterId -Like $meterId -and $_.resourceGroup -eq $resourceGroupName } | Select-Object date, instanceName, resourceGroupName, meterId, meterName, unitPrice, quantity, paygCostInUSD, paygCostInBillingCurrency, exchangeRate, reservationId, reservationName, term
            $diskCosts = @()
            $diskCosts += $billingInfo.value.properties | Where-Object { ($_.meterId -Like $standardHDDMeterId -or $_.meterId -Like $standardSSDMeterId -or $_.meterId -Like $premiumSSDMeterId) -and $_.resourceGroup -eq $resourceGroupName } | Select-Object date, instanceName, resourceGroupName, meterId, meterName, unitPrice, quantity, paygCostInUSD, paygCostInBillingCurrency, exchangeRate, reservationId, reservationName, term
            
            while ($billingInfo.nextLink) {
                $nextLink = $billingInfo.nextLink
                try {
                    $billingInfo = Invoke-WebRequest -Uri $nextLink -Method Get -Headers $authHeader -UseBasicParsing
                    $billingInfo = $billingInfo | ConvertFrom-Json
                }
                catch {
                    Write-Error "An error was received from the endpoint whilst querying the Microsoft Consumption API for the next page so the script was terminated"
                }
                $vmCosts += $billingInfo.value.properties | Where-Object { $_.meterId -Like $meterId -and $_.resourceGroup -eq $resourceGroupName } | Select-Object date, instanceName, resourceGroupName, meterId, meterName, unitPrice, quantity, paygCostInUSD, paygCostInBillingCurrency, exchangeRate, reservationId, reservationName, term
                $diskCosts += $billingInfo.value.properties | Where-Object { ($_.meterId -Like $standardHDDMeterId -or $_.meterId -Like $standardSSDMeterId -or $_.meterId -Like $premiumSSDMeterId) -and $_.resourceGroup -eq $resourceGroupName } | Select-Object date, instanceName, resourceGroupName, meterId, meterName, unitPrice, quantity, paygCostInUSD, paygCostInBillingCurrency, exchangeRate, reservationId, reservationName, term

            }

            if (!$vmCosts -and !$diskCosts) {
                Write-Output "No billing data was returned for machine type '$vmSize' on $missingDay so resource must have been created after this date"

                # Post blank set of data to Log Analytics so this missing day is not queried again
                $logMessage = @{ 
                    billingDay_s                                         = $missingDay;
                    resourceGroupName_s                                  = $resourceGroupName;
                    billingDayComputeSpendUSD_d                          = $null;
                    billingDayComputeSpend_d                             = $null;
                    hoursSaved_d                                         = $null; 
                    savingsFromAppliedReservedInstancesUSD_d             = $null;
                    savingsFromAppliedReservedInstancesBillingCurrency_d = $null;
                    totalAutomationSavingsToPAYGUSD_d                    = $null;
                    totalAutomationSavingsToPAYGBillingCurrency_d        = $null;
                    ifAllReservedSavings1YearTermUSD_d                   = $null;
                    ifAllReservedSavings3YearTermUSD_d                   = $null;
                    ifAllReservedSavings1YearTermBillingCurrency_d       = $null;
                    ifAllReservedSavings3YearTermBillingCurrency_d       = $null;
                    usageHours_d                                         = $null;
                    hostPoolName_s                                       = $hostpoolName;
                    exchangeRate_d                                       = $null;
                    totalVms_d                                           = $null;
                    recommendedReserved1YearTerm_d                       = $null;
                    recommendedReserved3YearTerm_d                       = $null;
                    recommendedSavingsUSDReserved1YearTerm_d             = $null;
                    recommendedSavingsUSDReserved3YearTerm_d             = $null;
                    recommendedSavingsBillingCurrencyReserved1YearTerm_d = $null;
                    recommendedSavingsBillingCurrencyReserved3YearTerm_d = $null;
                    billingDayDiskSpendUSD_d                             = $null;
                    billingDayDiskSpend_d                                = $null
                }
                Add-LogEntry -LogMessageObj $logMessage -LogAnalyticsWorkspaceId $logAnalyticsWorkspaceId -LogAnalyticsPrimaryKey $logAnalyticsPrimaryKey -LogType $logName
                continue
            }

            # Check for any reserved instances of the machine type contained in resource group
            Write-Output "Checking if any reserved instances of machine type '$vmSize' were applied to any VMs on date $missingDay..."
            $reservedInstances1YearTerm = 0
            $reservedInstances3YearTerm = 0
            $appliedReservations = $vmCosts | Where-Object { $_.Term } | Select-Object date, instanceName, resourceGroupName, meterId, meterName, unitPrice, reservationId, reservationName, term
            $appliedReservationsInstances = @()

            if ($appliedReservations) {
                foreach ($appliedReservation in $appliedReservations) {
                    if ($appliedReservation.Term -eq "1Year") { 
                        $reservedInstances1YearTerm = $reservedInstances1YearTerm + 1
                        $appliedReservationsInstances += $appliedReservation.instanceName
                    }
                    else { 
                        $reservedInstances3YearTerm = $reservedInstances3YearTerm + 1
                        $appliedReservationsInstances += $appliedReservation.instanceName
                    }
                }
            }
            if ($reservedInstances1YearTerm) {
                Write-Output "Found x$reservedInstances1YearTerm 1-Year reserved instances were applied for machine type '$vmSize'"
            }
            if ($reservedInstances3YearTerm) {
                Write-Output "Found x$reservedInstances3YearTerm 3-Year reserved instances were applied for machine type '$vmSize'"
            }
            if (!$reservedInstances1YearTerm -and !$reservedInstances3YearTerm) {
                Write-Output "No reserved instances were applied for machine type '$vmSize'"
            }

            # Calculate usage hours to subtract from applied reserved instances
            $reservedHoursToSubtract = 0
            foreach ($appliedReservationsInstance in $appliedReservationsInstances) {

                $reservedHoursToSubtract = $vmCosts | Where-Object { $_.instanceName -eq $appliedReservationsInstance } | Select-Object quantity -ExpandProperty quantity
                $totalReservedHoursToSubtract = $totalReservedHoursToSubtract + $reservedHoursToSubtract
            }

            # Check correct exchange rate is available
            $conversionRate = $vmCosts.exchangeRate | Sort-Object | Select-Object -First 1
            
            # If all VMs have had reserved instances applied then exchange rate wont be correct and will show as 1. If so try and retrieve exchange rate from Log Analytics
            if (!$conversionRate -or $conversionRate -eq 1) {
                Write-Warning "All VMs had reserved instances applied so the correct exchange rate has not been returned. Querying Log Analytics for latest exchange rate data..."
                $exchangeRateQuery = Invoke-AzOperationalInsightsQuery -WorkspaceId $logAnalyticsWorkspaceId -Query "$logName | where TimeGenerated > ago(31d)" -ErrorAction SilentlyContinue

                if (!$exchangeRateQuery) {
                    Write-Warning "An error was received from the endpoint whilst querying Log Analytics. Cost analysis cannot be performed without the exchange rate so the script was terminated"
                    Write-Warning "Error message: $($error[0].Exception.Message)"
                }
                $exchangeRateQuery = $exchangeRateQuery.Results | Sort-Object billingDay_s -Descending | Select-Object -First 1
                $conversionRate = $exchangeRateQuery.exchangeRate_d

                if (!$conversionRate -or $conversionRate -eq 1) {
                    Write-Error "The exchange rate could not be found in either Billing or Log Analytics. Cost analysis cannot be performed without the exchange rate so the script was terminated"
                }
            }

            # Check correct hourly cost is available
            $hourlyVMCostUSD = $vmCosts.unitPrice | Sort-Object | Select-Object -First 1

            # If all VMs have had reserved instances applied then hourly cost will show as 0. If so set hourly cost returned from Retail Prices API
            if (!$hourlyVMCostUSD) {
                $hourlyVMCostUSD = $retailHourlyPriceUSD
                Write-Warning "All VMs had reserved instances applied so the PAYG hourly cost for VM size '$vmSize' has not been returned. Setting hourly cost returned from Retail Prices API"
            }

            # Filter billing data for compute type and retrieve costs
            Write-Output "Successfully retrieved billing data for date $missingDay, calculating costs..."
            $hourlyVMCostBillingCurrency = $hourlyVMCostUSD * $conversionRate
            $hourlyReservedCostBillingCurrency1YearTerm = $hourlyReservedCostUSD1YearTerm * $conversionRate
            $hourlyReservedCostBillingCurrency3YearTerm = $hourlyReservedCostUSD3YearTerm * $conversionRate
            $usageHours = $vmCosts.quantity | Measure-Object -Sum | Select-Object -ExpandProperty Sum
            $billingDayComputeSpendUSD = $vmCosts.quantity | Measure-Object -Sum | Select-Object -ExpandProperty Sum
            $billingDayComputeSpendUSD = $billingDayComputeSpendUSD - $totalReservedHoursToSubtract
            $billingDayComputeSpendUSD = $billingDayComputeSpendUSD * $hourlyVMCostUSD
            $billingDayComputeSpend = $billingDayComputeSpendUSD * $conversionRate

            # Convert disk costs to billing currency
            $hourlyStandardHDDCostBillingCurrency = $hourlyStandardHDDCostUSD * $conversionRate
            $hourlyStandardSSDCostBillingCurrency = $hourlyStandardSSDCostUSD * $conversionRate
            $hourlyPremiumSSDCostBillingCurrency = $hourlyPremiumSSDCostUSD * $conversionRate
            $standardHDDCostBillingCurrency = $standardHDDCostUSD * $conversionRate
            $standardSSDCostBillingCurrency = $standardSSDCostUSD * $conversionRate
            $premiumSSDCostBillingCurrency = $premiumSSDCostUSD * $conversionRate

            # Calculate daily costs for disks
            $dailyStandardHDDCostUSD = $hourlyStandardHDDCostUSD * 24
            $dailyStandardHDDCostBillingCurrency = $dailyStandardHDDCostUSD * $conversionRate
            $dailyStandardSSDCostUSD = $hourlyStandardSSDCostUSD * 24
            $dailyStandardSSDCostBillingCurrency = $dailyStandardSSDCostUSD * $conversionRate
            $dailyPremiumSSDCostUSD = $hourlyPremiumSSDCostUSD * 24
            $dailyPremiumSSDCostBillingCurrency = $dailyPremiumSSDCostUSD * $conversionRate

            # Collect disk usage hours by Tier
            foreach ($diskCost in $diskCosts) {
                if ($diskCost.meterId -eq $standardHDDMeterId) {
                    $diskUsageHoursStandardHDD = $diskUsageHoursStandardHDD + $diskCost.quantity
                }
                if ($diskCost.meterId -eq $standardSSDMeterId) {
                    $diskUsageHoursStandardSSD = $diskUsageHoursStandardSSD + $diskCost.quantity
                }
                if ($diskCost.meterId -eq $premiumSSDMeterId) {
                    $diskUsageHoursPremiumSSD = $diskUsageHoursPremiumSSD + $diskCost.quantity 
                }
            }

            # Calculate disk usage costs by Tier
            $diskUsageCostsStandardHDDUSD = $diskUsageHoursStandardHDD * $standardHDDCostUSD
            $diskUsageCostsStandardHDDBillingCurrency = $diskUsageHoursStandardHDD * $standardHDDCostBillingCurrency
            $diskUsageCostsStandardSSDUSD = $diskUsageHoursStandardSSD * $standardSSDCostUSD
            $diskUsageCostsStandardSSDBillingCurrency = $diskUsageHoursStandardSSD * $standardSSDCostBillingCurrency
            $diskUsagecostsPremiumSSDUSD = $diskUsageHoursPremiumSSD * $premiumSSDCostUSD
            $diskUsagecostsPremiumSSDBillingCurrency = $diskUsageHoursPremiumSSD * $premiumSSDCostBillingCurrency

            # Calculate total spend on disks
            $billingDayDiskSpendUSD = $diskUsageCostsStandardHDDUSD + $diskUsageCostsStandardSSDUSD + $diskUsagecostsPremiumSSDUSD
            $billingDayDiskSpendBillingCurrency = $billingDayDiskSpendUSD * $conversionRate

            # Calculate daily costs for hosts running 24hours
            $payGDailyRunHoursPriceUSD = $hourlyVMCostUSD * 24
            $payGDailyRunHoursPriceBillingCurrency = $payGDailyRunHoursPriceUSD * $conversionRate
            $dailyReservedHoursPriceUSD1YearTerm = $hourlyReservedCostUSD1YearTerm * 24
            $dailyReservedHoursPriceBillingCurrency1YearTerm = $dailyReservedHoursPriceUSD1YearTerm * $conversionRate
            $dailyReservedHoursPriceUSD3YearTerm = $hourlyReservedCostUSD3YearTerm * 24
            $dailyReservedHoursPriceBillingCurrency3YearTerm = $dailyReservedHoursPriceUSD3YearTerm * $conversionRate

            # Get VM count from hostpool and calculate hours runtime if all machines were powered on 24/7 - we have to use the Hostpool to enumerate vms
            # rather than billing as powered off hosts will not show on the billing data due to no compute charge
            $allVms = Get-AzWvdSessionHost -ResourceGroupName $resourceGroupName -HostPoolName $hostpoolName
            $fullDailyRunHours = $allVms.Count * 24

            # Get cost per VM and calculate recommendations for Reserved Instances
            $vmCostTable = @()
            foreach ($vm in $allVms) {
                $vmUsageHours = $vmCosts | Where-Object { $_.instanceName -eq $vm.ResourceId } | Select-Object instanceName, quantity, term

                if ($vmUsageHours) {
                    if ($vmUsageHours.term -eq '1Year') {
                        $vmCostUSD = $dailyReservedHoursPriceUSD1YearTerm
                        $vmCostBillingCurrency = $dailyReservedHoursPriceBillingCurrency1YearTerm
                        $vmCostTable += New-Object -TypeName psobject -Property @{instanceName = $vmUsageHours.instanceName; usageHours = $vmUsageHours.quantity; costUSD = $vmCostUSD; costBillingCurrency = $vmCostBillingCurrency }
                    }
                    elseif ($vmUsageHours.term -eq '3Years') {
                        $vmCostUSD = $dailyReservedHoursPriceUSD3YearTerm
                        $vmCostBillingCurrency = $dailyReservedHoursPriceBillingCurrency3YearTerm
                        $vmCostTable += New-Object -TypeName psobject -Property @{instanceName = $vmUsageHours.instanceName; usageHours = $vmUsageHours.quantity; costUSD = $vmCostUSD; costBillingCurrency = $vmCostBillingCurrency }
                    }
                    else {
                        $vmCostUSD = $vmUsageHours.quantity * $hourlyVMCostUSD
                        $vmCostBillingCurrency = $vmCostUSD * $conversionRate
                        $vmCostTable += New-Object -TypeName psobject -Property @{instanceName = $vmUsageHours.instanceName; usageHours = $vmUsageHours.quantity; costUSD = $vmCostUSD; costBillingCurrency = $vmCostBillingCurrency }
                    }
                }
            }

            foreach ($vm in $allVms) {
                if ($vmCostTable.instanceName -notcontains $vm.ResourceId) {
                    $vmName = $vm.ResourceId | Out-String
                    $vmName = $vmName.Split("/")[8]
                    $vmName = $vmName.Trim()
                    $missingVm = $vm.ResourceId
                    $vmCostTable += New-Object -TypeName psobject -Property @{instanceName = $missingVm; usageHours = 0; costUSD = 0; costBillingCurrency = 0 }
                }
            }

            $recommendedReserved1YearTerm = 0
            $recommendedReserved3YearTerm = 0
            $recommendedSavingsUSDReserved1YearTerm = 0
            $recommendedSavingsUSDReserved3YearTerm = 0
            $recommendedSavingsBillingCurrencyReserved1YearTerm = 0
            $recommendedSavingsBillingCurrencyReserved3YearTerm = 0
            
            foreach ($vmCost in $vmCostTable) {
                if ($vmCost.costUSD -ge $dailyReservedHoursPriceUSD1YearTerm) {
                    $vmName = $vmCost.instanceName | Out-String
                    $vmName = $vmName.Split("/")[8]
                    $vmName = $vmName.Trim()
                    $overSpendUSD = $vmCost.costUSD - $dailyReservedHoursPriceUSD1YearTerm
                    $overSpendBillingCurrency = $vmCost.costBillingCurrency - $dailyReservedHoursPriceBillingCurrency1YearTerm
                    $overSpendUSD = [math]::Round($overSpendUSD, 2)
                    $overSpendBillingCurrency = [math]::Round($overSpendBillingCurrency, 2)
                    $recommendedSavingsUSDReserved1YearTerm = $recommendedSavingsUSDReserved1YearTerm + $overSpendUSD
                    $recommendedSavingsBillingCurrencyReserved1YearTerm = $recommendedSavingsBillingCurrencyReserved1YearTerm + $overSpendBillingCurrency
                    $recommendedReserved1YearTerm = $recommendedReserved1YearTerm + 1
                }
                if ($vmCost.costUSD -ge $dailyReservedHoursPriceUSD3YearTerm) {
                    $vmName = $vmCost.instanceName | Out-String
                    $vmName = $vmName.Split("/")[8]
                    $vmName = $vmName.Trim()
                    $overSpendUSD = $vmCost.costUSD - $dailyReservedHoursPriceUSD3YearTerm
                    $overSpendBillingCurrency = $vmCost.costBillingCurrency - $dailyReservedHoursPriceBillingCurrency3YearTerm
                    $overSpendUSD = [math]::Round($overSpendUSD, 2)
                    $overSpendBillingCurrency = [math]::Round($overSpendBillingCurrency, 2)
                    $recommendedSavingsUSDReserved3YearTerm = $recommendedSavingsUSDReserved3YearTerm + $overSpendUSD
                    $recommendedSavingsBillingCurrencyReserved3YearTerm = $recommendedSavingsBillingCurrencyReserved3YearTerm + $overSpendBillingCurrency
                    $recommendedReserved3YearTerm = $recommendedReserved3YearTerm + 1
                }
            }

            # Calculate costs for PAYG 24/7 running
            $fullPAYGDailyRunHoursPriceUSD = $fullDailyRunHours * $hourlyVMCostUSD
            $fullPAYGDailyRunHoursPriceBillingCurrency = $fullDailyRunHours * $hourlyVMCostBillingCurrency

            # Calculate costs for all VMs running as Reserved Instances
            $fullDailyReservedHoursPriceUSD1YearTerm = $fullDailyRunHours * $hourlyReservedCostUSD1YearTerm
            $fullDailyReservedHoursPriceUSD3YearTerm = $fullDailyRunHours * $hourlyReservedCostUSD3YearTerm
            $fullDailyReservedHoursPriceBillingCurrency1YearTerm = $fullDailyRunHours * $hourlyReservedCostBillingCurrency1YearTerm
            $fullDailyReservedHoursPriceBillingCurrency3YearTerm = $fullDailyRunHours * $hourlyReservedCostBillingCurrency3YearTerm

            # Calculate costs for applied Reserved Instances and add to Billing Spend
            $billingCost1YearTermUSD = $reservedInstances1YearTerm * $hourlyReservedCostUSD1YearTerm * 24
            $billingCost3YearTermUSD = $reservedInstances3YearTerm * $hourlyReservedCostUSD3YearTerm * 24
            $billingCost1YearTermBillingCurrency = $reservedInstances1YearTerm * $hourlyReservedCostBillingCurrency1YearTerm * 24
            $billingCost3YearTermBillingCurrency = $reservedInstances3YearTerm * $hourlyReservedCostBillingCurrency3YearTerm * 24
            $billingDayComputeSpend = $billingDayComputeSpend + $billingCost1YearTermBillingCurrency + $billingCost3YearTermBillingCurrency
            $billingDayComputeSpendUSD = $billingDayComputeSpendUSD + $billingCost1YearTermUSD + $billingCost3YearTermUSD 

            # Calculate savings from applied Reserved Instances
            $reservationSavings1YearTermUSD = (($hourlyVMCostUSD * 24) * $reservedInstances1YearTerm) - $billingCost1YearTermUSD
            $reservationSavings3YearTermUSD = (($hourlyVMCostUSD * 24) * $reservedInstances3YearTerm) - $billingCost3YearTermUSD
            $reservationSavings1YearTermBillingCurrency = (($hourlyVMCostBillingCurrency * 24) * $reservedInstances1YearTerm) - $billingCost1YearTermBillingCurrency
            $reservationSavings3YearTermBillingCurrency = (($hourlyVMCostBillingCurrency * 24) * $reservedInstances3YearTerm) - $billingCost3YearTermBillingCurrency

            # Calculate savings from auto-changing disk performance
            if ($vmDiskType -eq 'Standard_LRS') {
                $diskSavingsUSD = 0
                $fullDailyDiskCostsUSD = $dailyStandardHDDCostUSD * $allVms.Count
            } 
            if ($vmDiskType -eq 'StandardSSD_LRS') {
                $diskSavingsUSD = ($dailyStandardSSDCostUSD * $allVms.Count) - $diskUsageCostsStandardSSDUSD + $diskUsageCostsStandardHDDUSD
                $fullDailyDiskCostsUSD = $dailyStandardSSDCostUSD * $allVms.Count
            }
            if ($vmDiskType -eq 'PremiumSSD_LRS') {
                $diskSavingsUSD = ($dailyPremiumSSDCostUSD * $allVms.Count) - $diskUsagecostsPremiumSSDUSD + $diskUsageCostsStandardHDDUSD
                $fullDailyDiskCostsUSD = $dailyPremiumSSDCostUSD * $allVms.Count
            }
            $diskSavingsBillingCurrency = $diskSavingsUSD * $conversionRate
            $fullDailyDiskCostsBillingCurrency = $fullDailyDiskCostsUSD * $conversionRate

            # Convert final figures to 2 decimal places
            $fullPAYGDailyRunHoursPriceUSD = [math]::Round($fullPAYGDailyRunHoursPriceUSD, 2)
            $fullPAYGDailyRunHoursPriceBillingCurrency = [math]::Round($fullPAYGDailyRunHoursPriceBillingCurrency, 2)
            $fullDailyReservedHoursPriceUSD1YearTerm = [math]::Round($fullDailyReservedHoursPriceUSD1YearTerm, 2)
            $fullDailyReservedHoursPriceUSD3YearTerm = [math]::Round($fullDailyReservedHoursPriceUSD3YearTerm, 2)
            $fullDailyReservedHoursPriceBillingCurrency1YearTerm = [math]::Round($fullDailyReservedHoursPriceBillingCurrency1YearTerm, 2)
            $fullDailyReservedHoursPriceBillingCurrency3YearTerm = [math]::Round($fullDailyReservedHoursPriceBillingCurrency3YearTerm, 2)
            $billingCost1YearTermUSD = [math]::Round($billingCost1YearTermUSD, 2)
            $billingCost3YearTermUSD = [math]::Round($billingCost3YearTermUSD, 2)
            $billingCost1YearTermBillingCurrency = [math]::Round($billingCost1YearTermBillingCurrency, 2)
            $billingCost3YearTermBillingCurrency = [math]::Round($billingCost3YearTermBillingCurrency, 2)
            $billingDayComputeSpend = [math]::Round($billingDayComputeSpend, 2)
            $billingDayComputeSpendUSD = [math]::Round($billingDayComputeSpendUSD, 2)
            $reservationSavings1YearTermUSD = [math]::Round($reservationSavings1YearTermUSD, 2)
            $reservationSavings3YearTermUSD = [math]::Round($reservationSavings3YearTermUSD, 2)
            $reservationSavings1YearTermBillingCurrency = [math]::Round($reservationSavings1YearTermBillingCurrency, 2)
            $reservationSavings3YearTermBillingCurrency = [math]::Round($reservationSavings3YearTermBillingCurrency, 2)
            $diskSavingsUSD = [math]::Round($diskSavingsUSD, 2)
            $diskSavingsBillingCurrency = [math]::Round($diskSavingsBillingCurrency, 2)
            $billingDayDiskSpendUSD = [math]::Round($billingDayDiskSpendUSD, 2)
            $billingDayDiskSpendBillingCurrency = [math]::Round($billingDayDiskSpendBillingCurrency, 2)
            $fullDailyDiskCostsUSD = [math]::Round($fullDailyDiskCostsUSD, 2)
            $fullDailyDiskCostsBillingCurrency = [math]::Round($fullDailyDiskCostsBillingCurrency, 2)

            # Calculate total savings from Autoscaling + applied Reserved Instances
            $automationHoursSaved = $fullDailyRunHours - $usageHours
            $automationHoursSaved = [math]::Round($automationHoursSaved, 2)
            $totalSavingsReservedInstancesUSD = $reservationSavings1YearTermUSD + $reservationSavings3YearTermUSD
            $totalSavingsReservedInstancesBillingCurrency = $reservationSavings1YearTermBillingCurrency + $reservationSavings3YearTermBillingCurrency
            $totalSavingsReservedInstancesBillingCurrency = [math]::Round($totalSavingsReservedInstancesBillingCurrency, 2)
            $totalSavingsUSD = ($fullPAYGDailyRunHoursPriceUSD + $fullDailyDiskCostsUSD) - $billingDayComputeSpendUSD - $diskSavingsUSD
            $totalSavingsBillingCurrency = ($fullPAYGDailyRunHoursPriceBillingCurrency + $fullDailyDiskCostsBillingCurrency) - $billingDayComputeSpend - $diskSavingsBillingCurrency

            # Compare daily cost vs all VMs running as Reserved Instances
            $allReservedSavings1YearTermUSD = $billingDayComputeSpendUSD - $fullDailyReservedHoursPriceUSD1YearTerm
            $allReservedSavings3YearTermUSD = $billingDayComputeSpendUSD - $fullDailyReservedHoursPriceUSD3YearTerm
            $allReservedSavings1YearTermBillingCurrency = $billingDayComputeSpend - $fullDailyReservedHoursPriceBillingCurrency1YearTerm
            $allReservedSavings3YearTermBillingCurrency = $billingDayComputeSpend - $fullDailyReservedHoursPriceBillingCurrency3YearTerm

            # Post data to Log Analytics
            $logMessage = @{ 
                billingDay_s                                         = $missingDay;
                resourceGroupName_s                                  = $resourceGroupName;
                billingDayComputeSpendUSD_d                          = $billingDayComputeSpendUSD;
                billingDayComputeSpend_d                             = $billingDayComputeSpend;
                hoursSaved_d                                         = $automationHoursSaved; 
                savingsFromAppliedReservedInstancesUSD_d             = $totalSavingsReservedInstancesUSD;
                savingsFromAppliedReservedInstancesBillingCurrency_d = $totalSavingsReservedInstancesBillingCurrency;
                totalAutomationSavingsToPAYGUSD_d                    = $totalSavingsUSD;
                totalAutomationSavingsToPAYGBillingCurrency_d        = $totalSavingsBillingCurrency;
                ifAllReservedSavings1YearTermUSD_d                   = $allReservedSavings1YearTermUSD;
                ifAllReservedSavings3YearTermUSD_d                   = $allReservedSavings3YearTermUSD;
                ifAllReservedSavings1YearTermBillingCurrency_d       = $allReservedSavings1YearTermBillingCurrency;
                ifAllReservedSavings3YearTermBillingCurrency_d       = $allReservedSavings3YearTermBillingCurrency;
                usageHours_d                                         = $usageHours;
                hostPoolName_s                                       = $hostpoolName;
                exchangeRate_d                                       = $conversionRate;
                totalVms_d                                           = $allVms.Count;
                recommendedReserved1YearTerm_d                       = $recommendedReserved1YearTerm;
                recommendedReserved3YearTerm_d                       = $recommendedReserved3YearTerm;
                recommendedSavingsUSDReserved1YearTerm_d             = $recommendedSavingsUSDReserved1YearTerm;
                recommendedSavingsUSDReserved3YearTerm_d             = $recommendedSavingsUSDReserved3YearTerm;
                recommendedSavingsBillingCurrencyReserved1YearTerm_d = $recommendedSavingsBillingCurrencyReserved1YearTerm;
                recommendedSavingsBillingCurrencyReserved3YearTerm_d = $recommendedSavingsBillingCurrencyReserved3YearTerm;
                billingDayDiskSpendUSD_d                             = $billingDayDiskSpendUSD;
                billingDayDiskSpend_d                                = $billingDayDiskSpendBillingCurrency
            }
            Add-LogEntry -LogMessageObj $logMessage -LogAnalyticsWorkspaceId $logAnalyticsWorkspaceId -LogAnalyticsPrimaryKey $logAnalyticsPrimaryKey -LogType $logName
            Write-Output "Posted cost analysis data for date $missingDay to Log Analytics"
        }
    }
    Write-Output "All WVD cost analysis data successfully posted to Log Analytics"
}