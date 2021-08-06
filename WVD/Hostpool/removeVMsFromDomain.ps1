param(
    $domainUser,
    $domainPass
)

# Create PSCredential Object
$domainPass = $domainPass | ConvertTo-SecureString -AsPlainText -Force
$creds = New-Object System.Management.Automation.PSCredential($domainUser, $domainPass)

# Remove computer from domain
Remove-Computer -UnjoinDomainCredential $creds -WorkgroupName "WORKGROUP" -Force
