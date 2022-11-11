<# 
.SYNOPSIS
    This script removes previous resource group deployments 

.DESCRIPTION
    This script is designed to automate the process of removing previous resource
    group deployments during an AVD host pool update. It is triggered as a child by
    the 'automation_AVDUpdateHostPool_Runbook'

.NOTES
    Author  : Dave Pierson
    Version : 1.0.0

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
  [string]$resourceGroupName

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

#region Cleanup old Resource Group Deployments
Write-Output "Removing previous resource group deployments in '$resourceGroupName'..."
$deploymentsToDelete = Get-AzResourceGroupDeployment -ResourceGroupName $resourceGroupName | Where-Object { ($_.DeploymentName -notlike "HostPool*") -and ($_.Timestamp -lt ((Get-Date).AddDays(-1))) }
foreach ($deployment in $deploymentsToDelete) {
  try {
    Remove-AzResourceGroupDeployment -ResourceGroupName $resourceGroupName -Name $deployment.DeploymentName | Out-Null
    Write-Output "Removed deployment: '$($deployment.DeploymentName)'"
  }
  catch { 
    Write-Error "Error deleting resource group deployment '$($deployment.DeploymentName)'" 
  }
}
#endregion