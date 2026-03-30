#!/bin/bash
set -euo pipefail

# Identity Server Setup: FreeIPA + Keycloak
# Usage: setup-identity.sh <credentials-file>
# Credentials file contains: DOMAIN, REALM, IPA_ADMIN_PASSWORD, IPA_DS_PASSWORD, ADMIN_USER

CREDS_FILE="$1"
source "${CREDS_FILE}"

HOSTNAME="idm.${DOMAIN}"
PRIVATE_IP="10.0.1.10"
API_IP="10.0.1.11"
WS_IP="10.0.1.12"

echo "=========================================="
echo " Identity Server Setup"
echo " Domain: ${DOMAIN}"
echo " Realm:  ${REALM}"
echo "=========================================="

# -------------------------------------------------
# Step 1: Set hostname and /etc/hosts
# -------------------------------------------------
echo "[1/8] Configuring hostname and hosts file..."

hostnamectl set-hostname "${HOSTNAME}"

cat >> /etc/hosts <<EOF
${PRIVATE_IP}  ${HOSTNAME} idm
${API_IP}      api.${DOMAIN} api
${WS_IP}       ws1.${DOMAIN} ws1
EOF

# -------------------------------------------------
# Step 2: Install prerequisites
# -------------------------------------------------
echo "[2/8] Installing prerequisites..."

dnf install -y oracle-epel-release-el8

# Clean up /boot before distro-sync to prevent "No space left on device" errors.
# Oracle Linux LVM images have a small /boot partition (~800MB) that fills up
# when dnf distro-sync installs new kernels + dracut regenerates initramfs.
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
  curl \
  wget \
  jq \
  unzip

# -------------------------------------------------
# Step 3: Configure firewall
# -------------------------------------------------
echo "[3/8] Configuring firewall..."

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
firewall-cmd --permanent --add-port=9080/tcp
firewall-cmd --permanent --add-port=9443/tcp
firewall-cmd --reload

# -------------------------------------------------
# Step 4: Install FreeIPA server
# -------------------------------------------------
echo "[4/8] Installing FreeIPA server (this takes a while)..."

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

echo "[4/8] FreeIPA server installed successfully."

# After FreeIPA install, this server uses itself for DNS.
# Add Azure DNS as a global forwarder so external names (docker.com, etc.) resolve.
# Also ensure resolv.conf has a fallback.
cat > /etc/resolv.conf <<EOF
search ${DOMAIN}
nameserver 127.0.0.1
nameserver 168.63.129.16
EOF

# Prevent NetworkManager from overwriting resolv.conf
if [ -f /etc/NetworkManager/NetworkManager.conf ]; then
  grep -q "dns=none" /etc/NetworkManager/NetworkManager.conf || \
    sed -i '/\[main\]/a dns=none' /etc/NetworkManager/NetworkManager.conf
  systemctl restart NetworkManager || true
fi

# -------------------------------------------------
# Step 5: Configure DNS records for other VMs
# -------------------------------------------------
echo "[5/8] Adding DNS records..."

# kinit using file redirect (pipe doesn't work with kinit on RHEL/OL8)
echo "${IPA_ADMIN_PASSWORD}" > /tmp/.ipapw
kinit admin < /tmp/.ipapw
rm -f /tmp/.ipapw

# Add Azure DNS as a global forwarder in FreeIPA so all VMs can resolve external names
ipa dnsconfig-mod --forwarder=168.63.129.16 || true

# Add A records for API server and workstation
ipa dnsrecord-add "${DOMAIN}" api --a-rec="${API_IP}" || true
ipa dnsrecord-add "${DOMAIN}" ws1 --a-rec="${WS_IP}" || true

# Add reverse zone and PTR records
ipa dnszone-add 1.0.10.in-addr.arpa. || true
ipa dnsrecord-add 1.0.10.in-addr.arpa. 10 --ptr-rec="${HOSTNAME}." || true
ipa dnsrecord-add 1.0.10.in-addr.arpa. 11 --ptr-rec="api.${DOMAIN}." || true
ipa dnsrecord-add 1.0.10.in-addr.arpa. 12 --ptr-rec="ws1.${DOMAIN}." || true

# -------------------------------------------------
# Step 6: Create service principal and test users
# -------------------------------------------------
echo "[6/8] Creating service principal and test users..."

# Pre-create the host entry for the API server (required before adding a service)
# Use --force --no-reverse because DNS A record already exists
ipa host-add "api.${DOMAIN}" --force --no-reverse || true

# Create the HTTP service principal for the API
ipa service-add "HTTP/api.${DOMAIN}" || true

# Allow any host to retrieve the keytab (so the API server can fetch its own after enrollment)
ipa service-allow-retrieve-keytab "HTTP/api.${DOMAIN}" --hosts="api.${DOMAIN}" || true

# Create test user accounts
ipa user-add testuser --first=Test --last=User || true
ipa user-add launcheruser --first=Launcher --last=User || true

# Set passwords via LDAP directory manager to bypass the "must change on first login" flag.
# ipa passwd sets a temporary password that kinit rejects until changed interactively.
# ldappasswd with Directory Manager sets a permanent password directly.

LDAP_BASE="dc=$(echo "${DOMAIN}" | sed 's/\./,dc=/g')"

ldappasswd -x -D "cn=Directory Manager" -w "${IPA_DS_PASSWORD}" \
  -s "${IPA_ADMIN_PASSWORD}" \
  "uid=testuser,cn=users,cn=accounts,${LDAP_BASE}"

ldappasswd -x -D "cn=Directory Manager" -w "${IPA_DS_PASSWORD}" \
  -s "${IPA_ADMIN_PASSWORD}" \
  "uid=launcheruser,cn=users,cn=accounts,${LDAP_BASE}"

# Extend password expiration so kinit doesn't reject the password
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

echo "[6/8] Service principal and test users created."

# -------------------------------------------------
# Step 7: Install Docker for Keycloak
# -------------------------------------------------
echo "[7/8] Installing Docker..."

dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
dnf install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin

systemctl enable --now docker
usermod -aG docker "${ADMIN_USER}"

# -------------------------------------------------
# Step 8: Start Keycloak via Docker Compose
# -------------------------------------------------
echo "[8/8] Starting Keycloak..."

cd "/home/${ADMIN_USER}"

# Update docker-compose with the correct domain
sed -i "s|__DOMAIN__|${DOMAIN}|g" docker-compose.keycloak.yml
sed -i "s|__HOSTNAME__|${HOSTNAME}|g" docker-compose.keycloak.yml

docker compose -f docker-compose.keycloak.yml up -d

# Clean up credentials file
rm -f "${CREDS_FILE}"

echo "=========================================="
echo " Identity Server Setup Complete"
echo " FreeIPA:  https://${HOSTNAME}"
echo " Keycloak: http://${HOSTNAME}:9080"
echo "=========================================="
