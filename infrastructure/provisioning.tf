# --- Provisioning ---
# Identity server must be provisioned first (FreeIPA provides DNS + KDC),
# then API server (domain join + API deploy),
# then workstation (domain join + launcher install).
#
# Source code is uploaded via tar archives (no git clone needed).
# Credentials are written to a file to avoid sensitive vars in command line
# (Terraform suppresses ALL output when sensitive vars are in inline commands).

# --- Create source tarballs locally ---

resource "null_resource" "create_api_tarball" {
  triggers = {
    always = timestamp()
  }

  provisioner "local-exec" {
    command     = "tar czf /tmp/launcher-api-src.tar.gz -C ${path.module}/.. api/"
    interpreter = ["bash", "-c"]
  }
}

resource "null_resource" "create_launcher_tarball" {
  triggers = {
    always = timestamp()
  }

  provisioner "local-exec" {
    command     = "tar czf /tmp/launcher-ui-src.tar.gz -C ${path.module}/.. libvirt-ui/"
    interpreter = ["bash", "-c"]
  }
}

# --- Identity Server Provisioning ---

resource "null_resource" "provision_identity" {
  triggers = {
    vm_id       = azurerm_linux_virtual_machine.identity.id
    setup_sha   = filebase64sha256("${path.module}/scripts/setup-identity.sh")
    compose_sha = filebase64sha256("${path.module}/docker-compose.keycloak.yml")
  }

  connection {
    type        = "ssh"
    user        = var.admin_username
    private_key = file(var.ssh_private_key_path)
    host        = azurerm_public_ip.identity.ip_address
    timeout     = "30m"
  }

  # Upload credentials file (avoids sensitive vars on command line)
  provisioner "file" {
    content = join("\n", [
      "DOMAIN=${var.domain_name}",
      "REALM=${var.kerberos_realm}",
      "IPA_ADMIN_PASSWORD=${var.ipa_admin_password}",
      "IPA_DS_PASSWORD=${var.ipa_ds_password}",
      "ADMIN_USER=${var.admin_username}",
    ])
    destination = "/home/${var.admin_username}/.setup-creds"
  }

  provisioner "file" {
    source      = "${path.module}/scripts/setup-identity.sh"
    destination = "/home/${var.admin_username}/setup-identity.sh"
  }

  provisioner "file" {
    source      = "${path.module}/docker-compose.keycloak.yml"
    destination = "/home/${var.admin_username}/docker-compose.keycloak.yml"
  }

  # Run script with output logging. The script produces regular output which
  # keeps the SSH connection alive. Logging to file provides a record if
  # troubleshooting is needed.
  provisioner "remote-exec" {
    inline = [
      "chmod +x /home/${var.admin_username}/setup-identity.sh",
      "sudo bash -c '/home/${var.admin_username}/setup-identity.sh /home/${var.admin_username}/.setup-creds 2>&1 | tee /var/log/setup-identity.log'",
    ]
  }

  depends_on = [azurerm_linux_virtual_machine.identity]
}

# --- API Server Provisioning ---

resource "null_resource" "provision_api" {
  triggers = {
    vm_id     = azurerm_linux_virtual_machine.api.id
    setup_sha = filebase64sha256("${path.module}/scripts/setup-api.sh")
    nginx_sha = filebase64sha256("${path.module}/nginx-api.conf")
  }

  connection {
    type        = "ssh"
    user        = var.admin_username
    private_key = file(var.ssh_private_key_path)
    host        = azurerm_public_ip.api.ip_address
    timeout     = "20m"
  }

  # Upload credentials file
  provisioner "file" {
    content = join("\n", [
      "DOMAIN=${var.domain_name}",
      "REALM=${var.kerberos_realm}",
      "IPA_ADMIN_PASSWORD=${var.ipa_admin_password}",
      "ADMIN_USER=${var.admin_username}",
      "IPA_SERVER_IP=10.0.1.10",
    ])
    destination = "/home/${var.admin_username}/.setup-creds"
  }

  provisioner "file" {
    source      = "${path.module}/scripts/setup-api.sh"
    destination = "/home/${var.admin_username}/setup-api.sh"
  }

  provisioner "file" {
    source      = "${path.module}/nginx-api.conf"
    destination = "/home/${var.admin_username}/nginx-api.conf"
  }

  # Upload API source tarball
  provisioner "file" {
    source      = "/tmp/launcher-api-src.tar.gz"
    destination = "/home/${var.admin_username}/launcher-api-src.tar.gz"
  }

  provisioner "remote-exec" {
    inline = [
      "chmod +x /home/${var.admin_username}/setup-api.sh",
      "sudo bash -c '/home/${var.admin_username}/setup-api.sh /home/${var.admin_username}/.setup-creds 2>&1 | tee /var/log/setup-api.log'",
    ]
  }

  # API server depends on identity server being ready + tarball existing
  depends_on = [
    azurerm_linux_virtual_machine.api,
    null_resource.provision_identity,
    null_resource.create_api_tarball,
  ]
}

# --- Workstation Provisioning ---

resource "null_resource" "provision_workstation" {
  triggers = {
    vm_id     = azurerm_linux_virtual_machine.workstation.id
    setup_sha = filebase64sha256("${path.module}/scripts/setup-workstation.sh")
  }

  connection {
    type        = "ssh"
    user        = var.admin_username
    private_key = file(var.ssh_private_key_path)
    host        = azurerm_public_ip.workstation.ip_address
    timeout     = "30m"
  }

  # Upload credentials file
  provisioner "file" {
    content = join("\n", [
      "DOMAIN=${var.domain_name}",
      "REALM=${var.kerberos_realm}",
      "IPA_ADMIN_PASSWORD=${var.ipa_admin_password}",
      "ADMIN_USER=${var.admin_username}",
      "IPA_SERVER_IP=10.0.1.10",
    ])
    destination = "/home/${var.admin_username}/.setup-creds"
  }

  provisioner "file" {
    source      = "${path.module}/scripts/setup-workstation.sh"
    destination = "/home/${var.admin_username}/setup-workstation.sh"
  }

  # Upload launcher UI source tarball
  provisioner "file" {
    source      = "/tmp/launcher-ui-src.tar.gz"
    destination = "/home/${var.admin_username}/launcher-ui-src.tar.gz"
  }

  # Workstation setup is the longest (~30+ min) due to "Server with GUI" group install.
  # Output is tee'd to log file for troubleshooting.
  provisioner "remote-exec" {
    inline = [
      "chmod +x /home/${var.admin_username}/setup-workstation.sh",
      "sudo bash -c '/home/${var.admin_username}/setup-workstation.sh /home/${var.admin_username}/.setup-creds 2>&1 | tee /var/log/setup-workstation.log'",
    ]
  }

  # Workstation depends on identity server being ready + tarball existing
  depends_on = [
    azurerm_linux_virtual_machine.workstation,
    null_resource.provision_identity,
    null_resource.create_launcher_tarball,
  ]
}
