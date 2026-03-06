# Deleted Users Report — Project Overview

## Goal

Provide an automated, scheduled report of soft-deleted users in Microsoft Entra ID (formerly Azure Active Directory) delivered as an HTML email to a defined list of recipients.

The primary purpose is to notify administrators and service owners about user accounts that have been deleted in Entra ID so that those accounts can be **removed from downstream systems that do not automatically detect Entra ID deletions** (e.g., SaaS platforms, on-premises directories, ticketing systems, access control lists). This prevents orphaned accounts from persisting in external systems after an employee or contractor leaves the organisation.

As a secondary benefit, the report also gives operations teams visibility into the Entra ID recycle bin. Users remain in the recycle bin for **30 days** after deletion; after that, they are permanently purged.

---

## Problem Statement

When a user account is deleted in Entra ID it moves into a soft-delete state for 30 days before permanent removal. Many downstream systems (SaaS applications, internal portals, ITSM tools, access control lists) are **not integrated with Entra ID lifecycle events** and will not automatically remove the user when the account is deleted. This creates:

- **Security risk** — orphaned accounts in external systems may retain access or licenses after the person has left.
- **Compliance gaps** — audit records may incorrectly show active accounts for departed users.
- **Operational overhead** — manual identification of affected users across multiple systems is slow and error-prone.

This project automates the detection and reporting of deleted Entra ID users so that downstream system owners are notified on a regular schedule and can act on the information promptly.

---

## How It Works

```
+------------------+     Schedule      +----------------------+
|  Azure Scheduler | ----------------> |  Azure Automation    |
|   (Recurring)    |                   |  Runbook             |
+------------------+                   +----------+-----------+
                                                   |
                                       Managed Identity (Graph API)
                                                   |
                                                   v
                                    +-----------------------------+
                                    |  Microsoft Graph API        |
                                    |  /directory/deletedItems    |
                                    |  /microsoft.graph.user      |
                                    +-----------------------------+
                                                   |
                                           HTML report built
                                                   |
                                       Managed Identity (Az SDK)
                                                   |
                                                   v
                                    +-----------------------------+
                                    |  Azure Communication        |
                                    |  Services (Email)           |
                                    +-----------------------------+
                                                   |
                                                   v
                                    +-----------------------------+
                                    |  Recipients (Email)         |
                                    +-----------------------------+
```

1. **Schedule** — An Azure Automation schedule triggers the runbook on a recurring basis (e.g., daily or weekly).
2. **Authentication** — The runbook authenticates to both the Azure Resource Manager (`Az` module) and the Microsoft Graph API using the automation account's **User-Assigned Managed Identity** — no credentials are stored anywhere.
3. **Data collection** — The Script calls `GET /v1.0/directory/deletedItems/microsoft.graph.user` via the Graph API and retrieves all soft-deleted user objects.
4. **Processing** — Each deleted user is projected into a structured object with: Display Name, UPN, deletion date, and age in days since deletion.
5. **Report generation** — The list is converted into a styled HTML table.
6. **Email delivery** — The report is sent via Azure Communication Services using the `DoNotReply@<domain>` sender address that is read dynamically from the linked email domain of the ACS resource.

---

## Components

| Component                      | Name                        | Purpose                                      |
| ------------------------------ | --------------------------- | -------------------------------------------- |
| Azure Automation Account       | `<automation-account-name>` | Hosts and schedules runbooks                 |
| User-Assigned Managed Identity | `<managed-identity-name>`   | Passwordless authentication for runbooks     |
| Runbook                        | `sendDeletedUsers.ps1`      | Main script — collects and emails the report |
| Azure Communication Services   | `<acs-resource-name>`       | Email transport layer                        |
| Microsoft Graph API            | —                           | Source of deleted user data from Entra ID    |

---

## Permissions Required

### Microsoft Graph API (via Managed Identity app role)

| Permission           | Type        | Purpose                        |
| -------------------- | ----------- | ------------------------------ |
| `Directory.Read.All` | Application | Read deleted directory objects |

### Azure RBAC (over the ACS resource)

| Role / Permission                     | Scope                          | Purpose                             |
| ------------------------------------- | ------------------------------ | ----------------------------------- |
| `Contributor`                         | Communication Service resource | Full management access (simplified) |
| _or_ `CommunicationServiceEmail.Send` | ACS                            | Send emails                         |
| _or_ `CommunicationService Reader`    | ACS                            | Read service properties             |

---

## Repository Structure

```
azure-runbook/
├── docs/
│   ├── OVERVIEW.md              ← This file
│   ├── HIGH-LEVEL-DESIGN.md     ← Architecture & components
│   └── LOW-LEVEL-DESIGN.md      ← Code flow & technical details
├── runbooks/
│   └── sendDeletedUsers.ps1     ← Main reporting runbook
├── assign-permision-managed-identity  ← One-time permission setup script
└── README.md
```

---

## Related Documents

- [High Level Design](HIGH-LEVEL-DESIGN.md)
- [Low Level Design](LOW-LEVEL-DESIGN.md)
