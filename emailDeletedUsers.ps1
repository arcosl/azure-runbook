$commSrvRGname = "comm-srv-test"

$commSrvName = "cs-comm-srv-test"

$recipients = "andrey.aleksandrov@dxc.com"

# # Authenticate using Azure Automation managed identity
Connect-AzAccount -Identity

Connect-Entra -Scopes 'User.Read.All'

$deletedUsers = $(Get-EntraDeletedUser -All | Select-Object Id, UserPrincipalName, DisplayName, AccountEnabled, DeletedDateTime, DeletionAgeInDays, UserType)
#remove ID from UserPrincipalName for better readability
$deletedUsers | ForEach-Object { $_.UserPrincipalName = $_.UserPrincipalName -replace '^[a-f0-9]{32}', '' }

$css = @"
<style>
table {
    border-collapse: collapse;
    width: 100%;
    font-family: Arial, sans-serif;
    margin: 20px 0;
}
th {
    background-color: #4472C4;
    color: white;
    padding: 12px;
    text-align: left;
    border: 1px solid #ddd;
    font-weight: bold;
}
td {
    padding: 10px 12px;
    border: 1px solid #ddd;
}
tr:nth-child(even) {
    background-color: #f2f2f2;
}
tr:hover {
    background-color: #e8e8e8;
}
</style>
"@

$introText = @"
<h2>Deleted Users Report</h2>
<p>This report shows all users that have been deleted from your Entra ID. Please review the list below for any unexpected deletions.</p>
<p><strong>Total Deleted Users:</strong> $($deletedUsers.Count)</p>
"@

$htmlTable = $deletedUsers | ConvertTo-Html -Head $css -Title "Deleted Users" | Out-String
$htmlTableContent = ($htmlTable -replace '(<body>)', "`$1$introText").Trim()

# Sent the email with the HTML table using azure communication services

# Get ACS service details
$acsService = Get-AzCommunicationService -ResourceGroupName $commSrvRGname -Name $commSrvName

# Get endpoint from HostName
$commEndpoint = "https://$($acsService.HostName)"

# Extract domain name from LinkedDomain resource ID
# Format: /subscriptions/.../emailServices/EMAILSVC/domains/DOMAIN
$linkedDomainPath = $acsService.LinkedDomain[0]
$pathSegments = $linkedDomainPath.Split('/')
$emailServiceName = $pathSegments[8]  # emailservices name
$domainNameOrId = $pathSegments[-1]   # domain name (could be custom domain or "AzureManagedDomain")

# For AzureManagedDomain, fetch the actual domain string from the resource
if ($domainNameOrId -eq "AzureManagedDomain") {
    $domain = Get-AzEmailServiceDomain -ResourceGroupName $commSrvRGname -EmailServiceName $emailServiceName -Name $domainNameOrId
    $domainName = $domain.MailFromDomain
} else {
    $domainName = $domainNameOrId
}

$senderAddress = "DoNotReply@$domainName"

# Build recipients array from parameters
$emailRecipientTo = $recipients | ForEach-Object {
    @{
        Address = $_
    }
}

# Send email using Azure Communication Services
Send-AzEmailServicedataEmail `
    -Endpoint $commEndpoint `
    -ContentSubject "Deleted Users Report" `
    -SenderAddress $senderAddress `
    -RecipientTo @($emailRecipientTo) `
    -ContentPlainText "" `
    -ContentHTML $htmlTableContent