variable "subscription_id" {
  description = "Azure subscription ID where resources will be created."
  type        = string
}

variable "location" {
  description = "Azure region for all resources (e.g. westeurope, eastus)."
  type        = string
  default     = "Sweden Central"
}

variable "short_location" {
  description = "Short name for the Azure region, used in resource names (e.g. weu for westeurope, eus for eastus)."
  type        = string
  default     = "swc"
}

variable "environment" {
  description = "Short name for the environment, used in resource names (e.g. dev, prod)."
  type        = string
  default     = "test"
}

variable "project_name" {
  description = "Short name for the project, used in resource names (e.g. hr for HR department)."
  type        = string
}

variable "suffix" {
  description = "Additional suffix for resource names to ensure uniqueness (e.g. initials, date)."
  type        = string
  default     = "1"
}


# ── Schedule ──────────────────────────────────────────────────────────────────
# resource_group_name, automation_account_name, managed_identity_name,
# runbook_name, schedule_name, and schedule_start_time are all derived
# from the naming convention locals in main.tf.

variable "schedule_frequency" {
  description = "How often the schedule fires. Valid values: OneTime, Hour, Day, Week, Month."
  type        = string
  default     = "Day"
}

variable "schedule_interval" {
  description = "Number of frequency units between runs (e.g. 1 = every day when frequency is Day)."
  type        = number
  default     = 1
}

# ── ACS configuration (stored as Automation Variables) ───────────────────────

variable "acs_resource_group_name" {
  description = "Resource group that contains the Azure Communication Services resource and its linked Email Service. The Managed Identity is granted Contributor on this resource group to cover both Get-AzCommunicationService and Get-AzEmailServiceDomain calls."
  type        = string
}

variable "acs_resource_name" {
  description = "Name of the Azure Communication Services resource."
  type        = string
}

variable "report_recipients" {
  description = "Comma-separated list of email addresses that will receive the deleted users report."
  type        = string
}

# ── Tags ──────────────────────────────────────────────────────────────────────

variable "tags" {
  description = "Tags applied to all resources."
  type        = map(string)
  default     = {}
}
