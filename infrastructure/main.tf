locals {
  resource_group_name     = "rg-${var.short_location}-${var.environment}-${var.project_name}-${var.suffix}"
  automation_account_name = "aa-${var.short_location}-${var.environment}-${var.project_name}-${var.suffix}"
  managed_identity_name   = "mi-${var.short_location}-${var.environment}-${var.project_name}-${var.suffix}"
  runbook_name            = "rb-${var.short_location}-${var.environment}-${var.project_name}-${var.suffix}"
  schedule_name           = "sc-${var.short_location}-${var.environment}-${var.project_name}-${var.suffix}"
  schedule_start_time     = timeadd(timestamp(), "1h")
}

# ── Resource Group ────────────────────────────────────────────────────────────

resource "azurerm_resource_group" "main" {
  name     = local.resource_group_name
  location = var.location
  tags     = var.tags
}

# ── User-Assigned Managed Identity ───────────────────────────────────────────

resource "azurerm_user_assigned_identity" "main" {
  name                = local.managed_identity_name
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  tags                = var.tags
}

# ── Automation Account ────────────────────────────────────────────────────────

resource "azurerm_automation_account" "main" {
  name                = local.automation_account_name
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  sku_name            = "Basic"

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.main.id]
  }

  tags = var.tags
}

# ── PowerShell 7.2 Modules ────────────────────────────────────────────────────
# Modules are installed from PowerShell Gallery into the PS 7.2 runtime.
# Az.Accounts and Microsoft.Graph.Authentication are base modules that must
# be available before their dependent modules are used at runtime.

resource "azurerm_automation_powershell72_module" "az_accounts" {
  name                  = "Az.Accounts"
  automation_account_id = azurerm_automation_account.main.id

  module_link {
    uri = "https://www.powershellgallery.com/api/v2/package/Az.Accounts"
  }
}

resource "azurerm_automation_powershell72_module" "az_communication" {
  name                  = "Az.Communication"
  automation_account_id = azurerm_automation_account.main.id

  module_link {
    uri = "https://www.powershellgallery.com/api/v2/package/Az.Communication"
  }

  depends_on = [azurerm_automation_powershell72_module.az_accounts]
}

resource "azurerm_automation_powershell72_module" "graph_authentication" {
  name                  = "Microsoft.Graph.Authentication"
  automation_account_id = azurerm_automation_account.main.id

  module_link {
    uri = "https://www.powershellgallery.com/api/v2/package/Microsoft.Graph.Authentication"
  }
}

resource "azurerm_automation_powershell72_module" "graph_directory_management" {
  name                  = "Microsoft.Graph.Identity.DirectoryManagement"
  automation_account_id = azurerm_automation_account.main.id

  module_link {
    uri = "https://www.powershellgallery.com/api/v2/package/Microsoft.Graph.Identity.DirectoryManagement"
  }

  depends_on = [azurerm_automation_powershell72_module.graph_authentication]
}

# ── Runbook ───────────────────────────────────────────────────────────────────

resource "azurerm_automation_runbook" "send_deleted_users" {
  name                    = local.runbook_name
  location                = azurerm_resource_group.main.location
  resource_group_name     = azurerm_resource_group.main.name
  automation_account_name = azurerm_automation_account.main.name
  runbook_type            = "PowerShell72"
  log_verbose             = false
  log_progress            = true

  content = file("${path.module}/../runbooks/sendDeletedUsers.ps1")

  tags = var.tags

  depends_on = [
    azurerm_automation_powershell72_module.az_accounts,
    azurerm_automation_powershell72_module.az_communication,
    azurerm_automation_powershell72_module.graph_authentication,
    azurerm_automation_powershell72_module.graph_directory_management,
  ]
}

# ── Schedule ──────────────────────────────────────────────────────────────────

resource "azurerm_automation_schedule" "main" {
  name                    = local.schedule_name
  resource_group_name     = azurerm_resource_group.main.name
  automation_account_name = azurerm_automation_account.main.name
  frequency               = var.schedule_frequency
  interval                = var.schedule_interval
  start_time              = local.schedule_start_time
  description             = "Triggers the deleted users report runbook on a recurring schedule."
}

resource "azurerm_automation_job_schedule" "send_deleted_users" {
  resource_group_name     = azurerm_resource_group.main.name
  automation_account_name = azurerm_automation_account.main.name
  schedule_name           = azurerm_automation_schedule.main.name
  runbook_name            = azurerm_automation_runbook.send_deleted_users.name
}

# ── Automation Variables (runbook configuration) ──────────────────────────────
# These variables are stored in the Automation Account and can be read by the
# runbook at runtime. Update the runbook to use Get-AutomationVariable instead
# of the hardcoded values at the top of the script to make use of these.

resource "azurerm_automation_variable_string" "acs_rg_name" {
  name                    = "CommSrvRGName"
  resource_group_name     = azurerm_resource_group.main.name
  automation_account_name = azurerm_automation_account.main.name
  value                   = var.acs_resource_group_name
  encrypted               = false
  description             = "Resource group of the Azure Communication Services resource."
}

resource "azurerm_automation_variable_string" "acs_name" {
  name                    = "CommSrvName"
  resource_group_name     = azurerm_resource_group.main.name
  automation_account_name = azurerm_automation_account.main.name
  value                   = var.acs_resource_name
  encrypted               = false
  description             = "Name of the Azure Communication Services resource."
}

resource "azurerm_automation_variable_string" "recipients" {
  name                    = "Recipients"
  resource_group_name     = azurerm_resource_group.main.name
  automation_account_name = azurerm_automation_account.main.name
  value                   = var.report_recipients
  encrypted               = false
  description             = "Comma-separated list of email addresses to receive the deleted users report."
}

# ── Microsoft Graph: Directory.Read.All app role ───────────────────────────────
# Grants the Managed Identity the right to call
#   GET /v1.0/directory/deletedItems/microsoft.graph.user
# This is a Graph application permission, not an Azure RBAC role.

data "azuread_service_principal" "graph" {
  # Microsoft Graph — this app ID is the same in every Entra ID tenant
  client_id = "00000003-0000-0000-c000-000000000000"
}

resource "azuread_app_role_assignment" "directory_read_all" {
  # Directory.Read.All — well-known app role ID for Microsoft Graph
  app_role_id         = "7ab1d382-f21e-4acd-a863-ba3e13f7da61"
  principal_object_id = azurerm_user_assigned_identity.main.principal_id
  resource_object_id  = data.azuread_service_principal.graph.object_id
}

# ── Azure Communication Services: Contributor (scoped to ACS resource group) ──
# The Managed Identity needs access to two sibling resources in the ACS RG:
#   - Microsoft.Communication/communicationServices  → Get-AzCommunicationService
#   - Microsoft.Communication/emailServices/domains  → Get-AzEmailServiceDomain
#   - ACS data plane                                 → Send-AzEmailServicedataEmail
# Scoping Contributor to the resource group (not just the communication service
# resource) ensures all three operations succeed without subscription-level access.

data "azurerm_resource_group" "acs" {
  name = var.acs_resource_group_name
}

resource "azurerm_role_assignment" "acs_contributor" {
  scope                = data.azurerm_resource_group.acs.id
  role_definition_name = "Contributor"
  principal_id         = azurerm_user_assigned_identity.main.principal_id
}
