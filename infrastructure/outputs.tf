output "identity_public_ip" {
  description = "Public IP of the Identity Server (FreeIPA + Keycloak)."
  value       = azurerm_public_ip.identity.ip_address
}

output "api_public_ip" {
  description = "Public IP of the API Server."
  value       = azurerm_public_ip.api.ip_address
}

output "workstation_public_ip" {
  description = "Public IP of the Workstation."
  value       = azurerm_public_ip.workstation.ip_address
}

output "ssh_identity" {
  description = "SSH command for Identity Server."
  value       = "ssh ${var.admin_username}@${azurerm_public_ip.identity.ip_address}"
}

output "ssh_api" {
  description = "SSH command for API Server."
  value       = "ssh ${var.admin_username}@${azurerm_public_ip.api.ip_address}"
}

output "ssh_workstation" {
  description = "SSH command for Workstation."
  value       = "ssh ${var.admin_username}@${azurerm_public_ip.workstation.ip_address}"
}

output "api_url" {
  description = "API Server HTTPS URL."
  value       = "https://${azurerm_public_ip.api.ip_address}"
}

output "freeipa_url" {
  description = "FreeIPA Web UI."
  value       = "https://${azurerm_public_ip.identity.ip_address}"
}

output "keycloak_url" {
  description = "Keycloak admin console."
  value       = "http://${azurerm_public_ip.identity.ip_address}:9080"
}
