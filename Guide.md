# Gitea Setup Guide for Proxmox Container

## Step 1: Create Proxmox Container (CT102)

1. In Proxmox web interface, create a new container:
   - **CT ID**: 102
   - **Template**: Ubuntu 24.04
   - **Storage**: Local storage is fine
   - **CPU**: 1-2 cores
   - **Memory**: 2GB RAM
   - **Network**: Bridge to your network (DHCP)
   - **DNS**: Use your router's DNS or 8.8.8.8

2. Start the container and access it via console or SSH.

3. **Get the container's IP address** (since you're using DHCP):
   ```bash
   # Inside the container, run:
   ip addr show | grep "inet " | grep -v "127.0.0.1" | awk '{print $2}' | cut -d/ -f1
   
   # Or from Proxmox host:
   pct exec 102 -- ip addr show | grep "inet " | grep -v "127.0.0.1" | awk '{print $2}' | cut -d/ -f1
   ```
   
   **Write down this IP address** - you'll need it for the migration script!

## Step 2: Install Gitea

### Update the system:
```bash
apt update && apt upgrade -y
apt install -y wget curl git sqlite3 sudo
```

### Create Gitea user:
```bash
adduser --system --shell /bin/bash --gecos 'Git Version Control' --group --disabled-password --home /home/git git
```

### Download and install Gitea:
```bash
# Get the latest version (check https://github.com/go-gitea/gitea/releases for latest)
cd /tmp
wget -O gitea https://dl.gitea.io/gitea/1.21.4/gitea-1.21.4-linux-amd64
chmod +x gitea
sudo mv gitea /usr/local/bin/gitea

# Verify installation
gitea --version
```

### Create directories and set permissions:
```bash
sudo mkdir -p /var/lib/gitea/{custom,data,log}
sudo chown -R git:git /var/lib/gitea/
sudo chmod -R 750 /var/lib/gitea/
sudo mkdir /etc/gitea
sudo chown root:git /etc/gitea
sudo chmod 770 /etc/gitea
```

### Create systemd service:
```bash
sudo tee /etc/systemd/system/gitea.service > /dev/null <<EOF
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
```

### Start Gitea:
```bash
sudo systemctl daemon-reload
sudo systemctl enable gitea
sudo systemctl start gitea
sudo systemctl status gitea
```

## Step 3: Initial Gitea Configuration

1. **Access Gitea web interface**:
   - Open browser to `http://[container-ip]:3000`
   - You'll see the initial setup page

2. **Configure the installation**:
   - **Database Type**: SQLite3 (easiest for single user)
   - **Database Path**: `/var/lib/gitea/data/gitea.db`
   - **Application Name**: Your choice (e.g., "Adrian's Git Server")
   - **Repository Root Path**: `/var/lib/gitea/data/gitea-repositories`
   - **Git LFS Root Path**: `/var/lib/gitea/data/lfs`
   - **Server Domain**: Your container's IP address
   - **SSH Server Port**: 22 (or disable if not needed)
   - **HTTP Port**: 3000
   - **Base URL**: `http://[container-ip]:3000/`

3. **Create admin account**:
   - **Admin Username**: Choose your admin username
   - **Password**: Choose a strong password
   - **Email**: Your email address

4. **Click "Install Gitea"**

## Step 4: Generate Gitea Access Token

1. **Login to Gitea** with your admin account
2. **Go to Settings** (user menu → Settings)
3. **Applications** tab
4. **Generate New Token**:
   - **Token Name**: "Migration Script"
   - **Scopes**: Select `repo` (or all if you prefer)
5. **Copy the generated token** - you'll need this for the migration script

## Step 5: Configure the Migration Script

Edit the migration script with your details:

```bash
# These values are already set for you:
GITHUB_USERNAME="Adrianhammer"  # ✓ Already configured

# Update these values in the script:
GITHUB_TOKEN="your_github_personal_access_token"  # Get this from GitHub
GITEA_URL="http://[your_container_dhcp_ip]:3000"  # Use the IP you got from Step 1
GITEA_USERNAME="your_gitea_admin_username"        # The admin user you created
GITEA_TOKEN="your_gitea_access_token_from_step4"  # From Step 4
```

**Example after configuration:**
```bash
GITHUB_USERNAME="Adrianhammer"
GITHUB_TOKEN="ghp_xxxxxxxxxxxxxxxxxxxx"
GITEA_URL="http://192.168.1.150:3000"
GITEA_USERNAME="adrian"
GITEA_TOKEN="xxxxxxxxxxxxxxxxxxxxxxxx"
```

## Step 6: Run the Migration

1. **Make the script executable**:
   ```bash
   chmod +x github_gitea_migration.sh
   ```

2. **Run the migration**:
   ```bash
   ./github_gitea_migration.sh
   ```

3. **Monitor the progress** in the terminal and check the log file at `/var/log/github_gitea_migration.log`

## Optional: Set up automatic firewall rules

If you have a firewall running:
```bash
# Allow Gitea web interface
sudo ufw allow 3000/tcp

# Allow SSH if you enabled it
sudo ufw allow 22/tcp
```

## Optional: Set up SSL/HTTPS

For production use, consider setting up SSL with Let's Encrypt or a reverse proxy like Nginx.

## Troubleshooting

- **Check Gitea logs**: `sudo journalctl -u gitea -f`
- **Check if Gitea is running**: `sudo systemctl status gitea`
- **Verify network connectivity**: Make sure the container can reach GitHub
- **Check permissions**: Ensure git user has proper permissions on `/var/lib/gitea`

## Next Steps

Once the initial migration is complete, you can:
1. Set up the script as a cron job for regular syncing
2. Configure SSH keys for Git operations
3. Set up webhooks for real-time syncing
4. Configure backup strategies