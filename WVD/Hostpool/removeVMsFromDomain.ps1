param(
    $domainUser,
    $domainPass
)

# Create PSCredential Object
$creds = New-Object -TypeName System.Management.Automation.PSCredential -ArgumentList $domainUser, $domainPass

# Remove computer from domain
Remove-Computer -UnjoinDomainCredential $creds -WorkgroupName "WORKGROUP" -Restart -Force
