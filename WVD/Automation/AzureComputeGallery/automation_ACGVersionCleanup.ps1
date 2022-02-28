<# 
.SYNOPSIS
    This script automates the removal of old image versions from an Azure Compute Gallery 

.DESCRIPTION
    This script is designed to automate the process of removing old image versions from an Azure Compute Gallery.
    It will remove image versions from oldest to newest, leaving the amount of versions to keep as specified by the parameter $versionsToKeep

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
   [string[]]$resourceGroupNames,

   [int]$versionsToKeep = 2
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

#region Cleanup Image Versions
foreach ($resourceGroupName in $resourceGroupNames) {
   Write-Output "Checking resource group '$resourceGroupName'..."
   $gallerys = Get-AzGallery -ResourceGroupName $resourceGroupName
   if ($gallerys) {
      foreach ($gallery in $gallerys) {
         Write-Output "Checking azure compute gallery '$($gallery.Name)'..."
         $definitions = Get-AzGalleryImageDefinition -ResourceGroupName $resourceGroupName -GalleryName $gallery.Name
         if ($definitions) {
            foreach ($definition in $definitions) {
               Write-Output "Checking image definition '$($definition.Name)'..."
               $versions = Get-AzGalleryImageVersion -ResourceGroupName $resourceGroupName -GalleryName $gallery.Name -GalleryImageDefinitionName $definition.Name
               $removeVersions = $versions | Sort-Object Name -Descending | Select-Object -Skip $versionsToKeep
               if ($removeVersions) {
                  foreach ($versionToRemove in $removeVersions) {
                     Remove-AzGalleryImageVersion -ResourceGroupName $resourceGroupName -GalleryName $gallery.Name -GalleryImageDefinitionName $definition.Name -Name $versionToRemove.Name -Force | Out-Null
                     Write-Output "Removed version '$($versionToRemove.Name)' from image definition '$($definition.Name)'"
                  }
               }
               else {
                  Write-Output "Found no eligible versions to remove from image definition '$($definition.Name)'"
               }   
            }  
         }
         else {
            Write-Output "Found no Image Definitions in Azure Compute Gallery '$($gallery.Name)'"
         }
      }
   }
   else {
      Write-Output "Found no Azure Compute Galleries in resource group '$resourceGroupName'"
   }
}
Write-Output "Image version cleanup complete"
#endregion
