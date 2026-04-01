variable "instance_name" {
  description = "Name prefix for all Azure resources."
  type        = string
  default     = "launcher-env"
}

variable "location" {
  description = "Azure region for all resources."
  type        = string
  default     = "australiaeast"
}

variable "server_vm_size" {
  description = "Azure VM size for the server (needs nested virt + RAM for KVM guests)."
  type        = string
  default     = "Standard_D8s_v3"
}

variable "server_disk_size_gb" {
  description = "Server OS disk size in GB (stores KVM base images + overlays)."
  type        = number
  default     = 256
}

variable "vm_size" {
  description = "Azure VM size for the workstation."
  type        = string
  default     = "Standard_D4s_v3"
}

variable "disk_size_gb" {
  description = "Workstation OS disk size in GB."
  type        = number
  default     = 128
}

variable "admin_username" {
  description = "VM admin username."
  type        = string
  default     = "azureuser"
}

variable "ssh_public_key" {
  description = "SSH public key for VM authentication."
  type        = string
}

variable "ssh_private_key_path" {
  description = "Path to the SSH private key for provisioner connections."
  type        = string
  default     = "~/.ssh/id_rsa"
}

variable "domain_name" {
  description = "FreeIPA domain name."
  type        = string
  default     = "lab.forge.local"
}

variable "kerberos_realm" {
  description = "Kerberos realm (uppercase of domain)."
  type        = string
  default     = "LAB.FORGE.LOCAL"
}

variable "ipa_admin_password" {
  description = "FreeIPA admin password."
  type        = string
  sensitive   = true
}

variable "ipa_ds_password" {
  description = "FreeIPA Directory Server password."
  type        = string
  sensitive   = true
}

