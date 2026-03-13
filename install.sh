#!/bin/bash
set -e

# CTSDeploy installer — run this once on your Raspberry Pi
# Usage: sudo bash install.sh

INSTALL_DIR="/opt/ctsdeploy"
SERVICE_USER="ctsdeploy"
WEBHOOK_PORT=9000

echo "==> Creating system user '$SERVICE_USER'..."
id -u "$SERVICE_USER" &>/dev/null || useradd --system --no-create-home --shell /usr/sbin/nologin "$SERVICE_USER"

echo "==> Setting up directories..."
mkdir -p "$INSTALL_DIR/projects"
cp -r "$(dirname "$0")/webhook" "$INSTALL_DIR/webhook"
chown -R "$SERVICE_USER:$SERVICE_USER" "$INSTALL_DIR"

# Give service user permission to manage nginx and write configs without a password
echo "==> Configuring sudoers for '$SERVICE_USER'..."
cat > /etc/sudoers.d/ctsdeploy <<EOF
$SERVICE_USER ALL=(ALL) NOPASSWD: /usr/sbin/nginx
$SERVICE_USER ALL=(ALL) NOPASSWD: /usr/bin/tee /etc/nginx/sites-enabled/*
EOF
chmod 440 /etc/sudoers.d/ctsdeploy

# Add service user to docker group so it can run docker compose
echo "==> Adding '$SERVICE_USER' to docker group..."
usermod -aG docker "$SERVICE_USER"

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
}
EOF

nginx -t
nginx -s reload

echo "==> Enabling and starting ctsdeploy service..."
systemctl daemon-reload
systemctl enable ctsdeploy
systemctl start ctsdeploy

echo ""
echo "CTSDeploy is running."
echo ""
echo "Next steps:"
echo "  1. Point hooks.benkruseski.com → this Pi's IP in Cloudflare"
echo "  2. Run bootstrap_project.sh to add your first project"
echo "  3. Add a GitHub webhook: http://hooks.benkruseski.com/webhook (content type: application/json)"
