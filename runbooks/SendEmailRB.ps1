param(
  [Parameter(Mandatory = $true)]
  [string]$ToAddresses,

  [Parameter(Mandatory = $true)]
  [string]$Subject,

  [Parameter(Mandatory = $true)]
  [string]$MessageBody
)

# Convert comma-separated string to array
$ToAddressesArray = $ToAddresses -split ',' | ForEach-Object { $_.Trim() }

# Ensures you do not inherit an AzContext in your runbook
$null = Disable-AzContextAutosave -Scope Process

# Connect using a Managed Service Identity
try {
    $AzureConnection = (Connect-AzAccount -Identity).context
}
catch {
    Write-Output "There is no system-assigned user identity. Aborting."
    exit
}

Write-Output "You are connected to: $AzureConnection"

Write-Output "Parameters received:"
Write-Output "  ToAddresses: $ToAddresses"
Write-Output "  Subject: $Subject"
Write-Output "  MessageBody: $MessageBody"

$emailRecipientTo = @($ToAddressesArray | ForEach-Object {
    @{
        Address = $_
        DisplayName = $_
    }
})

Write-Output "Recipient objects:"
Write-Output ($emailRecipientTo | ConvertTo-Json)

$message = @{
    ContentSubject = $Subject
    RecipientTo = $emailRecipientTo
    SenderAddress = "DoNotReply@arcoa.eu"
    ContentPlainText = $MessageBody
    ContentHtml = "<html><body><p>$MessageBody</p></body></html>"
}

Write-Output "Message object:"
Write-Output ($message | ConvertTo-Json)

try {
    Send-AzEmailServicedataEmail -Message $message -endpoint "https://cs-comm-srv-test.europe.communication.azure.com/"
    Write-Output "Email sent successfully!"
}
catch {
    Write-Output "Error sending email:"
    Write-Output $_.Exception.Message
    Write-Output $_.Exception.StackTrace
    throw
}