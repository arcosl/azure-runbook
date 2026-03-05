$commSrvRGname = "comm-srv-test"

$commSrvName = "cs-comm-srv-test"

$recipients = "andrey.aleksandrov@dxc.com"

$ErrorActionPreference = 'Stop'

try {
    Write-Output "Authenticating with managed identity..."
    Connect-AzAccount -Identity | Out-Null
    Connect-MgGraph -Identity -NoWelcome | Out-Null

    Write-Output "Retrieving deleted users from Microsoft Graph..."
    $uri = "https://graph.microsoft.com/v1.0/directory/deletedItems/microsoft.graph.user?`$select=id,userPrincipalName,displayName,accountEnabled,deletedDateTime,userType&`$top=999"
    $deletedUsersRaw = @()

    do {
        $response = Invoke-MgGraphRequest -Method GET -Uri $uri
        if ($response.value) {
            $deletedUsersRaw += $response.value
        }
        $uri = $response.'@odata.nextLink'
    } while ($uri)

    $deletedUsers = $deletedUsersRaw | ForEach-Object {
        $deletedDateTime = $null
        $deletionAgeInDays = $null

        if ($_.deletedDateTime) {
            $deletedDateTime = [datetime]$_.deletedDateTime
            $deletionAgeInDays = [int]((Get-Date).ToUniversalTime() - $deletedDateTime.ToUniversalTime()).TotalDays
        }

        [PSCustomObject]@{
            Id                = $_.id
            UserPrincipalName = $_.userPrincipalName
            DisplayName       = $_.displayName
            AccountEnabled    = $_.accountEnabled
            DeletedDateTime   = $deletedDateTime
            DeletionAgeInDays = $deletionAgeInDays
            UserType          = $_.userType
        }
    }

    # remove leading 32-char ID fragment from UPN for readability (if present)
    $deletedUsers | ForEach-Object {
        if ($_.UserPrincipalName) {
            $_.UserPrincipalName = $_.UserPrincipalName -replace '^[a-f0-9]{32}', ''
        }
    }

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

    Write-Host "Sending email to: $($recipients -join ', ') with sender: $senderAddress using ACS endpoint: $commEndpoint"

    # Send email using Azure Communication Services
    Send-AzEmailServicedataEmail `
        -Endpoint $commEndpoint `
        -ContentSubject "Deleted Users Report" `
        -SenderAddress $senderAddress `
        -RecipientTo @($emailRecipientTo) `
        -ContentPlainText "" `
        -ContentHTML $htmlTableContent

    Write-Output "Runbook completed successfully."
}
catch {
    Write-Error ("Runbook failed: " + $_.Exception.Message)
    if ($_.ScriptStackTrace) {
        Write-Error ("Stack: " + $_.ScriptStackTrace)
    }
    throw
}
