# Install Evergreen
Install-Module -Name Evergreen -Confirm:$false -Force
Import-Module -Name Evergreen

# Create directory for software download
$dirPath = "C:\Windows\Temp"
New-Item -Path $dirPath -Name "evergreenSoftware" -ItemType Directory
