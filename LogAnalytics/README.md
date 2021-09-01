# Microsoft Azure Log Analytics

Log Analytics is a tool in the Azure portal used to edit and run log queries with data in Azure Monitor Logs

This repository contains scripts to create Log Analytics resources

The 'Deploy to Azure' buttons shown below can be used to create these resources

#### Insights Counters for AVD
Creates the Azure Monitor Agent configuration required for AVD Insights

#### Diagnostics for AVD
Creates the Diagnostics configuration required for AVD Insights

## Deploy to Azure buttons

Name | Description   | Auto-deploy   |
-----| ------------- |--------------- | 
| Insights Counters for AVD | Creates the Azure Monitor Agent configuration required for AVD Insights | [![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2FBistech%2FAzure%2Fmaster%2FLogAnalytics%2FAVD%2FavdInsightsCounters.json)
| Diagnostics for AVD | Creates the Diagnostics configuration required for AVD Insights | [![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2FBistech%2FAzure%2Fmaster%2FLogAnalytics%2FAVD%2FavdDiagnostics.json)
