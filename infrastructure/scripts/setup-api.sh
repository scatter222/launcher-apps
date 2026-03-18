#!/bin/bash
set -euo pipefail

# API Server Setup: Domain join + .NET Core API + Nginx
# Usage: setup-api.sh <credentials-file>
# Credentials file contains: DOMAIN, REALM, IPA_ADMIN_PASSWORD, ADMIN_USER, IPA_SERVER_IP
# Expects launcher-api-src.tar.gz in the admin user's home directory.

CREDS_FILE="$1"
source "${CREDS_FILE}"

HOSTNAME="api.${DOMAIN}"
IPA_SERVER="idm.${DOMAIN}"
HOME_DIR="/home/${ADMIN_USER}"

echo "=========================================="
echo " API Server Setup"
echo " Hostname: ${HOSTNAME}"
echo " Domain:   ${DOMAIN}"
echo "=========================================="

# -------------------------------------------------
# Step 1: Set hostname and DNS
# -------------------------------------------------
echo "[1/9] Configuring hostname and DNS..."

hostnamectl set-hostname "${HOSTNAME}"

# Point DNS at the FreeIPA server
cat > /etc/resolv.conf <<EOF
search ${DOMAIN}
nameserver ${IPA_SERVER_IP}
nameserver 168.63.129.16
EOF

# Prevent NetworkManager from overwriting resolv.conf
if [ -f /etc/NetworkManager/NetworkManager.conf ]; then
  grep -q "dns=none" /etc/NetworkManager/NetworkManager.conf || \
    sed -i '/\[main\]/a dns=none' /etc/NetworkManager/NetworkManager.conf
  systemctl restart NetworkManager || true
fi

# Add hosts entry as fallback
cat >> /etc/hosts <<EOF
${IPA_SERVER_IP}  ${IPA_SERVER} idm
10.0.1.11         ${HOSTNAME} api
10.0.1.12         ws1.${DOMAIN} ws1
EOF

# -------------------------------------------------
# Step 2: Install prerequisites
# -------------------------------------------------
echo "[2/9] Installing prerequisites..."

dnf install -y oracle-epel-release-el8
dnf install -y \
  ipa-client \
  krb5-workstation \
  nginx \
  curl \
  wget \
  jq \
  unzip \
  firewalld

# -------------------------------------------------
# Step 3: Join FreeIPA domain
# -------------------------------------------------
echo "[3/9] Joining FreeIPA domain..."

ipa-client-install \
  --unattended \
  --hostname="${HOSTNAME}" \
  --domain="${DOMAIN}" \
  --realm="${REALM}" \
  --server="${IPA_SERVER}" \
  --principal=admin \
  --password="${IPA_ADMIN_PASSWORD}" \
  --mkhomedir \
  --no-ntp \
  --force-join

echo "[3/9] Domain join successful."

# -------------------------------------------------
# Step 4: Generate keytab for API service
# -------------------------------------------------
echo "[4/9] Generating API service keytab..."

# IMPORTANT: The keytab MUST be generated AFTER ipa-client-install.
# Client enrollment changes the host keys in the KDC (bumps KVNO).
# Any keytab generated before enrollment will have a stale KVNO and
# Negotiate auth will fail with "GenericFailure".

# kinit using file redirect (pipe doesn't work with kinit on RHEL/OL8)
echo "${IPA_ADMIN_PASSWORD}" > /tmp/.ipapw
kinit admin < /tmp/.ipapw
rm -f /tmp/.ipapw

# Generate a fresh keytab with the current KVNO
ipa-getkeytab -s "${IPA_SERVER}" -p "HTTP/${HOSTNAME}" -k /etc/krb5.keytab.api

chmod 600 /etc/krb5.keytab.api

# Verify the keytab
klist -k /etc/krb5.keytab.api

kdestroy

echo "[4/9] Keytab generated and verified."

# -------------------------------------------------
# Step 5: Install .NET 8 SDK
# -------------------------------------------------
echo "[5/9] Installing .NET 8..."

dnf install -y dotnet-sdk-8.0 || {
  # Fallback: install from Microsoft repo
  rpm -Uvh https://packages.microsoft.com/config/rhel/8/packages-microsoft-prod.rpm || true
  dnf install -y dotnet-sdk-8.0
}

dotnet --version

# -------------------------------------------------
# Step 6: Extract source and build API
# -------------------------------------------------
echo "[6/9] Extracting source and building API..."

mkdir -p /opt/launcher-apps/src

# Extract the API source tarball uploaded by Terraform
tar xzf "${HOME_DIR}/launcher-api-src.tar.gz" -C /opt/launcher-apps/src/

cd /opt/launcher-apps/src/api

dotnet publish src/LauncherApi/LauncherApi.csproj \
  -c Release \
  -o /opt/launcher-api \
  --self-contained false

echo "[6/9] API built successfully."

# -------------------------------------------------
# Step 7: Create systemd service
# -------------------------------------------------
echo "[7/9] Creating systemd service..."

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
# Step 8: Configure Nginx reverse proxy
# -------------------------------------------------
echo "[8/9] Configuring Nginx..."

# Generate self-signed cert for HTTPS
mkdir -p /etc/nginx/ssl
openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout /etc/nginx/ssl/api.key \
  -out /etc/nginx/ssl/api.crt \
  -subj "/CN=${HOSTNAME}/O=LauncherEnv/C=AU"

cp "${HOME_DIR}/nginx-api.conf" /etc/nginx/conf.d/api.conf
rm -f /etc/nginx/conf.d/default.conf 2>/dev/null || true

# SELinux: allow nginx to proxy
setsebool -P httpd_can_network_connect 1 || true

# -------------------------------------------------
# Step 9: Configure firewall and start services
# -------------------------------------------------
echo "[9/9] Starting services..."

systemctl enable --now firewalld
firewall-cmd --permanent --add-service=https
firewall-cmd --permanent --add-service=http
firewall-cmd --permanent --add-port=443/tcp
firewall-cmd --reload

systemctl enable --now nginx
systemctl start launcher-api

# Verify
sleep 3
systemctl status launcher-api --no-pager || true
curl -s http://localhost:5000/api/health || echo "API not yet responding (may need a moment)"

# Clean up credentials and tarball
rm -f "${CREDS_FILE}"
rm -f "${HOME_DIR}/launcher-api-src.tar.gz"

echo "=========================================="
echo " API Server Setup Complete"
echo " API: https://${HOSTNAME}/api"
echo "=========================================="
