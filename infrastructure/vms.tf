# --- Oracle Linux VM Image ---
# Oracle Linux 8.x Gen2 from Azure Marketplace

locals {
  oracle_image = {
    publisher = "Oracle"
    offer     = "Oracle-Linux"
    sku       = "ol810-lvm-gen2"
    version   = "latest"
  }
}

# --- VM 1: Identity Server (FreeIPA + Keycloak) ---

resource "azurerm_linux_virtual_machine" "identity" {
  name                = "${var.instance_name}-identity"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  size                = var.vm_size
  admin_username      = var.admin_username

  network_interface_ids = [
    azurerm_network_interface.identity.id,
  ]

  disable_password_authentication = true

  admin_ssh_key {
    username   = var.admin_username
    public_key = var.ssh_public_key
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Premium_LRS"
    disk_size_gb         = var.disk_size_gb
  }

  source_image_reference {
    publisher = local.oracle_image.publisher
    offer     = local.oracle_image.offer
    sku       = local.oracle_image.sku
    version   = local.oracle_image.version
  }

  tags = {
    environment = "testing"
    managed_by  = "terraform"
    role        = "identity-server"
  }
}

# --- VM 2: API Server (.NET Core API) ---

resource "azurerm_linux_virtual_machine" "api" {
  name                = "${var.instance_name}-api"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  size                = var.vm_size
  admin_username      = var.admin_username

  network_interface_ids = [
    azurerm_network_interface.api.id,
  ]

  disable_password_authentication = true

  admin_ssh_key {
    username   = var.admin_username
    public_key = var.ssh_public_key
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Premium_LRS"
    disk_size_gb         = var.disk_size_gb
  }

  source_image_reference {
    publisher = local.oracle_image.publisher
    offer     = local.oracle_image.offer
    sku       = local.oracle_image.sku
    version   = local.oracle_image.version
  }

  tags = {
    environment = "testing"
    managed_by  = "terraform"
    role        = "api-server"
  }
}

# --- VM 3: Workstation (Electron Launcher) ---

resource "azurerm_linux_virtual_machine" "workstation" {
  name                = "${var.instance_name}-workstation"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  size                = var.vm_size
  admin_username      = var.admin_username

  network_interface_ids = [
    azurerm_network_interface.workstation.id,
  ]

  disable_password_authentication = true

  admin_ssh_key {
    username   = var.admin_username
    public_key = var.ssh_public_key
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Premium_LRS"
    disk_size_gb         = var.disk_size_gb
  }

  source_image_reference {
    publisher = local.oracle_image.publisher
    offer     = local.oracle_image.offer
    sku       = local.oracle_image.sku
    version   = local.oracle_image.version
  }

  tags = {
    environment = "testing"
    managed_by  = "terraform"
    role        = "workstation"
  }
}
