# Azure Virtual Desktop AutoScaling


### Latest Release - v5.0.3
#### v5.0.3
##### Other
###### * Added logging line to display host pool friendly name to make finding logs easier when using multiple host pools
---
#### v5.0.2
##### Fixes
###### * Changed Tag value collection to support host VMs having additional tags
---
#### v5.0.1
##### Fixes
###### * Fixed an issue with maintenance hosts showing -1 at peak start up
---
#### v5.0.0
##### New Features
###### * Complete code rewrite to enhance troubleshooting, execution and reduce duplication
###### * Execution time reduced by ~50%
##### Breaking Changes
###### * Parameters file now requires EnhancedLogging (boolean)
---
#### v4.4.1
##### Fixes
###### * Fixed an issue that caused a VM to yoyo stopping and starting between script runs when a certain condition was met
---
#### v4.4.0
##### Fixes
###### * Fixed an issue with excessive output when checking spare capacity
##### Other
###### * Reduced script run time by ~45%
---
#### v4.3.3
##### Fixes
###### * Fixed an issue with disk tiers not changing when StartVMOnConnect was turned off
##### Other
###### * Updated naming from WVD to AVD
---
#### v4.3.2
##### Other
###### * Added check for upcoming feature 'Start VM on Connect' - disks will not be resized to save costs if using this feature as 'Start on VM on Connect' feature is independent and will start the VM with Standard HDD if powered off by automation
---
#### v4.3.1
##### Other
###### * Added active & disconnected session reporting
---
#### v4.3.0
##### New Features
###### * Automation Account now uses Managed Identity rather than Azure RunAs Account. No longer any need to renew certificate every 12 months
##### Other
###### * Added error checking for holidays API
---
#### v4.2.0
##### New Features
###### * Custom Holiday Support - Custom holiday dates can now be specified. Host pools will be kept in Off-Peak mode when it's a Custom Holiday
##### Breaking Changes
###### * Parameters file now requires customHolidays (array)
---
#### v4.1.0
##### New Features
###### * UK Bank Holiday Support - Host pools can now be kept in Off-Peak mode when it's a UK Bank Holiday
##### Fixes
###### * Fixed an issue where last host wouldn't shut down if minimum number of hosts was set to 0
##### Breaking Changes
###### * Parameters file now requires observeUKBankHolidays (bool)
---
#### v4.0.0
##### New Features
###### * Disk cost optimization - VM disks will be changed to Standard HDD when powered off to save on storage costs. They will be changed to required performance tier when powered on
###### * Minimum Number of Hosts now supports being set to 0 - All hosts can be powered off if required
###### * Scale Factor - This now uses session number rather than a percentage calculation making it easier to set and less error prone
##### Other
###### * Condensed and tidied Job outputs
###### * Various code optimizations
##### Breaking Changes
###### * Parameters file now requires vmDiskType (string)
###### * Parameters file Scale Factor variables now required to be number of sessions (int) rather than percentage of total sessions allowed
---
#### v3.2.1
##### Other
###### * Log Analytics log name changed to variable
---
#### v3.2.0
##### New Features
###### * Added daylight saving support
##### Breaking Changes
###### * Parameters file now requires timeZone (string) instead of timeDifferenceInHours
---
#### v3.1.02
##### Fixes
###### * Log output field types changed to correct data types
##### Other
###### * Added resource group to log output for better query function
---
#### v3.1.01
##### New Features
###### * Log Analytics reporting is now combined into a single file for better query function
##### Fixes
###### * Removed blank logging lines from job output
##### Other
###### * Added additonal output
---
#### v3.0.20
##### Other
###### * Added synopsis, description and versioning
