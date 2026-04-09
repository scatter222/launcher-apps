#!/bin/bash
set -euo pipefail

# FreeIPA Server Setup — runs inside a KVM guest VM via cloud-init.
# This script installs FreeIPA with integrated DNS and creates the
# service principals, DNS records, and test users needed by the environment.
#
# Usage: setup-freeipa-vm.sh <credentials-file>
# Credentials file contains: DOMAIN, REALM, IPA_ADMIN_PASSWORD, IPA_DS_PASSWORD,
#                             HOST_IP, WS_IP

CREDS_FILE="$1"
source "${CREDS_FILE}"

HOSTNAME="idm.${DOMAIN}"

echo "=========================================="
echo " FreeIPA VM Setup"
echo " Hostname: ${HOSTNAME}"
echo " Domain:   ${DOMAIN}"
echo " Realm:    ${REALM}"
echo "=========================================="

# -------------------------------------------------
# Step 1: Set hostname
# -------------------------------------------------
echo "[1/6] Configuring hostname..."

hostnamectl set-hostname "${HOSTNAME}"

# Ensure /etc/hosts has the correct FQDN mapping for the guest's own IP.
# cloud-init may have set this already, but be explicit.
sed -i '/idm/d' /etc/hosts 2>/dev/null || true
cat >> /etc/hosts <<EOF
192.168.122.10  ${HOSTNAME} idm
${HOST_IP}      api.${DOMAIN} api srv.${DOMAIN} srv
${WS_IP}        ws1.${DOMAIN} ws1
EOF

# -------------------------------------------------
# Step 2: Install FreeIPA packages
# -------------------------------------------------
echo "[2/6] Installing FreeIPA packages..."

dnf install -y oracle-epel-release-el8 || true

# Clean /boot to prevent space issues during distro-sync
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
  firewalld

# -------------------------------------------------
# Step 3: Configure firewall
# -------------------------------------------------
echo "[3/6] Configuring firewall..."

# Restart dbus first — cloud-init environments may not have it fully ready,
# causing firewalld to hang with DBus timeout errors.
systemctl restart dbus 2>/dev/null || true
sleep 2

systemctl enable --now firewalld || true

# Use || true on each rule — if firewalld hangs, we continue anyway.
# FreeIPA's ipa-server-install will open the ports it needs.
firewall-cmd --permanent --add-service=freeipa-ldap || true
firewall-cmd --permanent --add-service=freeipa-ldaps || true
firewall-cmd --permanent --add-service=freeipa-replication || true
firewall-cmd --permanent --add-service=freeipa-trust || true
firewall-cmd --permanent --add-service=dns || true
firewall-cmd --permanent --add-service=ntp || true
firewall-cmd --permanent --add-service=http || true
firewall-cmd --permanent --add-service=https || true
firewall-cmd --permanent --add-port=88/tcp || true
firewall-cmd --permanent --add-port=88/udp || true
firewall-cmd --permanent --add-port=464/tcp || true
firewall-cmd --permanent --add-port=464/udp || true
firewall-cmd --reload || true

# -------------------------------------------------
# Step 4: Install FreeIPA server
# -------------------------------------------------
echo "[4/6] Installing FreeIPA server (this takes a while)..."

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

echo "[4/6] FreeIPA server installed."

# Use self for DNS, with Azure DNS as fallback for external names
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
echo "[5/6] Adding DNS records and creating users..."

echo "${IPA_ADMIN_PASSWORD}" > /tmp/.ipapw
kinit admin < /tmp/.ipapw
rm -f /tmp/.ipapw

# Azure DNS as global forwarder so all domain members can resolve external names
ipa dnsconfig-mod --forwarder=168.63.129.16 || true

# A records — api and srv both point to the server host (10.0.1.10)
ipa dnsrecord-add "${DOMAIN}" api --a-rec="${HOST_IP}" || true
ipa dnsrecord-add "${DOMAIN}" srv --a-rec="${HOST_IP}" || true
ipa dnsrecord-add "${DOMAIN}" ws1 --a-rec="${WS_IP}" || true

# Reverse zone
ipa dnszone-add 1.0.10.in-addr.arpa. || true
ipa dnsrecord-add 1.0.10.in-addr.arpa. 10 --ptr-rec="srv.${DOMAIN}." || true
ipa dnsrecord-add 1.0.10.in-addr.arpa. 11 --ptr-rec="ws1.${DOMAIN}." || true

# Reverse zone for the libvirt network (so the guest can be resolved too)
ipa dnszone-add 122.168.192.in-addr.arpa. || true
ipa dnsrecord-add 122.168.192.in-addr.arpa. 10 --ptr-rec="${HOSTNAME}." || true

# -------------------------------------------------
# Step 6: Create service principal and test users
# -------------------------------------------------
echo "[6/6] Creating service principals and test users..."

# Host entry for the API hostname
ipa host-add "api.${DOMAIN}" --force --no-reverse || true

# Host entry for the server host
ipa host-add "srv.${DOMAIN}" --force --no-reverse || true

# HTTP service principal for the API (Kerberos SPNEGO)
ipa service-add "HTTP/api.${DOMAIN}" || true
ipa service-allow-retrieve-keytab "HTTP/api.${DOMAIN}" --hosts="srv.${DOMAIN}" || true

# Test users
ipa user-add testuser --first=Test --last=User || true
ipa user-add launcheruser --first=Launcher --last=User || true

# Set permanent passwords via LDAP directory manager (bypasses first-login change)
LDAP_BASE="dc=$(echo "${DOMAIN}" | sed 's/\./,dc=/g')"

ldappasswd -x -D "cn=Directory Manager" -w "${IPA_DS_PASSWORD}" \
  -s "${IPA_ADMIN_PASSWORD}" \
  "uid=testuser,cn=users,cn=accounts,${LDAP_BASE}"

ldappasswd -x -D "cn=Directory Manager" -w "${IPA_DS_PASSWORD}" \
  -s "${IPA_ADMIN_PASSWORD}" \
  "uid=launcheruser,cn=users,cn=accounts,${LDAP_BASE}"

# Extend password expiration
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

echo "[6/6] Users and service principals created."

# -------------------------------------------------
# Signal readiness
# -------------------------------------------------
touch /root/.ipa-ready

echo "=========================================="
echo " FreeIPA VM Setup Complete"
echo " FreeIPA:  https://${HOSTNAME}"
echo " Domain:   ${DOMAIN}"
echo " Realm:    ${REALM}"
echo "=========================================="
