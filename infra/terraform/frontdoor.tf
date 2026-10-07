# Azure Front Door (Standard) in front of the frontend LoadBalancer: gives the app an
# HTTPS URL (<endpoint>-<hash>.z01.azurefd.net) with a Microsoft-managed certificate,
# no custom domain needed. TLS ends at Front Door; Front Door -> origin is HTTP.
#
# The origin is the frontend Service's public IP, reached via the Azure DNS label
# the Helm chart puts on it (<label>.<region>.cloudapp.azure.com). The Service only
# accepts traffic from the AzureFrontDoor.Backend service tag, and nginx rejects
# requests whose X-Azure-FDID header isn't this profile's ID.

locals {
  # Must be unique within the region; the random suffix takes care of that.
  frontend_dns_label = "${var.prefix}-${local.suffix}"
  frontend_origin    = "${local.frontend_dns_label}.${var.location}.cloudapp.azure.com"
}

resource "azurerm_cdn_frontdoor_profile" "main" {
  count = var.enable_front_door ? 1 : 0

  name                = "${var.prefix}-afd"
  resource_group_name = data.azurerm_resource_group.main.name
  sku_name            = "Standard_AzureFrontDoor"
  tags                = local.tags

  lifecycle {
    # Front Door targets the frontend LoadBalancer, which gateway mode replaces.
    precondition {
      condition     = !(var.enable_front_door && var.enable_gateway_api)
      error_message = "enable_front_door targets the frontend LoadBalancer; it can't be combined with enable_gateway_api."
    }
  }
}

resource "azurerm_cdn_frontdoor_endpoint" "main" {
  count = var.enable_front_door ? 1 : 0

  name                     = "${var.prefix}-${local.suffix}"
  cdn_frontdoor_profile_id = azurerm_cdn_frontdoor_profile.main[0].id
  tags                     = local.tags
}

resource "azurerm_cdn_frontdoor_origin_group" "frontend" {
  count = var.enable_front_door ? 1 : 0

  name                     = "frontend"
  cdn_frontdoor_profile_id = azurerm_cdn_frontdoor_profile.main[0].id

  load_balancing {}

  # nginx answers /healthz without the X-Azure-FDID check.
  health_probe {
    protocol            = "Http"
    path                = "/healthz"
    request_type        = "HEAD"
    interval_in_seconds = 60
  }
}

resource "azurerm_cdn_frontdoor_origin" "frontend" {
  count = var.enable_front_door ? 1 : 0

  name                          = "aks-frontend"
  cdn_frontdoor_origin_group_id = azurerm_cdn_frontdoor_origin_group.frontend[0].id
  host_name                     = local.frontend_origin
  origin_host_header            = local.frontend_origin
  http_port                     = 80
  https_port                    = 443
  # The origin is plain HTTP, so there's no certificate to check.
  certificate_name_check_enabled = false
}

resource "azurerm_cdn_frontdoor_route" "frontend" {
  count = var.enable_front_door ? 1 : 0

  name                          = "frontend"
  cdn_frontdoor_endpoint_id     = azurerm_cdn_frontdoor_endpoint.main[0].id
  cdn_frontdoor_origin_group_id = azurerm_cdn_frontdoor_origin_group.frontend[0].id
  cdn_frontdoor_origin_ids      = [azurerm_cdn_frontdoor_origin.frontend[0].id]

  patterns_to_match      = ["/*"]
  supported_protocols    = ["Http", "Https"]
  https_redirect_enabled = true
  forwarding_protocol    = "HttpOnly"
  link_to_default_domain = true
  # No cache block: the API is dynamic, so nothing is cached at the edge.
}
