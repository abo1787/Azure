# Mitel

This repository contains scripts to create Mitel resources

The 'Deploy to Azure' buttons shown below can be used to create these resources

#### Automated Deployment
Creates everything required for the Mitel deployment

#### Create Resource Groups
Creates resource groups required to host Mitel resources

#### Create Networking
Creates all networking required to support Mitel resources

#### Create DMZ Resources
Creates selected resources required in a DMZ. Selections include:

  * MiVoice Border Gateway

#### Create Application Resources
Creates selected resources required for applications. Selections include:

  * MiVoice Business
  * MiCollab
  * MiCC
  * IVR
  * MiVCR
  * SQL

## Deploy to Azure buttons

Name | Description   | Deploy   |
-----| ------------- |--------------- | 
| Automated Deployment | Creates everything required for the Mitel deployment | [![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2FBistech%2FAzure%2Fmaster%2FMitel%2FDeploy%2FdeployMitelSolution.json)
| Create Resource Groups | Creates resource groups required to host Mitel resources | [![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2FBistech%2FAzure%2Fmaster%2FMitel%2FDeploy%2FdeployResourceGroups.json)
| Create Networking | Creates all networking required to support Mitel resources | [![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2FBistech%2FAzure%2Fmaster%2FMitel%2FDeploy%2FdeployNetworking.json)
| Create DMZ Resources | Creates selected resources required in a DMZ | [![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2FBistech%2FAzure%2Fmaster%2FMitel%2FDeploy%2FdeployDMZResources.json)
| Create Application Resources | Creates selected resources required for applications | [![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2FBistech%2FAzure%2Fmaster%2FMitel%2FDeploy%2FdeployAppResources.json)