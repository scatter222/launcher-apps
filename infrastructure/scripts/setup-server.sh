#!/bin/bash
set -euo pipefail

# Server Setup: FreeIPA + .NET Core API + Nginx + KVM/libvirt + Keycloak
# This is the single server VM that provides identity, API, and remote VM hosting.
# Usage: setup-server.sh <credentials-file>

CREDS_FILE="$1"
source "${CREDS_FILE}"

# Background heartbeat to keep SSH alive during long operations.
(while true; do echo "... heartbeat $(date +%H:%M:%S)"; sleep 60; done) &
HEARTBEAT_PID=$!
trap "kill ${HEARTBEAT_PID} 2>/dev/null" EXIT

HOSTNAME="idm.${DOMAIN}"
PRIVATE_IP="10.0.1.10"
WS_IP="10.0.1.11"
HOME_DIR="/home/${ADMIN_USER}"

echo "=========================================="
echo " Server Setup (FreeIPA + API + KVM)"
echo " Domain: ${DOMAIN}"
echo " Realm:  ${REALM}"
echo "=========================================="

# -------------------------------------------------
# Step 1: Set hostname and /etc/hosts
# -------------------------------------------------
echo "[1/14] Configuring hostname and hosts file..."

hostnamectl set-hostname "${HOSTNAME}"

cat >> /etc/hosts <<EOF
${PRIVATE_IP}  ${HOSTNAME} idm
${PRIVATE_IP}  api.${DOMAIN} api
${WS_IP}       ws1.${DOMAIN} ws1
EOF

# -------------------------------------------------
# Step 2: Install prerequisites
# -------------------------------------------------
echo "[2/14] Installing prerequisites..."

dnf install -y oracle-epel-release-el8

# Clean up /boot before distro-sync
rm -f /boot/initramfs-0-rescue-*.img 2>/dev/null || true
dnf install -y dnf-utils || true
package-cleanup --oldkernels --count=1 -y 2>/dev/null || true
dnf clean all

dnf module enable -y idm:DL1
dnf distro-sync -y

dnf install -y \
  @idm:DL1/dns \
  ipa-server \
  ipa-server-dns \
  bind-dyndb-ldap \
  openldap-clients \
  firewalld \
  nginx \
  bind-utils \
  curl \
  wget \
  jq \
  unzip \
  policycoreutils-python-utils \
  qemu-kvm \
  libvirt \
  libvirt-devel \
  virt-install \
  libguestfs-tools

# -------------------------------------------------
# Step 3: Configure firewall
# -------------------------------------------------
echo "[3/14] Configuring firewall..."

systemctl enable --now firewalld

firewall-cmd --permanent --add-service=freeipa-ldap
firewall-cmd --permanent --add-service=freeipa-ldaps
firewall-cmd --permanent --add-service=freeipa-replication
firewall-cmd --permanent --add-service=freeipa-trust
firewall-cmd --permanent --add-service=dns
firewall-cmd --permanent --add-service=ntp
firewall-cmd --permanent --add-service=http
firewall-cmd --permanent --add-service=https
firewall-cmd --permanent --add-port=88/tcp
firewall-cmd --permanent --add-port=88/udp
firewall-cmd --permanent --add-port=464/tcp
firewall-cmd --permanent --add-port=464/udp
firewall-cmd --permanent --add-port=9444/tcp
firewall-cmd --permanent --add-port=9080/tcp
firewall-cmd --permanent --add-port=9443/tcp
firewall-cmd --reload

# -------------------------------------------------
# Step 4: Install FreeIPA server
# -------------------------------------------------
echo "[4/14] Installing FreeIPA server (this takes a while)..."

ipa-server-install \
  --unattended \
  --hostname="${HOSTNAME}" \
  --domain="${DOMAIN}" \
  --realm="${REALM}" \
  --ds-password="${IPA_DS_PASSWORD}" \
  --admin-password="${IPA_ADMIN_PASSWORD}" \
  --setup-dns \
  --no-forwarders \
  --allow-zone-overlap \
  --no-ntp

echo "[4/14] FreeIPA server installed successfully."

cat > /etc/resolv.conf <<EOF
search ${DOMAIN}
nameserver 127.0.0.1
nameserver 168.63.129.16
EOF

if [ -f /etc/NetworkManager/NetworkManager.conf ]; then
  grep -q "dns=none" /etc/NetworkManager/NetworkManager.conf || \
    sed -i '/\[main\]/a dns=none' /etc/NetworkManager/NetworkManager.conf
  systemctl restart NetworkManager || true
fi

# -------------------------------------------------
# Step 5: Configure DNS records
# -------------------------------------------------
echo "[5/14] Adding DNS records..."

echo "${IPA_ADMIN_PASSWORD}" > /tmp/.ipapw
kinit admin < /tmp/.ipapw
rm -f /tmp/.ipapw

ipa dnsconfig-mod --forwarder=168.63.129.16 || true

# api.DOMAIN points to self (10.0.1.10) — API is co-hosted
ipa dnsrecord-add "${DOMAIN}" api --a-rec="${PRIVATE_IP}" || true
ipa dnsrecord-add "${DOMAIN}" ws1 --a-rec="${WS_IP}" || true

# Reverse zone
ipa dnszone-add 1.0.10.in-addr.arpa. || true
ipa dnsrecord-add 1.0.10.in-addr.arpa. 10 --ptr-rec="${HOSTNAME}." || true
ipa dnsrecord-add 1.0.10.in-addr.arpa. 11 --ptr-rec="ws1.${DOMAIN}." || true

# -------------------------------------------------
# Step 6: Create service principal and test users
# -------------------------------------------------
echo "[6/14] Creating service principal and test users..."

# Host entry for the API hostname (points to self)
ipa host-add "api.${DOMAIN}" --force --no-reverse || true

# HTTP service principal for the API
ipa service-add "HTTP/api.${DOMAIN}" || true
ipa service-allow-retrieve-keytab "HTTP/api.${DOMAIN}" --hosts="api.${DOMAIN}" || true

# Test users
ipa user-add testuser --first=Test --last=User || true
ipa user-add launcheruser --first=Launcher --last=User || true

# Set passwords via LDAP directory manager (permanent, no first-login change)
LDAP_BASE="dc=$(echo "${DOMAIN}" | sed 's/\./,dc=/g')"

ldappasswd -x -D "cn=Directory Manager" -w "${IPA_DS_PASSWORD}" \
  -s "${IPA_ADMIN_PASSWORD}" \
  "uid=testuser,cn=users,cn=accounts,${LDAP_BASE}"

ldappasswd -x -D "cn=Directory Manager" -w "${IPA_DS_PASSWORD}" \
  -s "${IPA_ADMIN_PASSWORD}" \
  "uid=launcheruser,cn=users,cn=accounts,${LDAP_BASE}"

ldapmodify -x -D "cn=Directory Manager" -w "${IPA_DS_PASSWORD}" <<LDIF
dn: uid=testuser,cn=users,cn=accounts,${LDAP_BASE}
changetype: modify
replace: krbPasswordExpiration
krbPasswordExpiration: 20301231235959Z

dn: uid=launcheruser,cn=users,cn=accounts,${LDAP_BASE}
changetype: modify
replace: krbPasswordExpiration
krbPasswordExpiration: 20301231235959Z
LDIF

echo "[6/14] Service principal and test users created."

# -------------------------------------------------
# Step 7: Generate API keytab
# -------------------------------------------------
echo "[7/14] Generating API service keytab..."

# On the IPA server itself, the keytab can be generated directly after
# creating the service principal. No domain-join/KVNO dance needed.
ipa-getkeytab -s "${HOSTNAME}" -p "HTTP/api.${DOMAIN}" -k /etc/krb5.keytab.api

chmod 600 /etc/krb5.keytab.api
klist -k /etc/krb5.keytab.api

echo "[7/14] Keytab generated and verified."

# -------------------------------------------------
# Step 8: Install Docker + start Keycloak
# -------------------------------------------------
echo "[8/14] Installing Docker and starting Keycloak..."

dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
dnf install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin

systemctl enable --now docker
usermod -aG docker "${ADMIN_USER}"

cd "${HOME_DIR}"
sed -i "s|__DOMAIN__|${DOMAIN}|g" docker-compose.keycloak.yml
sed -i "s|__HOSTNAME__|${HOSTNAME}|g" docker-compose.keycloak.yml
docker compose -f docker-compose.keycloak.yml up -d

# -------------------------------------------------
# Step 9: Install .NET 8 SDK
# -------------------------------------------------
echo "[9/14] Installing .NET 8..."

dnf install -y dotnet-sdk-8.0 || {
  rpm -Uvh https://packages.microsoft.com/config/rhel/8/packages-microsoft-prod.rpm || true
  dnf install -y dotnet-sdk-8.0
}

dotnet --version

# -------------------------------------------------
# Step 10: Extract source and build API
# -------------------------------------------------
echo "[10/14] Extracting source and building API..."

mkdir -p /opt/launcher-apps/src
tar xzf "${HOME_DIR}/launcher-api-src.tar.gz" -C /opt/launcher-apps/src/

cd /opt/launcher-apps/src/api

dotnet publish src/LauncherApi/LauncherApi.csproj \
  -c Release \
  -o /opt/launcher-api \
  --self-contained false

echo "[10/14] API built successfully."

# -------------------------------------------------
# Step 11: Create systemd service for API
# -------------------------------------------------
echo "[11/14] Creating API systemd service..."

cat > /etc/systemd/system/launcher-api.service <<EOF
[Unit]
Description=Launcher API (.NET Core)
After=network.target

[Service]
WorkingDirectory=/opt/launcher-api
ExecStart=/opt/launcher-api/LauncherApi
Environment=ASPNETCORE_URLS=http://0.0.0.0:5000
Environment=ASPNETCORE_ENVIRONMENT=Production
Environment=KRB5_KTNAME=/etc/krb5.keytab.api
Restart=always
RestartSec=5
SyslogIdentifier=launcher-api

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable launcher-api

# -------------------------------------------------
# Step 12: Configure Nginx reverse proxy
# -------------------------------------------------
echo "[12/14] Configuring Nginx..."

mkdir -p /etc/nginx/ssl
openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout /etc/nginx/ssl/api.key \
  -out /etc/nginx/ssl/api.crt \
  -subj "/CN=api.${DOMAIN}/O=LauncherEnv/C=AU"

cp "${HOME_DIR}/nginx-api.conf" /etc/nginx/conf.d/api.conf
rm -f /etc/nginx/conf.d/default.conf 2>/dev/null || true

# SELinux: allow nginx to proxy and bind to port 9444
setsebool -P httpd_can_network_connect 1 || true
semanage port -a -t http_port_t -p tcp 9444 2>/dev/null || \
  semanage port -m -t http_port_t -p tcp 9444 2>/dev/null || true

# -------------------------------------------------
# Step 13: Install and configure KVM/libvirt
# -------------------------------------------------
echo "[13/14] Configuring KVM/libvirt..."

systemctl enable --now libvirtd

# Verify nested virtualization is available
if [ -e /dev/kvm ]; then
  echo "KVM device found — nested virtualization available."
else
  echo "WARNING: /dev/kvm not found — remote VMs will not work."
fi

# Create directory structure for VM management
mkdir -p /var/lib/libvirt/images/base
mkdir -p /var/lib/libvirt/images/instances

# Ensure the default libvirt network is active
virsh net-start default 2>/dev/null || true
virsh net-autostart default 2>/dev/null || true

# SELinux: allow VMs to use network
setsebool -P virt_sandbox_use_all_caps on 2>/dev/null || true

echo "[13/14] KVM/libvirt configured."

# -------------------------------------------------
# Step 14: Start services and verify
# -------------------------------------------------
echo "[14/14] Starting services..."

firewall-cmd --permanent --add-service=https
firewall-cmd --permanent --add-service=http
firewall-cmd --permanent --add-port=443/tcp
firewall-cmd --reload

systemctl enable --now nginx
systemctl start launcher-api

sleep 3
systemctl status launcher-api --no-pager || true
curl -s http://localhost:5000/api/health || echo "API not yet responding (may need a moment)"

# Clean up
rm -f "${CREDS_FILE}"
rm -f "${HOME_DIR}/launcher-api-src.tar.gz"

echo "=========================================="
echo " Server Setup Complete"
echo " FreeIPA:  https://${HOSTNAME}"
echo " API:      https://api.${DOMAIN}/api"
echo " Keycloak: http://${HOSTNAME}:9080"
echo " KVM:      $(virsh version --daemon 2>/dev/null | head -1 || echo 'not available')"
echo "=========================================="
