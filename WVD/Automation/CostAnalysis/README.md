
# Azure Virtual Desktop Cost Analysis

### Latest Release - v1.6.9
#### v1.7.0
##### Fixes
###### * Fixed issue when multiple reserved instances were applied to the same VM
---
#### v1.6.9
##### Other
###### * Renamed to Azure Virtual Desktop
###### * Changed missing days to check for last 90 days instead of 30
---
#### v1.6.8
##### Other
###### * Added reserved instance hours metric to Log Analytics
---
#### v1.6.7
##### Fixes
###### * Fixed multiple issues with reserved instance calculations when a reserved instance was added to a host with PAYG usage as well
---
#### v1.6.6
##### Fixes
###### * Fixed an issue with Disk Savings not calculating correctly
###### * Fixed an issue with Automation vs Reserved Instances where it was not taking into account disk savings from automation
---
#### v1.6.5
##### New Features
###### * Automation Account now uses Managed Identity rather than Azure RunAs Account. No longer any need to renew certificate every 12 months
##### Fixes
###### * Fixed an issue with Disk Size where it sometimes return null
###### * Fixed an issue with Total Costs not totalling correctly
---
#### v1.6.4
##### New Features
###### * Bandwidth Costs - Costs will now be calculated for the VMs egress bandwidth
##### Other
###### * Increased number of metrics being written to Log Analytics
---
#### v1.5.0
##### New Features
###### * Missing Days - If any billing data is missing in Log Analytics for the last 31 days, cost analysis will be performed and missing data retrieved
---
#### v1.4.0
##### New Features
###### * Disk Costs - Costs will now be calculated for the VM managed disks. This works alongside AutoScaling where disk performance is changed on startup/shutdown of hosts in order to save costs on storage 
----
#### v1.3.3
##### New Features
###### * Reserved Instance Recommendations Cost Comparison - Added cost comparison alongside the reserved instance recommendations
##### Fixes
###### * Fixed total compute spend calculations where sometimes they wouldn't total correctly
###### * Fixed compute MeterId where it sometimes returned Cloud Services rather than Compute
##### Other
###### * Tidied logging so output is consistent
---
#### v1.2.0
##### New Features
###### * Reserved Instance Recommendations - Compute hours will be compared with reserved instances, outputting a recommended number of reserved instances to apply to enable maximum cost reduction for compute
---
#### v1.1.0
##### Fixes
###### * Fixed reserved instance cost calculations
##### Other
###### * Added fallback options for VMN cost and exchange rate
###### * Added additional error checking
---
#### v1.0.9
##### Fixes
###### * Changed Log Analytics query to warning on fail rather than error. This is expected to error on first run due to time for Log Analytics log file initial creation
---
#### v1.0.7
##### Fixes
###### * Added full error checking
---
#### v1.0.3
##### Fixes
###### * Fixed REST requests when used by Automation Account
##### Other
###### * Added additonal output
###### * Usage hours added to logging
---
#### v1.0.0
##### New Features
###### * Costs from compute 
###### * Comparison to running all hosts as reserved instances
