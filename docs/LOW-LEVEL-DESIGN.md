# Low Level Design — Deleted Users Automation Report

## 1. Purpose

This document describes the internal implementation details of the Deleted Users Report solution. It is intended for engineers who will maintain, extend, or troubleshoot the runbooks and infrastructure.

The solution reports users deleted from Entra ID to enable **offboarding from downstream systems** (SaaS platforms, ITSM tools, on-premises directories, etc.) that do not automatically react to Entra ID deletion events.

---

## 2. Runbook: `sendDeletedUsers.ps1`

### 2.1 Entry Point and Prerequisites

```
Environment: Azure Automation Sandbox (PowerShell 7.2+)
Execution Identity: User-Assigned Managed Identity (<managed-identity-name>)
```

**Modules loaded at startup:**

| Module                                         | Source                     | Purpose                                                      |
| ---------------------------------------------- | -------------------------- | ------------------------------------------------------------ |
| `Az.Accounts`                                  | Automation Account modules | `Connect-AzAccount -Identity`                                |
| `Az.Communication`                             | Automation Account modules | `Get-AzCommunicationService`, `Send-AzEmailServicedataEmail` |
| `Microsoft.Graph.Authentication`               | Automation Account modules | `Connect-MgGraph -Identity`                                  |
| `Microsoft.Graph.Identity.DirectoryManagement` | Automation Account modules | `Invoke-MgGraphRequest`                                      |

Only `Az.Accounts` and `Microsoft.Graph.Authentication` are explicitly imported with `Import-Module`. Other modules are loaded implicitly when their cmdlets are invoked.

---

### 2.2 Configuration Variables

| Variable         | Example / Placeholder         | Description                                |
| ---------------- | ----------------------------- | ------------------------------------------ |
| `$commSrvRGname` | `<rg-communication>`          | Resource group containing the ACS resource |
| `$commSrvName`   | `<acs-resource-name>`         | Azure Communication Services resource name |
| `$recipients`    | `<recipient@your-domain.com>` | Comma-separated email recipient list       |

> For production, these should be moved to Automation Account **Variables** (encrypted if needed) so they can be updated without editing runbook code.

---

### 2.3 Execution Flow (Step-by-Step)

#### Step 1 — Authentication

```powershell
Connect-AzAccount -Identity      # authenticates Az module using MI token
Connect-MgGraph -Identity -NoWelcome  # authenticates Graph SDK using MI token
```

Both calls use the IMDS (Instance Metadata Service) endpoint inside the Automation sandbox to obtain OAuth 2.0 bearer tokens. No credentials are passed.

#### Step 2 — Retrieve Deleted Users from Graph API

```
GET https://graph.microsoft.com/v1.0/directory/deletedItems/microsoft.graph.user
```

**Request:** No parameters — returns all soft-deleted user objects in the tenant.

**Response structure (abbreviated):**

```json
{
  "value": [
    {
      "id": "...",
      "userPrincipalName": "...",
      "displayName": "...",
      "deletedDateTime": "2026-02-01T09:12:00Z"
    }
  ]
}
```

> Only the `value` array is consumed. OData `@odata.nextLink` pagination is **not implemented** in the current POC — if the tenant has more than one page of deleted users (>100 per page by default), only the first page will be reported.

**Error handling:** A `try/catch` block writes the error to `Write-Error` and terminates with `return` on any Graph API failure.

#### Step 3 — Data Transformation

Each raw Graph API object is projected into a `[PSCustomObject]`:

```
Raw Graph object              Projected PSCustomObject
─────────────────────────     ────────────────────────────────────
id                       →    Id
userPrincipalName        →    UserPrincipalName (UPN cleaned)
displayName              →    DisplayName
deletedDateTime          →    DeletedDateTime  (cast to [DateTime])
(calculated)             →    DeletionAgeInDays (TimeSpan in days)
```

**UPN Cleanup:**

Deleted accounts have a synthetic prefix appended to the UPN (a 32-character hex GUID):

```
Before: a1b2c3d4e5f6...7890user@contoso.com
After:  user@contoso.com
```

Regex used: `'^[a-f0-9]{32}'` — strips any 32-char lowercase hex prefix.

**Null guard for `deletedDateTime`:**

If `deletedDateTime` is null (unusual but defensive), the current timestamp is substituted so `DeletionAgeInDays` remains calculable.

#### Step 4 — Early Exit if No Data

```powershell
if ($deletedUsers.Count -eq 0) {
    Write-Output "No deleted users found. Script stops."
    return
}
```

No email is sent if the recycle bin is empty.

#### Step 5 — HTML Report Generation

The HTML output consists of three parts assembled in sequence:

1. **CSS block** — Inline `<style>` tag with table styling.
2. **Intro header** — `<h2>` title + `<p>` with the count of deleted users.
3. **HTML table body** — Generated via `ConvertTo-Html`.

```
$css        ──→  <head> section of the HTML document
$introText  ──→  injected after <body> tag via regex replace
$htmlTable  ──→  full HTML document from ConvertTo-Html
                 │
                 └─ regex: '(<body>)' → '$1<h2>...</h2><p>...</p>'
```

Fields rendered in the table (column order matches object property declaration):

| Column            | Source Field                  |
| ----------------- | ----------------------------- |
| Id                | `Id`                          |
| UserPrincipalName | `UserPrincipalName` (cleaned) |
| DisplayName       | `DisplayName`                 |
| DeletedDateTime   | `DeletedDateTime`             |
| DeletionAgeInDays | `DeletionAgeInDays`           |

**CSS specifics:**

| Selector             | Key Styles                                          |
| -------------------- | --------------------------------------------------- |
| `table`              | `border-collapse: collapse`, full width, Arial font |
| `th`                 | Blue (`#4472C4`) background, white text             |
| `td`                 | `10px 12px` padding, `1px solid #ddd` border        |
| `tr:nth-child(even)` | Light grey (`#f2f2f2`) background (zebra striping)  |

#### Step 6 — Resolve ACS Endpoint and Sender Address

The endpoint and sender address are **not hardcoded** — they are resolved at runtime from the ACS resource:

```
Get-AzCommunicationService
  └── .HostName         → commEndpoint = "https://<hostname>"
  └── .LinkedDomain[0]  → ARM path to the linked email domain
        │
        ├── extract emailServiceName  (between '/emailServices/' and next '/')
        └── extract domainNameOrId    (last segment of the ARM path)
              │
              ├── if "AzureManagedDomain"
              │     └── Get-AzEmailServiceDomain → .MailFromDomain → senderAddress
              └── else
                    └── domainNameOrId is used directly as the domain name
```

This makes the runbook portable across environments with different ACS configurations.

#### Step 7 — Send Email

```powershell
Send-AzEmailServicedataEmail `
    -Endpoint $commEndpoint `
    -ContentSubject "Deleted Users Report (Graph API)" `
    -SenderAddress $senderAddress `
    -RecipientTo $emailRecipientTo `
    -ContentHTML $htmlTableContent
```

`$emailRecipientTo` is a `@(@{ Address = $recipients })` array. The current POC supports a single recipient string. For multiple recipients the string would need to be split into multiple address hash tables.

---

### 2.4 Sequence Diagram

```
Scheduler          Runbook                  Graph API                ACS Resource         Recipient
    |                 |                         |                         |                    |
    |--trigger------->|                         |                         |                    |
    |                 |--Connect-AzAccount----->| (IMDS token)            |                    |
    |                 |--Connect-MgGraph------->| (IMDS token)            |                    |
    |                 |                         |                         |                    |
    |                 |--GET /deletedItems/---->|                         |                    |
    |                 |  microsoft.graph.user   |                         |                    |
    |                 |<--200 OK: value[]-------|                         |                    |
    |                 |                         |                         |                    |
    |                 |--transform & build HTML |                         |                    |
    |                 |                         |                         |                    |
    |                 |--Get-AzCommunicationService------------------->  |                    |
    |                 |<--HostName, LinkedDomain-----------------------   |                    |
    |                 |                         |                         |                    |
    |                 |  [if AzureManagedDomain] Get-AzEmailServiceDomain|                    |
    |                 |<--MailFromDomain-------------------------------   |                    |
    |                 |                         |                         |                    |
    |                 |--Send-AzEmailServicedataEmail------------------>  |                    |
    |                 |                         |       ACS REST API      |--send SMTP-------->|
    |                 |<--202 Accepted---------------------------------   |                    |
    |                 |                         |                         |                    |
```

---

## 3. Permission Setup Script: `assign-permision-managed-identity`

This is a **one-time, manual script** run by an administrator to grant the Managed Identity the required Microsoft Graph application role.

### 3.1 Steps Performed

```
1. Set Azure subscription context
        Set-AzContext -SubscriptionId <subscriptionId>

2. Get MI Principal ID
        Get-AzAutomationAccount → .Identity.PrincipalId

3. Connect to Microsoft Graph (as admin with consent rights)
        Connect-MgGraph -Scopes "Application.Read.All",
                                "AppRoleAssignment.ReadWrite.All",
                                "Directory.Read.All"

4. Get Service Principals
        ├── MI service principal (by principal ID)
        └── Microsoft Graph SP (by fixed appId: 00000003-0000-0000-c000-000000000000)

5. Find the target App Role
        $graphSp.AppRoles | Where-Object {
            $_.Value -eq "Directory.Read.All"
            -and $_.AllowedMemberTypes -contains "Application"
        }

6. Assign the role
        New-MgServicePrincipalAppRoleAssignment
            -ServicePrincipalId  $miSp.Id
            -PrincipalId         $miSp.Id
            -ResourceId          $graphSp.Id
            -AppRoleId           $role.Id
```

### 3.2 Required Admin Permissions (for the person running this script)

| Permission                        | Reason                                         |
| --------------------------------- | ---------------------------------------------- |
| `Application.Read.All`            | Enumerate service principals                   |
| `AppRoleAssignment.ReadWrite.All` | Create the app role assignment                 |
| `Directory.Read.All`              | Read directory data (service principal lookup) |

---

## 4. Infrastructure Details (Terraform)

### 4.1 Managed Resources

Only three Azure resources are in scope for Terraform:

```
azurerm_user_assigned_identity  (<managed-identity-name>)
└── location: target region

azurerm_automation_account  (<automation-account-name>)
├── sku_name: Basic
├── identity:
│     type: UserAssigned
│     identity_ids: [<managed-identity-name>]
└── public_network_access_enabled: true

azurerm_automation_runbook  (sendDeletedUsers)
├── runbook_type: PowerShell
├── automation_account_name: <automation-account-name>
└── content: sendDeletedUsers.ps1

azurerm_automation_schedule  (+ azurerm_automation_job_schedule)
└── linked to: sendDeletedUsers runbook
```

> Azure Communication Services is **outside the Terraform scope** — it is pre-existing or provisioned separately.

### 4.2 Required PowerShell Modules

Modules must be installed in the Automation Account (via Portal or `azurerm_automation_module` resources). The runbook requires:

| Module                                         | Used By                 |
| ---------------------------------------------- | ----------------------- |
| `Az.Accounts`                                  | Authentication          |
| `Az.Communication`                             | ACS cmdlets             |
| `Microsoft.Graph.Authentication`               | Graph auth              |
| `Microsoft.Graph.Identity.DirectoryManagement` | `Invoke-MgGraphRequest` |

---

## 5. Known Limitations and Recommended Improvements

| Limitation                      | Impact                                  | Recommended Fix                                    |
| ------------------------------- | --------------------------------------- | -------------------------------------------------- |
| No Graph API pagination         | Only first 100 deleted users retrieved  | Implement `@odata.nextLink` loop                   |
| Single recipient string         | Cannot send to multiple people          | Split `$recipients` on `,` and build array         |
| Hardcoded config vars           | Runbook must be edited to change target | Move to Automation Account Variables               |
| No retry logic on Graph errors  | Transient errors cause full failure     | Add retry loop with backoff                        |
| Contributor on ACS resource     | Over-privileged for POC purposes        | Use scoped ACS RBAC roles in production            |
| `$recipients` not parameterised | Recipients set at author time           | Accept as runbook parameter or Automation Variable |

---

## 6. Error Handling Summary

| Error Scenario                        | Behaviour                                           |
| ------------------------------------- | --------------------------------------------------- |
| Graph API unreachable or auth failure | `Write-Error` + `return` (runbook exits)            |
| No deleted users returned             | `Write-Output "No deleted users found."` + `return` |
| ACS resource not found                | Unhandled exception — runbook marks job as `Failed` |
| Email send failure                    | Unhandled exception — runbook marks job as `Failed` |

---

## 7. Related Documents

- [Project Overview](OVERVIEW.md)
- [High Level Design](HIGH-LEVEL-DESIGN.md)
