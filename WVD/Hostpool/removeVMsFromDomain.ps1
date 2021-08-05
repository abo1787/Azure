param(
    $domainUser,
    $domainPass)


$creds = New-Object -TypeName System.Management.Automation.PSCredential -ArgumentList $domainUser, $domainPass

Remove-Computer -UnjoinDomainCredential $creds -WorkgroupName "WORKGROUP" -Restart -Force
