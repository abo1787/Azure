# Microsoft Azure Windows Virtual Desktop

Windows Virtual Desktop is a desktop and app virtualization service that runs on the cloud

This repository contains scripts to create WVD Resources and deploy Automation

The 'Deploy to Azure' buttons shown below can be used to create these resources

#### Create Image VM
Creates a VM from a Marketplace Image and gives you options to customize it by installing M365 Apps, Teams (Machine-Wide Installer), OneDrive (Machine-Wide Installer), FSLogix and downloading the scripts and files required to set the system to UK rather than US

#### Install M365 Apps Standalone
Installs specified M365 Apps on an already provisioned VM. You have to choice to exclude certain Apps from being installed (Access, Publisher etc)

#### Install OneDrive Standalone
Installs the OneDrive Machine-Wide Installer on an already provisioned VM

#### Install Teams Standalone
Installs the Teams Machine-Wide Installer and Web-RTC AV redirection on an already provisioned VM. Sets the 'IsWVDEnvironment' registry key if it is a Multi-Session environment

#### Install FSLogix Standalone
Installs FSLogix on an already provisioned VM

#### Install UK Language Pack Standalone
Downloads the UK Language Packs and associated scripts to an already provisioned VM. Run the 'setLocaleUk' script on the desktop to complete the setup.

## Deploy to Azure buttons

Name | Description   | Auto-deploy   |
-----| ------------- |--------------- | 
| Create Image VM | Create a VM from a Marketplace Image and customize it with required software relevant to WVD | [![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2FBistech%2FAzure%2Fmaster%2FWVD%2FImage%2Fdeploy.json)
| Install M365 Apps Standalone | Install specified M365 Apps on an already provisioned VM | [![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2FBistech%2FAzure%2Fmaster%2FWVD%2FImage%2FinstallCustom365Apps.json)
| Install OneDrive Standalone | Install OneDrive Machine-Wide Installer on an already provisioned VM | [![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2FBistech%2FAzure%2Fmaster%2FWVD%2FImage%2FinstallOneDrive.json)
| Install Teams Standalone | Install Teams Machine-Wide Installer on an already provisioned VM | [![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2FBistech%2FAzure%2Fmaster%2FWVD%2FImage%2FinstallTeams.json)
| Install FSLogix Standalone | Install FSLogix on an already provisioned VM | [![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2FBistech%2FAzure%2Fmaster%2FWVD%2FImage%2FinstallFSLogix.json)
| Install UK Language Pack Standalone | Download UK Language Packs and scripts to an already provisioned VM | [![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2FBistech%2FAzure%2Fmaster%2FWVD%2FImage%2FdownloadLocaleUk.json)
