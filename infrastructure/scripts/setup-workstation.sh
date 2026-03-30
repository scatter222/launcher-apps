#!/bin/bash
set -euo pipefail

# Workstation Setup: Domain join + Electron Launcher
# Usage: setup-workstation.sh <credentials-file>
# Credentials file contains: DOMAIN, REALM, IPA_ADMIN_PASSWORD, ADMIN_USER, IPA_SERVER_IP
# Expects launcher-ui-src.tar.gz in the admin user's home directory.

CREDS_FILE="$1"
source "${CREDS_FILE}"

HOSTNAME="ws1.${DOMAIN}"
IPA_SERVER="idm.${DOMAIN}"
HOME_DIR="/home/${ADMIN_USER}"

echo "=========================================="
echo " Workstation Setup"
echo " Hostname: ${HOSTNAME}"
echo " Domain:   ${DOMAIN}"
echo "=========================================="

# -------------------------------------------------
# Step 1: Set hostname and DNS
# -------------------------------------------------
echo "[1/7] Configuring hostname and DNS..."

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

cat >> /etc/hosts <<EOF
${IPA_SERVER_IP}  ${IPA_SERVER} idm
10.0.1.11         api.${DOMAIN} api
10.0.1.12         ${HOSTNAME} ws1
EOF

# -------------------------------------------------
# Step 2: Install prerequisites
# -------------------------------------------------
echo "[2/7] Installing prerequisites..."

dnf install -y oracle-epel-release-el8
dnf install -y \
  ipa-client \
  krb5-workstation \
  bind-utils \
  curl \
  wget \
  jq \
  unzip \
  firewalld

# -------------------------------------------------
# Step 3: Join FreeIPA domain
# -------------------------------------------------
echo "[3/7] Joining FreeIPA domain..."

# Wait for FreeIPA DNS to be reachable before attempting domain join.
echo "Waiting for FreeIPA DNS to respond..."
for i in $(seq 1 30); do
  if host "${IPA_SERVER}" "${IPA_SERVER_IP}" &>/dev/null; then
    echo "FreeIPA DNS is ready."
    break
  fi
  echo "  Attempt ${i}/30 — DNS not ready, waiting 10s..."
  sleep 10
done

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

echo "[3/7] Domain join successful."

# Verify Kerberos works (use file redirect, pipe doesn't work with kinit)
echo "${IPA_ADMIN_PASSWORD}" > /tmp/.ipapw
kinit admin < /tmp/.ipapw
rm -f /tmp/.ipapw
klist
kdestroy

# -------------------------------------------------
# Step 4: Install Node.js 20 + pnpm
# -------------------------------------------------
echo "[4/7] Installing Node.js 20 and pnpm..."

dnf module enable -y nodejs:20 || true
dnf install -y nodejs || {
  # Fallback: NodeSource
  curl -fsSL https://rpm.nodesource.com/setup_20.x | bash -
  dnf install -y nodejs
}

npm install -g pnpm@latest

# Ensure pnpm is in PATH for the rest of this script
# npm global installs go to /usr/local/bin which may not be in sudo's PATH
export PATH="/usr/local/bin:${PATH}"

node --version
pnpm --version

# -------------------------------------------------
# Step 5: Install Electron dependencies
# -------------------------------------------------
echo "[5/7] Installing Electron/GUI dependencies..."

# Clean up /boot to free space before large installs.
# Oracle Linux LVM images have a small /boot partition (~800MB) that fills up
# when dnf distro-sync installs new kernels + dracut regenerates initramfs.
# The rescue images alone can be 100-200MB each.
rm -f /boot/initramfs-0-rescue-*.img 2>/dev/null || true
dnf install -y dnf-utils || true
package-cleanup --oldkernels --count=1 -y 2>/dev/null || true
dnf clean all

# Desktop and Electron runtime deps
dnf groupinstall -y "Server with GUI" || dnf groupinstall -y "Workstation" || true
dnf install -y \
  gtk3 \
  libnotify \
  nss \
  libXScrnSaver \
  alsa-lib \
  mesa-libGL \
  libdrm \
  libgbm \
  at-spi2-atk \
  cups-libs \
  xdg-utils \
  libxkbcommon \
  xorg-x11-server-Xvfb

# -------------------------------------------------
# Step 6: Extract source and build launcher
# -------------------------------------------------
echo "[6/7] Extracting source and building launcher..."

mkdir -p /opt/launcher-apps/src

# Extract the launcher UI source tarball uploaded by Terraform
tar xzf "${HOME_DIR}/launcher-ui-src.tar.gz" -C /opt/launcher-apps/src/

cd /opt/launcher-apps/src/libvirt-ui

# Install dependencies (pnpm is in /usr/local/bin, ensured in PATH above)
pnpm install --frozen-lockfile || pnpm install

# Build the RPM package
pnpm run make || {
  echo "RPM build failed, the app can still be run in dev mode with: pnpm run start"
}

# Install the RPM if it was built
RPM_FILE=$(find out/make -name "*.rpm" 2>/dev/null | head -1)
if [ -n "${RPM_FILE}" ]; then
  dnf install -y "${RPM_FILE}"
  echo "Launcher RPM installed successfully."
else
  echo "No RPM found. Run manually with: cd /opt/launcher-apps/src/libvirt-ui && pnpm run start"
fi

# -------------------------------------------------
# Step 7: Configure API connection
# -------------------------------------------------
echo "[7/7] Configuring API connection..."

# Create API config for the launcher
mkdir -p /opt/launcher-apps/src/libvirt-ui/config
cat > /opt/launcher-apps/src/libvirt-ui/config/api.yaml <<EOF
api:
  baseUrl: https://api.${DOMAIN}
  timeout: 10000
  auth:
    method: negotiate
EOF

# Clean up credentials and tarball
rm -f "${CREDS_FILE}"
rm -f "${HOME_DIR}/launcher-ui-src.tar.gz"

echo "=========================================="
echo " Workstation Setup Complete"
echo " Domain:   ${DOMAIN}"
echo " Launcher: /opt/launcher-apps/src/libvirt-ui"
echo ""
echo " To test Kerberos auth:"
echo "   kinit testuser@${REALM}"
echo "   curl --negotiate -u : https://api.${DOMAIN}/api/user"
echo "=========================================="
