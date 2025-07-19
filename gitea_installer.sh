#!/bin/bash

# Gitea Quick Installer for Ubuntu 24.04
# Run this script inside your Proxmox container CT102

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check if running as root
if [[ $EUID -ne 0 ]]; then
   error "This script must be run as root"
   exit 1
fi

log "Starting Gitea installation for Ubuntu 24.04..."

# Get container IP
CONTAINER_IP=$(ip addr show | grep "inet " | grep -v "127.0.0.1" | awk '{print $2}' | cut -d/ -f1 | head -1)
log "Container IP address: $CONTAINER_IP"

# Update system
log "Updating system packages..."
apt update && apt upgrade -y
apt install -y wget curl git sqlite3 sudo ufw

# Create git user
log "Creating git user..."
if ! id "git" &>/dev/null; then
    adduser --system --shell /bin/bash --gecos 'Git Version Control' --group --disabled-password --home /home/git git
    success "Git user created"
else
    warning "Git user already exists"
fi

# Download Gitea
log "Downloading Gitea..."
GITEA_VERSION="1.21.4"
cd /tmp
if [[ ! -f "gitea-${GITEA_VERSION}-linux-amd64" ]]; then
    wget -O gitea "https://dl.gitea.io/gitea/${GITEA_VERSION}/gitea-${GITEA_VERSION}-linux-amd64"
else
    log "Gitea binary already downloaded"
fi

chmod +x gitea
mv gitea /usr/local/bin/gitea

# Verify installation
INSTALLED_VERSION=$(/usr/local/bin/gitea --version | head -1)
success "Gitea installed: $INSTALLED_VERSION"

# Create directories
log "Creating Gitea directories..."
mkdir -p /var/lib/gitea/{custom,data,log}
chown -R git:git /var/lib/gitea/
chmod -R 750 /var/lib/gitea/
mkdir -p /etc/gitea
chown root:git /etc/gitea
chmod 770 /etc/gitea

# Create systemd service
log "Creating systemd service..."
cat > /etc/systemd/system/gitea.service << 'EOF'
[Unit]
Description=Gitea (Git with a cup of tea)
After=syslog.target
After=network.target

[Service]
RestartSec=2s
Type=simple
User=git
Group=git
WorkingDirectory=/var/lib/gitea/
ExecStart=/usr/local/bin/gitea web --config /etc/gitea/app.ini
Restart=always
Environment=USER=git HOME=/home/git GITEA_WORK_DIR=/var/lib/gitea

[Install]
WantedBy=multi-user.target
EOF

# Start Gitea service
log "Starting Gitea service..."
systemctl daemon-reload
systemctl enable gitea
systemctl start gitea

# Wait for service to start
sleep 5

# Check if service is running
if systemctl is-active --quiet gitea; then
    success "Gitea service is running"
else
    error "Gitea service failed to start"
    systemctl status gitea
    exit 1
fi

# Configure firewall
log "Configuring firewall..."
ufw --force enable
ufw allow 3000/tcp
ufw allow ssh
success "Firewall configured"

# Final information
echo
success "Gitea installation completed!"
echo
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo -e "${GREEN}Next Steps:${NC}"
echo "1. Open your browser and go to: ${YELLOW}http://${CONTAINER_IP}:3000${NC}"
echo "2. Complete the initial setup wizard"
echo "3. Create your admin account"
echo "4. Generate an access token for the migration script"
echo
echo -e "${BLUE}Container Information:${NC}"
echo "  IP Address: $CONTAINER_IP"
echo "  Gitea URL:  http://${CONTAINER_IP}:3000"
echo "  Service:    systemctl status gitea"
echo "  Logs:       journalctl -u gitea -f"
echo
echo -e "${YELLOW}For the migration script, you'll need:${NC}"
echo "  - Your GitHub personal access token"
echo "  - Your Gitea admin username (create during setup)"
echo "  - Your Gitea access token (generate after setup)"
echo "  - This container IP: $CONTAINER_IP"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"