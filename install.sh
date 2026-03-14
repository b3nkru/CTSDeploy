#!/bin/bash
set -e

# CTSDeploy installer — run this once on your Raspberry Pi
# Usage: sudo bash install.sh

INSTALL_DIR="/opt/ctsdeploy"
SERVICE_USER="ctsdeploy"
WEBHOOK_PORT=9000

echo "==> Installing system dependencies..."
apt-get install -y python3-venv python3-pip nginx certbot python3-certbot-nginx

echo "==> Creating system user '$SERVICE_USER'..."
if ! id -u "$SERVICE_USER" &>/dev/null; then
    useradd --system --create-home --home-dir /home/$SERVICE_USER --shell /usr/sbin/nologin "$SERVICE_USER"
fi

echo "==> Setting up directories..."
mkdir -p "$INSTALL_DIR/projects"
mkdir -p /var/log/ctsdeploy
cp -r "$(dirname "$0")/webhook" "$INSTALL_DIR/webhook"
chown -R "$SERVICE_USER:$SERVICE_USER" "$INSTALL_DIR"
chown -R "$SERVICE_USER:$SERVICE_USER" /var/log/ctsdeploy

# Give service user permission to manage nginx and write configs without a password
echo "==> Configuring sudoers for '$SERVICE_USER'..."
cat > /etc/sudoers.d/ctsdeploy <<EOF
$SERVICE_USER ALL=(ALL) NOPASSWD: /usr/sbin/nginx
$SERVICE_USER ALL=(ALL) NOPASSWD: /usr/bin/tee /etc/nginx/sites-enabled/*
$SERVICE_USER ALL=(ALL) NOPASSWD: /usr/bin/certbot
EOF
chmod 440 /etc/sudoers.d/ctsdeploy

# Add service user to docker group so it can run docker compose
echo "==> Adding '$SERVICE_USER' to docker group..."
usermod -aG docker "$SERVICE_USER"

# Generate SSH key for pulling private repos
echo "==> Generating SSH key for GitHub access..."
mkdir -p /home/$SERVICE_USER/.ssh
if [ ! -f /home/$SERVICE_USER/.ssh/id_ed25519 ]; then
    ssh-keygen -t ed25519 -f /home/$SERVICE_USER/.ssh/id_ed25519 -N "" -C "ctsdeploy@$(hostname)"
fi
ssh-keyscan github.com >> /home/$SERVICE_USER/.ssh/known_hosts
cat > /home/$SERVICE_USER/.ssh/config <<EOF
Host github.com
    IdentityFile /home/$SERVICE_USER/.ssh/id_ed25519
    UserKnownHostsFile /home/$SERVICE_USER/.ssh/known_hosts
    StrictHostKeyChecking no
EOF
chown -R "$SERVICE_USER:$SERVICE_USER" /home/$SERVICE_USER/.ssh
chmod 700 /home/$SERVICE_USER/.ssh
chmod 600 /home/$SERVICE_USER/.ssh/id_ed25519
chmod 644 /home/$SERVICE_USER/.ssh/known_hosts
chmod 600 /home/$SERVICE_USER/.ssh/config

# Update deployer.py to reference correct SSH paths
sed -i "s|SSH_KEY = .*|SSH_KEY = \"/home/$SERVICE_USER/.ssh/id_ed25519\"|" "$INSTALL_DIR/webhook/deployer.py"
sed -i "s|KNOWN_HOSTS = .*|KNOWN_HOSTS = \"/home/$SERVICE_USER/.ssh/known_hosts\"|" "$INSTALL_DIR/webhook/deployer.py"

echo ""
echo "==> Add this public key as a Deploy Key on each private GitHub repo:"
echo ""
cat /home/$SERVICE_USER/.ssh/id_ed25519.pub
echo ""
read -rp "Press Enter once you've added the deploy key to GitHub..."

echo "==> Installing Python dependencies..."
python3 -m venv "$INSTALL_DIR/venv"
"$INSTALL_DIR/venv/bin/pip" install -q -r "$INSTALL_DIR/webhook/requirements.txt"

echo ""
echo "==> Set your webhook secret (used to verify GitHub payloads):"
read -rsp "    WEBHOOK_SECRET: " WEBHOOK_SECRET
echo ""

echo "==> Writing systemd service..."
cat > /etc/systemd/system/ctsdeploy.service <<EOF
[Unit]
Description=CTSDeploy webhook listener
After=network.target

[Service]
User=$SERVICE_USER
WorkingDirectory=$INSTALL_DIR/webhook
ExecStart=$INSTALL_DIR/venv/bin/uvicorn main:app --host 127.0.0.1 --port $WEBHOOK_PORT
Restart=on-failure
RestartSec=5

Environment=PROJECTS_DIR=$INSTALL_DIR/projects
Environment=NGINX_SITES_DIR=/etc/nginx/sites-enabled
Environment=DOMAIN=benkruseski.com
Environment=CERTBOT_EMAIL=rw2dm13@gmail.com
Environment=WEBHOOK_SECRET=$WEBHOOK_SECRET

[Install]
WantedBy=multi-user.target
EOF

echo "==> Writing nginx proxy config for hooks.benkruseski.com..."
cat > /etc/nginx/sites-enabled/ctsdeploy-hooks.conf <<EOF
server {
    listen 80;
    server_name hooks.benkruseski.com;

    location /webhook {
        proxy_pass http://127.0.0.1:$WEBHOOK_PORT/webhook;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
    }

    location /health {
        proxy_pass http://127.0.0.1:$WEBHOOK_PORT/health;
    }
}
EOF

/usr/sbin/nginx -t
/usr/sbin/nginx -s reload

echo "==> Enabling and starting ctsdeploy service..."
systemctl daemon-reload
systemctl enable ctsdeploy
systemctl start ctsdeploy

echo ""
echo "CTSDeploy is running."
echo ""
echo "Next steps:"
echo "  1. Point *.benkruseski.com → this Pi's IP in Cloudflare (wildcard A record)"
echo "  2. Run bootstrap_project.sh to add your first project"
echo "  3. Add a GitHub webhook: http://hooks.benkruseski.com/webhook (content type: application/json)"
echo "  4. Run certbot for SSL: certbot --nginx -d hooks.benkruseski.com"
