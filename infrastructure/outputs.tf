output "server_public_ip" {
  description = "Public IP of the Server (FreeIPA + API + KVM)."
  value       = azurerm_public_ip.server.ip_address
}

output "workstation_public_ip" {
  description = "Public IP of the Workstation."
  value       = azurerm_public_ip.workstation.ip_address
}

output "ssh_server" {
  description = "SSH command for Server."
  value       = "ssh ${var.admin_username}@${azurerm_public_ip.server.ip_address}"
}

output "ssh_workstation" {
  description = "SSH command for Workstation."
  value       = "ssh ${var.admin_username}@${azurerm_public_ip.workstation.ip_address}"
}

output "api_url" {
  description = "API Server HTTPS URL."
  value       = "https://api.${var.domain_name}"
}

output "freeipa_url" {
  description = "FreeIPA Web UI."
  value       = "https://${azurerm_public_ip.server.ip_address}"
}

output "keycloak_url" {
  description = "Keycloak admin console."
  value       = "http://${azurerm_public_ip.server.ip_address}:9080"
}
