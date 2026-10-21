variable "prefix" {
  description = "Short prefix used in every resource name."
  type        = string
  default     = "poc3t"
}

variable "location" {
  description = "Azure region."
  type        = string
  default     = "swedencentral"
}

variable "resource_group_name" {
  description = "Existing resource group created by bootstrap.sh. Defaults to <prefix>-rg."
  type        = string
  default     = null
}

# --- AKS -----------------------------------------------------------------------

variable "kubernetes_version" {
  description = "AKS Kubernetes version. null = the region's current default."
  type        = string
  default     = null
}

variable "node_vm_size" {
  description = <<-EOT
    Node VM size. AKS needs at least 2 vCPU / 4 GiB. Standard_D2als_v6 is the cheapest
    such size this subscription is allowed to use in Sweden Central (B-series is blocked).
  EOT
  type        = string
  default     = "Standard_D2als_v6"
}

variable "node_count" {
  description = <<-EOT
    Number of nodes in the single system node pool. Two: one D2als_v6 can't fit the
    system pods, both monitoring agents (Container Insights + managed Prometheus) and
    the app.
  EOT
  type        = number
  default     = 2
}

variable "node_os_disk_size_gb" {
  description = "OS disk size per node. The AKS default (128 GB) costs more than this PoC needs."
  type        = number
  default     = 32
}

variable "enable_gateway_api" {
  description = <<-EOT
    Enable the AKS app-routing Gateway API implementation (managed Istio, GatewayClass
    "approuting-istio"). Off by default: its istiod and gateway pods need more than a
    single small node. When off, the frontend Service gets a public LoadBalancer IP.
  EOT
  type        = bool
  default     = false
}

variable "enable_front_door" {
  description = <<-EOT
    Put Azure Front Door (Standard, ~$35/month base fee) in front of the frontend for an
    HTTPS *.azurefd.net URL. Requires the LoadBalancer frontend (enable_gateway_api = false).
  EOT
  type        = bool
  default     = true
}

# --- PostgreSQL -----------------------------------------------------------------

variable "postgres_version" {
  description = "PostgreSQL major version."
  type        = string
  default     = "17"
}

variable "postgres_sku" {
  description = "Flexible Server SKU. B_Standard_B1ms (1 vCore / 2 GiB) is the cheapest tier."
  type        = string
  default     = "B_Standard_B1ms"
}

variable "postgres_storage_mb" {
  description = "Storage size in MB (32 GiB is the minimum)."
  type        = number
  default     = 32768
}

variable "postgres_database" {
  description = "Application database name."
  type        = string
  default     = "app"
}

variable "postgres_slow_query_ms" {
  description = "Statements slower than this (ms) are written to the PostgreSQL logs. -1 disables."
  type        = number
  default     = 500
}

# --- Monitoring -----------------------------------------------------------------

variable "log_analytics_daily_quota_gb" {
  description = <<-EOT
    Daily ingestion cap for the Log Analytics workspace (all logs, including Application
    Insights). Ingestion stops for the rest of the UTC day once reached. -1 = no cap.
  EOT
  type        = number
  default     = 0.5
}

# --- Application ----------------------------------------------------------------

variable "app_namespace" {
  description = "Kubernetes namespace the Helm chart deploys into."
  type        = string
  default     = "poc3t"
}

variable "backend_service_account" {
  description = "Kubernetes service account used by the backend pods (workload identity)."
  type        = string
  default     = "backend"
}

variable "migrate_service_account" {
  description = "Kubernetes service account used by the db-migrate job (workload identity)."
  type        = string
  default     = "db-migrate"
}

variable "postgres_app_user" {
  description = "Least-privilege login the backend uses (DML only, no DDL)."
  type        = string
  default     = "app_user"
}
