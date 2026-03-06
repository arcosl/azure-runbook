output "automation_account_id" {
  description = "Resource ID of the Azure Automation Account."
  value       = azurerm_automation_account.main.id
}

output "automation_account_name" {
  description = "Name of the Azure Automation Account."
  value       = azurerm_automation_account.main.name
}

output "managed_identity_id" {
  description = "Resource ID of the User-Assigned Managed Identity."
  value       = azurerm_user_assigned_identity.main.id
}

output "managed_identity_principal_id" {
  description = "Principal (Object) ID of the Managed Identity. Use this value in the assign-permision-managed-identity script to grant the Directory.Read.All Graph API role."
  value       = azurerm_user_assigned_identity.main.principal_id
}

output "managed_identity_client_id" {
  description = "Client ID of the Managed Identity."
  value       = azurerm_user_assigned_identity.main.client_id
}

output "resource_group_name" {
  description = "Name of the resource group."
  value       = azurerm_resource_group.main.name
}
