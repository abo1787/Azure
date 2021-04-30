# Windows Virtual Desktop AutoScaling


### Latest Release - v4.2.0
#### v4.2.0
##### New Features
###### * Custom Holiday Support - Custom holiday dates can now be specified.Host pools will be kept in Off-Peak mode when it's a Custom Holiday
##### Breaking Changes
###### * Parameters file now needs customHolidays (array)
---
#### v4.1.0
##### New Features
###### * UK Bank Holiday Support - Host pools can now be kept in Off-Peak mode when it's a UK Bank Holiday
##### Fixes
###### * Fixed an issue where last host wouldn't shut down if minimum number of hosts was set to 0
##### Breaking Changes
###### * Parameters file now needs observeUKBankHolidays (bool)
---
#### v4.0.0
##### New Features
###### * Disk cost optimization - VM disks will be changed to Standard HDD when powered off to save on storage costs. They will be changed to required performance tier when powered on
###### * Minimum Number of Hosts now supports being set to 0 - All hosts can be powered off in Off-Peak if required
###### * Scale Factor - This now uses session number rather than a percentage calculation making it easier to set and less error prone
##### Other
###### * Condensed and tidied Job outputs
###### * Various code optimizations
##### Breaking Changes
###### * Parameters file now needs vmDiskType (string)
###### * Parameters file Scale Factor variables now need to be number of sessions (int) rather than percentage of total sessions allowed
---
#### v3.2.1
##### Other
###### * Log Analytics log name changed to variable
---
#### v3.2.0
##### New Features
###### * Added daylight saving support
##### Breaking Changes
###### * Parameters file now needs timeZone (string) instead of timeDifferenceInHours
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
