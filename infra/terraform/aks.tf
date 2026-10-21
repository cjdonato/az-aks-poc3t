# User-assigned control-plane identity, so it can be granted rights on the
# subnet before the cluster exists.
resource "azurerm_user_assigned_identity" "aks" {
  name                = "${var.prefix}-aks-id"
  location            = local.location
  resource_group_name = data.azurerm_resource_group.main.name
  tags                = local.tags
}

resource "azurerm_role_assignment" "aks_network" {
  scope                = azurerm_subnet.aks.id
  role_definition_name = "Network Contributor"
  principal_id         = azurerm_user_assigned_identity.aks.principal_id
  principal_type       = "ServicePrincipal"
}

resource "azurerm_kubernetes_cluster" "main" {
  name                = "${var.prefix}-aks"
  location            = local.location
  resource_group_name = data.azurerm_resource_group.main.name
  dns_prefix          = var.prefix
  kubernetes_version  = var.kubernetes_version
  node_resource_group = "${var.prefix}-aks-nodes-rg"
  sku_tier            = "Free"

  automatic_upgrade_channel = "patch"
  node_os_upgrade_channel   = "NodeImage"

  # Workload identity lets the backend read Key Vault without stored credentials.
  oidc_issuer_enabled       = true
  workload_identity_enabled = true

  # Entra ID auth + Azure RBAC for Kubernetes; no static admin kubeconfig.
  local_account_disabled            = true
  role_based_access_control_enabled = true
  azure_active_directory_role_based_access_control {
    azure_rbac_enabled = true
    tenant_id          = data.azurerm_client_config.current.tenant_id
  }

  default_node_pool {
    name                        = "system"
    vm_size                     = var.node_vm_size
    node_count                  = var.node_count
    os_disk_size_gb             = var.node_os_disk_size_gb
    os_disk_type                = "Managed"
    vnet_subnet_id              = azurerm_subnet.aks.id
    temporary_name_for_rotation = "systemtmp"

    upgrade_settings {
      max_surge = "1"
    }
  }

  # Fixed-size node pool we manage ourselves (no Karpenter node auto-provisioning).
  node_provisioning_profile {
    mode = "Manual"
  }

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.aks.id]
  }

  network_profile {
    network_plugin      = "azure"
    network_plugin_mode = "overlay"
    load_balancer_sku   = "standard"
    pod_cidr            = "192.168.0.0/16"
    service_cidr        = "172.16.0.0/16"
    dns_service_ip      = "172.16.0.10"
  }

  # Secrets Store CSI driver: mounts Key Vault secrets into pods.
  key_vault_secrets_provider {
    secret_rotation_enabled = true
  }

  # Container Insights agent. It authenticates with its managed identity; what it
  # collects is set by the data collection rule in monitoring.tf.
  oms_agent {
    log_analytics_workspace_id      = azurerm_log_analytics_workspace.main.id
    msi_auth_for_monitoring_enabled = true
  }

  tags = local.tags

  depends_on = [azurerm_role_assignment.aks_network]
}

# Optional: managed Gateway API CRDs + app-routing Istio implementation.
# azurerm has no arguments for these yet, so they're set through azapi
# (pattern from the AKS docs).
resource "azapi_update_resource" "gateway_api" {
  count = var.enable_gateway_api ? 1 : 0

  type        = "Microsoft.ContainerService/managedClusters@2026-03-01"
  resource_id = azurerm_kubernetes_cluster.main.id
  body = {
    properties = {
      ingressProfile = {
        gatewayAPI = {
          installation = "Standard"
        }
        webAppRouting = {
          gatewayAPIImplementations = {
            appRoutingIstio = {
              mode = "Enabled"
            }
          }
        }
      }
    }
  }
}
