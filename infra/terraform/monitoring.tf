# Observability: one Log Analytics workspace that everything reports to.
#   - Container Insights: node/pod metrics, Kubernetes events, container stdout/stderr
#   - Diagnostic settings: Front Door, PostgreSQL, Key Vault and AKS control-plane logs
#   - Application Insights (workspace-based): backend requests, SQL calls, exceptions
#
# Ingestion is the main cost, so the workspace has a daily cap, container logs use the
# cheaper Basic table plan, and Container Insights collects every 5 minutes.

resource "azurerm_log_analytics_workspace" "main" {
  name                = "${var.prefix}-law"
  location            = local.location
  resource_group_name = data.azurerm_resource_group.main.name
  sku                 = "PerGB2018"
  # 30 days is included in the ingestion price.
  retention_in_days = 30
  daily_quota_gb    = var.log_analytics_daily_quota_gb
  tags              = local.tags
}

# Container stdout/stderr (nginx access logs, backend console output) is the noisiest
# table. Basic logs cost a fraction to ingest; queries are billed per GB scanned.
resource "azurerm_log_analytics_workspace_table" "container_logs" {
  name         = "ContainerLogV2"
  workspace_id = azurerm_log_analytics_workspace.main.id
  plan         = "Basic"
}

# --- Container Insights -----------------------------------------------------------
# The AKS monitoring add-on (oms_agent in aks.tf) authenticates with its managed
# identity and sends what this data collection rule asks for.

resource "azurerm_monitor_data_collection_rule" "container_insights" {
  name                = "MSCI-${var.prefix}-aks"
  location            = local.location
  resource_group_name = data.azurerm_resource_group.main.name
  description         = "Container Insights for ${var.prefix}-aks"
  tags                = local.tags

  destinations {
    log_analytics {
      name                  = "workspace"
      workspace_resource_id = azurerm_log_analytics_workspace.main.id
    }
  }

  data_flow {
    streams      = ["Microsoft-ContainerInsights-Group-Default"]
    destinations = ["workspace"]
  }

  data_sources {
    extension {
      name           = "ContainerInsightsExtension"
      extension_name = "ContainerInsights"
      streams        = ["Microsoft-ContainerInsights-Group-Default"]
      extension_json = jsonencode({
        dataCollectionSettings = {
          # 1m is the default; 5m cuts perf/inventory volume about fivefold.
          interval               = "5m"
          namespaceFilteringMode = "Off"
          enableContainerLogV2   = true
        }
      })
    }
  }
}

resource "azurerm_monitor_data_collection_rule_association" "container_insights" {
  name                    = "ContainerInsightsExtension"
  target_resource_id      = azurerm_kubernetes_cluster.main.id
  data_collection_rule_id = azurerm_monitor_data_collection_rule.container_insights.id
  description             = "Sends Container Insights data from ${var.prefix}-aks to ${var.prefix}-law."
}

# --- Diagnostic settings ------------------------------------------------------------
# Platform metrics (CPU, requests, latency...) are already in Azure Monitor for free;
# only logs are exported, so nothing is paid for twice.

locals {
  diagnostic_settings = merge(
    {
      # Entra ID sign-ins and authorization decisions (guard). All audit categories
      # are left out: even kube-audit-admin is ~0.7 GB/day on an idle cluster, almost
      # all of it AKS's own lease renewals, which would blow the daily cap.
      aks = {
        target           = azurerm_kubernetes_cluster.main.id
        categories       = ["guard"]
        category_groups  = []
        destination_type = "Dedicated" # AKSAudit*/AKSControlPlane tables
      }
      # Server logs, including statements slower than log_min_duration_statement.
      postgres = {
        target           = azurerm_postgresql_flexible_server.main.id
        categories       = ["PostgreSQLLogs"]
        category_groups  = []
        destination_type = null
      }
      # Who read or changed which secret.
      key_vault = {
        target           = azurerm_key_vault.main.id
        categories       = []
        category_groups  = ["audit"]
        destination_type = null
      }
    },
    var.enable_front_door ? {
      # Every request at the edge (status, latency, POP, cache) and failed origin probes.
      front_door = {
        target           = azurerm_cdn_frontdoor_profile.main[0].id
        categories       = ["FrontDoorAccessLog", "FrontDoorHealthProbeLog"]
        category_groups  = []
        destination_type = null
      }
    } : {},
  )
}

resource "azurerm_monitor_diagnostic_setting" "main" {
  for_each = local.diagnostic_settings

  name                           = "to-${azurerm_log_analytics_workspace.main.name}"
  target_resource_id             = each.value.target
  log_analytics_workspace_id     = azurerm_log_analytics_workspace.main.id
  log_analytics_destination_type = each.value.destination_type

  dynamic "enabled_log" {
    for_each = each.value.categories
    content {
      category = enabled_log.value
    }
  }

  dynamic "enabled_log" {
    for_each = each.value.category_groups
    content {
      category_group = enabled_log.value
    }
  }
}

# Log statements that take longer than this (ms) to PostgreSQLLogs; -1 (the
# default) logs none. Dynamic parameter: no server restart.
resource "azurerm_postgresql_flexible_server_configuration" "log_min_duration_statement" {
  name      = "log_min_duration_statement"
  server_id = azurerm_postgresql_flexible_server.main.id
  value     = tostring(var.postgres_slow_query_ms)
}

# --- Application Insights -----------------------------------------------------------

resource "azurerm_application_insights" "main" {
  name                = "${var.prefix}-appi"
  location            = local.location
  resource_group_name = data.azurerm_resource_group.main.name
  workspace_id        = azurerm_log_analytics_workspace.main.id
  application_type    = "Node.JS"
  # Instrumentation-key ingestion is off: the connection string alone can't send data.
  # The backend authenticates with its workload identity (role below).
  local_authentication_enabled = false
  tags                         = local.tags
}

resource "azurerm_role_assignment" "backend_telemetry" {
  scope                = azurerm_application_insights.main.id
  role_definition_name = "Monitoring Metrics Publisher"
  principal_id         = azurerm_user_assigned_identity.workload["backend"].principal_id
  principal_type       = "ServicePrincipal"
}
