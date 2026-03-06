# Azure automation script to retrieve deleted users from Azure AD via Microsoft Graph API
# and send a report via Azure Communication Services email.
# This script require environment with PowerShell 7+ and the following modules:
#   - Az
#   - Azure CLI
#   - Az.Accounts
#   - Az.Communication
#   - Microsoft.Graph.Authentication
#   - Microsoft.Graph.Identity.DirectoryManagement
#
# required permissions for the Managed Identity running this script:
#   - Directory.Read.All (for reading deleted users) over Microsoft Graph API
#   - Contributor over the Communication Service resource in Azure (for sending emails) or:
#       - CommunicationServiceEmail.Send (for sending emails) over Azure Communication Services
#       - CommunicationServiceEmail.Domains.Read (for reading email domains) over Azure Communication Services
#       - CommunicationServiceEmail.Services.Read (for reading communication services) over Azure Communication Services
#       - CommunicationService Reader (for reading communication services) over Azure Communication Services

# Parameters for Azure Communication Services — read from Automation Account variables
# (set by Terraform as azurerm_automation_variable_string resources)

$commSrvRGname = Get-AutomationVariable -Name "CommSrvRGName"
$commSrvName = Get-AutomationVariable -Name "CommSrvName"
$recipients = Get-AutomationVariable -Name "Recipients"

# Importing necessary modules
Import-Module Az.Accounts -ErrorAction SilentlyContinue
Import-Module Microsoft.Graph.Authentication -ErrorAction SilentlyContinue

# Authentication using Managed Identity

Connect-AzAccount -Identity
Connect-MgGraph -Identity -NoWelcome

# Getting the list of deleted users from Microsoft Graph API
$uri = "https://graph.microsoft.com/v1.0/directory/deletedItems/microsoft.graph.user"
try {
    $response = Invoke-MgGraphRequest -Method GET -Uri $uri
    $deletedItems = $response.value # API-то връща масив в свойството 'value'
}
catch {
    Write-Error "Error communicating with Microsoft Graph API: $_"
    return
}

# Processing the objects
$deletedUsers = if ($null -ne $deletedItems) {
    foreach ($item in $deletedItems) {
        $delDate = if ($item.deletedDateTime) { [DateTime]$item.deletedDateTime } else { Get-Date }

        [PSCustomObject]@{
            Id                = $item.id
            UserPrincipalName = $item.userPrincipalName
            DisplayName       = $item.displayName
            DeletedDateTime   = $delDate
            DeletionAgeInDays = (New-TimeSpan -Start $delDate -End (Get-Date)).Days
        }
    }
}
else { @() }

# Removing the ID from UPN for better readability
$deletedUsers | ForEach-Object {
    if ($_.UserPrincipalName) {
        $_.UserPrincipalName = $_.UserPrincipalName -replace '^[a-f0-9]{32}', ''
    }
}

# Checking if there is any data
if ($deletedUsers.Count -eq 0) {
    Write-Output "No deleted users found. Script stops."
    return
}

# HTML Design
$css = @"
<style>
table { border-collapse: collapse; width: 100%; font-family: Arial, sans-serif; margin: 20px 0; }
th { background-color: #4472C4; color: white; padding: 12px; text-align: left; border: 1px solid #ddd; }
td { padding: 10px 12px; border: 1px solid #ddd; }
tr:nth-child(even) { background-color: #f2f2f2; }
</style>
"@

$introText = "<h2>Deleted Users Report</h2><p>Total Deleted Users for the last 30 days: $($deletedUsers.Count)</p>"
$htmlTable = $deletedUsers | ConvertTo-Html -Head $css -Title "Deleted Users" | Out-String
$htmlTableContent = ($htmlTable -replace '(<body>)', "`$1$introText").Trim()

# Sending via Azure Communication Services

# Getting the Communication Service details to construct the endpoint and sender address
$acsService = Get-AzCommunicationService -ResourceGroupName $commSrvRGname -Name $commSrvName
$commEndpoint = "https://$($acsService.HostName)"

$linkedDomainPath = $acsService.LinkedDomain[0]
$emailServiceName = ($linkedDomainPath -split "/emailServices/")[1].Split("/")[0]
$domainNameOrId = $linkedDomainPath.Split('/')[-1]

if ($domainNameOrId -eq "AzureManagedDomain") {
    $domain = Get-AzEmailServiceDomain -ResourceGroupName $commSrvRGname -EmailServiceName $emailServiceName -Name $domainNameOrId
    $domainName = $domain.MailFromDomain
}
else { $domainName = $domainNameOrId }

$senderAddress = "DoNotReply@$domainName"
$emailRecipientTo = $recipients -split "\s*,\s*" | Where-Object { $_ } | ForEach-Object { @{ Address = $_ } }

Send-AzEmailServicedataEmail `
    -Endpoint $commEndpoint `
    -ContentSubject "Deleted Users Report (Graph API)" `
    -SenderAddress $senderAddress `
    -RecipientTo $emailRecipientTo `
    -ContentHTML $htmlTableContent
