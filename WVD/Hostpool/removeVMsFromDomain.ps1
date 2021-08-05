params(
    [pscredential]$domainCreds
)

Remove-Computer -UnjoinDomaincredential $domainCreds -WorkgroupName "WORKGROUP" -Restart -Force
