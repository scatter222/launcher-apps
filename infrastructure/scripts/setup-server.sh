#!/bin/bash
set -euo pipefail

# Server Host Setup: KVM + FreeIPA guest VM + .NET Core API + Nginx + Keycloak
# The server host acts as a hypervisor and application host. FreeIPA runs inside
# a KVM guest VM on the libvirt default network (192.168.122.0/24).
#
# Usage: setup-server.sh <credentials-file>
# Credentials file contains: DOMAIN, REALM, IPA_ADMIN_PASSWORD, IPA_DS_PASSWORD, ADMIN_USER

CREDS_FILE="$1"
source "${CREDS_FILE}"

# Background heartbeat to keep SSH alive during long operations
(while true; do echo "... heartbeat $(date +%H:%M:%S)"; sleep 60; done) &
HEARTBEAT_PID=$!
trap "kill ${HEARTBEAT_PID} 2>/dev/null" EXIT

HOSTNAME="srv.${DOMAIN}"
PRIVATE_IP="10.0.1.10"
WS_IP="10.0.1.11"
FREEIPA_GUEST_IP="192.168.122.10"
FREEIPA_MAC="52:54:00:00:01:10"
HOME_DIR="/home/${ADMIN_USER}"

echo "=========================================="
echo " Server Host Setup (KVM + API)"
echo " Host:   ${HOSTNAME}"
echo " Domain: ${DOMAIN}"
echo " Realm:  ${REALM}"
echo "=========================================="

# =================================================
# PHASE A: Host prerequisites
# =================================================

# -------------------------------------------------
# Step 1: Set hostname and /etc/hosts
# -------------------------------------------------
echo "[1/14] Configuring hostname and hosts file..."

hostnamectl set-hostname "${HOSTNAME}"

cat >> /etc/hosts <<EOF
${PRIVATE_IP}       ${HOSTNAME} srv
${FREEIPA_GUEST_IP} idm.${DOMAIN} idm
${PRIVATE_IP}       api.${DOMAIN} api
${WS_IP}            ws1.${DOMAIN} ws1
EOF

# -------------------------------------------------
# Step 2: Install host prerequisites
# -------------------------------------------------
echo "[2/14] Installing host prerequisites..."

dnf install -y oracle-epel-release-el8

# Clean /boot to prevent space issues
rm -f /boot/initramfs-0-rescue-*.img 2>/dev/null || true
dnf install -y dnf-utils || true
package-cleanup --oldkernels --count=1 -y 2>/dev/null || true
dnf clean all

dnf distro-sync -y

dnf install -y \
  qemu-kvm \
  libvirt \
  libvirt-devel \
  virt-install \
  libguestfs-tools \
  genisoimage \
  ipa-client \
  krb5-workstation \
  openldap-clients \
  dnsmasq \
  nginx \
  firewalld \
  bind-utils \
  curl \
  wget \
  jq \
  unzip \
  policycoreutils-python-utils

# -------------------------------------------------
# Step 3: Configure firewall
# -------------------------------------------------
echo "[3/14] Configuring firewall..."

systemctl enable --now firewalld

# Identity ports (forwarded to FreeIPA guest via DNAT)
firewall-cmd --permanent --add-service=dns
firewall-cmd --permanent --add-service=freeipa-ldap
firewall-cmd --permanent --add-service=freeipa-ldaps
firewall-cmd --permanent --add-service=http
firewall-cmd --permanent --add-service=https
firewall-cmd --permanent --add-port=88/tcp
firewall-cmd --permanent --add-port=88/udp
firewall-cmd --permanent --add-port=464/tcp
firewall-cmd --permanent --add-port=464/udp

# Application ports (local to this host)
firewall-cmd --permanent --add-port=9444/tcp
firewall-cmd --permanent --add-port=9080/tcp
firewall-cmd --permanent --add-port=9443/tcp

# Enable masquerading for DNAT forwarding
firewall-cmd --permanent --add-masquerade

# Port forwarding: identity traffic from Azure NIC -> FreeIPA guest
for PORT in 53 88 464 389 636; do
  firewall-cmd --permanent --add-forward-port="port=${PORT}:proto=tcp:toaddr=${FREEIPA_GUEST_IP}"
  firewall-cmd --permanent --add-forward-port="port=${PORT}:proto=udp:toaddr=${FREEIPA_GUEST_IP}"
done

# TCP-only: HTTPS (FreeIPA web UI) and LDAPS
firewall-cmd --permanent --add-forward-port="port=443:proto=tcp:toaddr=${FREEIPA_GUEST_IP}"
firewall-cmd --permanent --add-forward-port="port=80:proto=tcp:toaddr=${FREEIPA_GUEST_IP}"

firewall-cmd --reload

# Enable IP forwarding
sysctl -w net.ipv4.ip_forward=1
echo "net.ipv4.ip_forward = 1" > /etc/sysctl.d/99-ip-forward.conf

# =================================================
# PHASE B: KVM/libvirt setup + FreeIPA guest VM
# =================================================

# -------------------------------------------------
# Step 4: Start libvirt and configure networking
# -------------------------------------------------
echo "[4/14] Configuring KVM/libvirt..."

systemctl enable --now libvirtd

# Verify nested virtualization
if [ -e /dev/kvm ]; then
  echo "KVM device found — nested virtualization available."
else
  echo "WARNING: /dev/kvm not found — FreeIPA guest will run in emulation (slow)."
fi

# Start the default network
virsh net-start default 2>/dev/null || true
virsh net-autostart default 2>/dev/null || true

# Add a DHCP host reservation so the FreeIPA VM always gets 192.168.122.10
virsh net-update default add ip-dhcp-host \
  "<host mac='${FREEIPA_MAC}' name='idm' ip='${FREEIPA_GUEST_IP}'/>" \
  --live --config || true

# Create directory structure for VM management (user VMs, not the infra FreeIPA VM)
mkdir -p /var/lib/libvirt/images/base
mkdir -p /var/lib/libvirt/images/instances

# -------------------------------------------------
# Step 5: Download OL8 cloud image
# -------------------------------------------------
echo "[5/14] Downloading Oracle Linux 8 cloud image..."

OL8_IMAGE_URL="https://yum.oracle.com/templates/OracleLinux/OL8/u10/x86_64/OL8U10_x86_64-kvm-cloud.qcow2"
BASE_IMAGE="/var/lib/libvirt/images/base/ol8-cloud.qcow2"

if [ ! -f "${BASE_IMAGE}" ]; then
  wget -q --show-progress -O "${BASE_IMAGE}" "${OL8_IMAGE_URL}" || {
    # Fallback: try the generic cloud image URL
    wget -q --show-progress -O "${BASE_IMAGE}" \
      "https://yum.oracle.com/templates/OracleLinux/OL8/u9/x86_64/OL8U9_x86_64-kvm-cloud.qcow2"
  }
fi

# -------------------------------------------------
# Step 6: Create FreeIPA guest disk (COW overlay)
# -------------------------------------------------
echo "[6/14] Creating FreeIPA guest disk..."

FREEIPA_DISK="/var/lib/libvirt/images/instances/freeipa.qcow2"

qemu-img create -f qcow2 -b "${BASE_IMAGE}" -F qcow2 "${FREEIPA_DISK}"
# Resize to 30GB so FreeIPA has room for its databases
qemu-img resize "${FREEIPA_DISK}" 30G

# -------------------------------------------------
# Step 7: Generate cloud-init ISO
# -------------------------------------------------
echo "[7/14] Generating cloud-init seed ISO..."

CLOUD_INIT_DIR="/tmp/freeipa-cloud-init"
mkdir -p "${CLOUD_INIT_DIR}"

# Copy the network config template (uploaded by Terraform)
cp "${HOME_DIR}/freeipa-network.yaml" "${CLOUD_INIT_DIR}/network-config"

# Generate the user-data with credentials injected
cat > "${CLOUD_INIT_DIR}/user-data" <<USERDATA
#cloud-config
hostname: idm
fqdn: idm.${DOMAIN}
manage_etc_hosts: false

users:
  - name: root
    lock_passwd: false
    hashed_passwd: ""

growpart:
  mode: auto
  devices: [/]

write_files:
  - path: /root/setup-freeipa-vm.sh
    permissions: '0755'
    encoding: b64
    content: $(base64 -w0 "${HOME_DIR}/setup-freeipa-vm.sh")
  - path: /root/.ipa-creds
    permissions: '0600'
    content: |
      DOMAIN=${DOMAIN}
      REALM=${REALM}
      IPA_ADMIN_PASSWORD=${IPA_ADMIN_PASSWORD}
      IPA_DS_PASSWORD=${IPA_DS_PASSWORD}
      HOST_IP=${PRIVATE_IP}
      WS_IP=${WS_IP}

runcmd:
  - /root/setup-freeipa-vm.sh /root/.ipa-creds 2>&1 | tee /var/log/setup-freeipa.log
USERDATA

# meta-data (minimal)
cat > "${CLOUD_INIT_DIR}/meta-data" <<METADATA
instance-id: freeipa-vm-001
local-hostname: idm
METADATA

# Create the seed ISO
genisoimage -output /var/lib/libvirt/images/instances/freeipa-seed.iso \
  -volid cidata \
  -joliet -rock \
  "${CLOUD_INIT_DIR}/user-data" \
  "${CLOUD_INIT_DIR}/meta-data" \
  "${CLOUD_INIT_DIR}/network-config"

rm -rf "${CLOUD_INIT_DIR}"

# -------------------------------------------------
# Step 8: Create and start the FreeIPA VM
# -------------------------------------------------
echo "[8/14] Creating FreeIPA KVM guest..."

virt-install \
  --name freeipa \
  --memory 4096 \
  --vcpus 2 \
  --disk "${FREEIPA_DISK}" \
  --disk "/var/lib/libvirt/images/instances/freeipa-seed.iso,device=cdrom" \
  --os-variant ol8.0 \
  --network "network=default,mac=${FREEIPA_MAC}" \
  --graphics none \
  --console pty,target_type=serial \
  --noautoconsole \
  --import

echo "[8/14] FreeIPA VM started. Waiting for installation to complete..."

# =================================================
# PHASE C: Wait for FreeIPA readiness
# =================================================

# -------------------------------------------------
# Step 9: Poll until FreeIPA is ready
# -------------------------------------------------
echo "[9/14] Waiting for FreeIPA to become ready (this takes 15-25 minutes)..."

READY=false
for i in $(seq 1 60); do
  echo "  Attempt ${i}/60 — checking FreeIPA readiness..."

  # Check if DNS is responding for the domain
  if dig @${FREEIPA_GUEST_IP} "idm.${DOMAIN}" +short 2>/dev/null | grep -q "${FREEIPA_GUEST_IP}"; then
    # Also verify LDAP is up (FreeIPA DNS comes up before LDAP)
    if ldapsearch -x -H "ldap://${FREEIPA_GUEST_IP}" -b "" -s base namingContexts 2>/dev/null | grep -q "dc="; then
      echo "  FreeIPA is ready! (DNS + LDAP responding)"
      READY=true
      break
    fi
  fi

  sleep 30
done

if [ "${READY}" != "true" ]; then
  echo "ERROR: FreeIPA did not become ready within 30 minutes."
  echo "Check the FreeIPA VM console: virsh console freeipa"
  echo "Continuing anyway — some steps may fail."
fi

# =================================================
# PHASE D: Host DNS configuration
# =================================================

# -------------------------------------------------
# Step 10: Configure dnsmasq for split DNS
# -------------------------------------------------
echo "[10/14] Configuring dnsmasq for DNS forwarding..."

# Stop any conflicting systemd-resolved
systemctl stop systemd-resolved 2>/dev/null || true
systemctl disable systemd-resolved 2>/dev/null || true

cat > /etc/dnsmasq.d/freeipa.conf <<EOF
# Forward lab.forge.local queries to the FreeIPA guest
server=/${DOMAIN}/${FREEIPA_GUEST_IP}
# Forward reverse lookups too
server=/1.0.10.in-addr.arpa/${FREEIPA_GUEST_IP}
server=/122.168.192.in-addr.arpa/${FREEIPA_GUEST_IP}
# Everything else goes to Azure DNS
server=168.63.129.16
# Bind only to localhost to avoid conflicts with libvirt's dnsmasq
listen-address=127.0.0.1
bind-interfaces
EOF

systemctl enable --now dnsmasq

# Point the host at dnsmasq
cat > /etc/resolv.conf <<EOF
search ${DOMAIN}
nameserver 127.0.0.1
EOF

# Prevent NetworkManager from overwriting resolv.conf
if [ -f /etc/NetworkManager/NetworkManager.conf ]; then
  grep -q "dns=none" /etc/NetworkManager/NetworkManager.conf || \
    sed -i '/\[main\]/a dns=none' /etc/NetworkManager/NetworkManager.conf
  systemctl restart NetworkManager || true
fi

# Verify DNS resolution through the chain
echo "Testing DNS resolution..."
dig "idm.${DOMAIN}" +short || echo "DNS not resolving yet — may need a moment"

# =================================================
# PHASE E: Domain-join host + API keytab
# =================================================

# -------------------------------------------------
# Step 11: Join the server host to FreeIPA as a client
# -------------------------------------------------
echo "[11/14] Joining server host to FreeIPA domain..."

ipa-client-install \
  --unattended \
  --hostname="${HOSTNAME}" \
  --domain="${DOMAIN}" \
  --realm="${REALM}" \
  --server="idm.${DOMAIN}" \
  --principal=admin \
  --password="${IPA_ADMIN_PASSWORD}" \
  --mkhomedir \
  --no-ntp \
  --force-join

echo "[11/14] Domain join successful."

# Get the API service keytab
echo "${IPA_ADMIN_PASSWORD}" > /tmp/.ipapw
kinit admin < /tmp/.ipapw
rm -f /tmp/.ipapw

ipa-getkeytab -s "idm.${DOMAIN}" -p "HTTP/api.${DOMAIN}" -k /etc/krb5.keytab.api
chmod 600 /etc/krb5.keytab.api
klist -k /etc/krb5.keytab.api

echo "[11/14] API keytab generated and verified."

# =================================================
# PHASE F: Application services
# =================================================

# -------------------------------------------------
# Step 12: Install Docker + start Keycloak
# -------------------------------------------------
echo "[12/14] Installing Docker and starting Keycloak..."

dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
dnf install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin

systemctl enable --now docker
usermod -aG docker "${ADMIN_USER}"

cd "${HOME_DIR}"
sed -i "s|__DOMAIN__|${DOMAIN}|g" docker-compose.keycloak.yml
sed -i "s|__HOSTNAME__|idm.${DOMAIN}|g" docker-compose.keycloak.yml
docker compose -f docker-compose.keycloak.yml up -d

# -------------------------------------------------
# Step 13: Install .NET 8 + build and deploy API
# -------------------------------------------------
echo "[13/14] Installing .NET 8 and building API..."

dnf install -y dotnet-sdk-8.0 || {
  rpm -Uvh https://packages.microsoft.com/config/rhel/8/packages-microsoft-prod.rpm || true
  dnf install -y dotnet-sdk-8.0
}

dotnet --version

# Extract and build
mkdir -p /opt/launcher-apps/src
tar xzf "${HOME_DIR}/launcher-api-src.tar.gz" -C /opt/launcher-apps/src/

cd /opt/launcher-apps/src/api
dotnet publish src/LauncherApi/LauncherApi.csproj \
  -c Release \
  -o /opt/launcher-api \
  --self-contained false

# Create systemd service
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
# Step 14: Configure Nginx + start services
# -------------------------------------------------
echo "[14/14] Configuring Nginx and starting services..."

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

# SELinux: allow VMs to use network
setsebool -P virt_sandbox_use_all_caps on 2>/dev/null || true

systemctl enable --now nginx
systemctl start launcher-api

sleep 3
systemctl status launcher-api --no-pager || true
curl -s http://localhost:5000/api/health || echo "API not yet responding (may need a moment)"

# Clean up
rm -f "${CREDS_FILE}"
rm -f "${HOME_DIR}/launcher-api-src.tar.gz"
rm -f "${HOME_DIR}/setup-freeipa-vm.sh"
rm -f "${HOME_DIR}/freeipa-network.yaml"

echo "=========================================="
echo " Server Host Setup Complete"
echo " Host:     ${HOSTNAME}"
echo " FreeIPA:  https://idm.${DOMAIN} (KVM guest at ${FREEIPA_GUEST_IP})"
echo " API:      https://api.${DOMAIN}:9444"
echo " Keycloak: http://srv.${DOMAIN}:9080"
echo " KVM:      $(virsh version --daemon 2>/dev/null | head -1 || echo 'not available')"
echo ""
echo " FreeIPA VM status:"
echo "   virsh list --all"
echo "   virsh console freeipa"
echo "=========================================="
