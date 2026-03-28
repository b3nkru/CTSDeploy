#!/bin/bash
set -e

# CTSDeploy installer — run this once on your server
# Usage: sudo bash install.sh

INSTALL_DIR="/opt/ctsdeploy"
SERVICE_USER="ctsdeploy"
WEBHOOK_PORT=9000
ENV_FILE="/etc/ctsdeploy.env"

echo "==> Installing system dependencies..."
apt-get install -y python3-venv python3-pip nginx certbot python3-certbot-nginx curl

# Fix #13: check for Docker and install if missing
echo "==> Checking for Docker..."
if ! command -v docker &>/dev/null; then
    echo "    Docker not found — installing via get.docker.com..."
    curl -fsSL https://get.docker.com | sh
fi
if ! docker compose version &>/dev/null 2>&1; then
    echo "ERROR: 'docker compose' (v2 plugin) is not available after Docker install."
    echo "Install it manually: https://docs.docker.com/compose/install/"
    exit 1
fi
echo "    Docker $(docker --version) OK"

echo "==> Creating system user '$SERVICE_USER'..."
if ! id -u "$SERVICE_USER" &>/dev/null; then
    useradd --system --no-create-home --home-dir "$INSTALL_DIR" --shell /usr/sbin/nologin "$SERVICE_USER"
fi

echo "==> Set your domain configuration:"
read -rp "    Domain (e.g. example.com): " DOMAIN
if [ -z "$DOMAIN" ]; then
    echo "ERROR: Domain cannot be empty."
    exit 1
fi
read -rp "    Certbot email: " CERTBOT_EMAIL
if [ -z "$CERTBOT_EMAIL" ]; then
    echo "ERROR: Certbot email cannot be empty."
    exit 1
fi

echo ""
echo "==> Set your webhook secret (used to verify GitHub payloads):"
read -rsp "    WEBHOOK_SECRET: " WEBHOOK_SECRET
echo ""
if [ -z "$WEBHOOK_SECRET" ]; then
    echo "ERROR: WEBHOOK_SECRET cannot be empty — it protects your deploy endpoint."
    exit 1
fi

echo "==> Setting up directories..."
mkdir -p "$INSTALL_DIR/projects"
mkdir -p /var/log/ctsdeploy
cp -r "$(dirname "$0")/webhook" "$INSTALL_DIR/webhook"
chown -R "$SERVICE_USER:$SERVICE_USER" "$INSTALL_DIR"
chown -R "$SERVICE_USER:$SERVICE_USER" /var/log/ctsdeploy

# Fix #10: restricted certbot wrapper — blocks dangerous hook arguments
echo "==> Installing certbot wrapper..."
cat > /usr/local/bin/ctsdeploy-certbot <<'SCRIPT'
#!/bin/bash
# Certbot wrapper for ctsdeploy — blocks hook injection and dangerous flags.
# Fix #1 (audit): use prefix matching (--arg=value) to prevent bypass via = syntax.
for arg in "$@"; do
    case "$arg" in
        --deploy-hook|--deploy-hook=*|\
        --pre-hook|--pre-hook=*|\
        --post-hook|--post-hook=*|\
        --renew-hook|--renew-hook=*|\
        --manual-auth-hook|--manual-auth-hook=*|\
        --manual-cleanup-hook|--manual-cleanup-hook=*|\
        --config-dir|--config-dir=*|\
        --work-dir|--work-dir=*|\
        --logs-dir|--logs-dir=*)
            echo "ctsdeploy-certbot: blocked dangerous argument: $arg" >&2
            exit 1
            ;;
    esac
done
exec /usr/bin/certbot "$@"
SCRIPT
chmod 755 /usr/local/bin/ctsdeploy-certbot

echo "==> Configuring sudoers for '$SERVICE_USER'..."
cat > /etc/sudoers.d/ctsdeploy <<EOF
# Fix #5 (audit): restrict nginx to only -t and -s reload — prevents sudo nginx -s stop
$SERVICE_USER ALL=(ALL) NOPASSWD: /usr/sbin/nginx -t
$SERVICE_USER ALL=(ALL) NOPASSWD: /usr/sbin/nginx -s reload
$SERVICE_USER ALL=(ALL) NOPASSWD: /usr/bin/tee /etc/nginx/sites-enabled/*
$SERVICE_USER ALL=(ALL) NOPASSWD: /usr/bin/cat /etc/nginx/sites-enabled/*
$SERVICE_USER ALL=(ALL) NOPASSWD: /bin/rm -f /etc/nginx/sites-enabled/*
$SERVICE_USER ALL=(ALL) NOPASSWD: /usr/local/bin/ctsdeploy-certbot
EOF
chmod 440 /etc/sudoers.d/ctsdeploy

echo "==> Adding '$SERVICE_USER' to docker group..."
usermod -aG docker "$SERVICE_USER"

echo "==> Generating SSH key for GitHub access..."
mkdir -p "$INSTALL_DIR/.ssh"
if [ ! -f "$INSTALL_DIR/.ssh/id_ed25519" ]; then
    ssh-keygen -t ed25519 -f "$INSTALL_DIR/.ssh/id_ed25519" -N "" -C "ctsdeploy@$(hostname)"
fi
ssh-keyscan github.com >> "$INSTALL_DIR/.ssh/known_hosts"
# Fix #11: use StrictHostKeyChecking=yes — known_hosts is populated above
cat > "$INSTALL_DIR/.ssh/config" <<EOF
Host github.com
    IdentityFile $INSTALL_DIR/.ssh/id_ed25519
    UserKnownHostsFile $INSTALL_DIR/.ssh/known_hosts
    StrictHostKeyChecking yes
EOF
chown -R "$SERVICE_USER:$SERVICE_USER" "$INSTALL_DIR/.ssh"
chmod 700 "$INSTALL_DIR/.ssh"
chmod 600 "$INSTALL_DIR/.ssh/id_ed25519"
chmod 644 "$INSTALL_DIR/.ssh/known_hosts"
chmod 600 "$INSTALL_DIR/.ssh/config"

echo ""
echo "==> Add this public key as a Deploy Key on each private GitHub repo:"
echo ""
cat "$INSTALL_DIR/.ssh/id_ed25519.pub"
echo ""
read -rp "Press Enter once you've added the deploy key to GitHub..."

echo "==> Installing Python dependencies..."
python3 -m venv "$INSTALL_DIR/venv"
"$INSTALL_DIR/venv/bin/pip" install -q -r "$INSTALL_DIR/webhook/requirements.txt"

# Fix #5: write secrets to a protected env file instead of the world-readable unit file
echo "==> Writing environment config to $ENV_FILE..."
cat > "$ENV_FILE" <<EOF
PROJECTS_DIR=$INSTALL_DIR/projects
NGINX_SITES_DIR=/etc/nginx/sites-enabled
DOMAIN=$DOMAIN
CERTBOT_EMAIL=$CERTBOT_EMAIL
WEBHOOK_SECRET=$WEBHOOK_SECRET
EOF
chmod 600 "$ENV_FILE"
chown root:root "$ENV_FILE"

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

# Fix #5: load secrets from 0600 env file instead of unit file
EnvironmentFile=$ENV_FILE

# Fix #17: give in-flight deploys time to finish before kill
TimeoutStopSec=60
KillMode=mixed

[Install]
WantedBy=multi-user.target
EOF

echo "==> Writing nginx proxy config for hooks.$DOMAIN..."
cat > /etc/nginx/sites-enabled/ctsdeploy-hooks.conf <<EOF
server {
    listen 80;
    server_name hooks.$DOMAIN;

    location /webhook {
        proxy_pass http://127.0.0.1:$WEBHOOK_PORT/webhook;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
    }

    location /health {
        proxy_pass http://127.0.0.1:$WEBHOOK_PORT/health;
    }

    location /status/ {
        proxy_pass http://127.0.0.1:$WEBHOOK_PORT/status/;
        proxy_set_header Host \$host;
    }
}
EOF

/usr/sbin/nginx -t
/usr/sbin/nginx -s reload

echo "==> Enabling and starting ctsdeploy service..."
systemctl daemon-reload
systemctl enable ctsdeploy
systemctl start ctsdeploy

# Fix #22: provision SSL for the hooks endpoint automatically
echo "==> Provisioning SSL for hooks.$DOMAIN..."
echo "    (This requires DNS to be pointed at this server first)"
if certbot --nginx -d "hooks.$DOMAIN" --non-interactive --agree-tos -m "$CERTBOT_EMAIL"; then
    echo "    SSL configured for hooks.$DOMAIN"
else
    echo "    SSL provisioning failed — DNS may not be pointed here yet."
    echo "    Run manually when ready: certbot --nginx -d hooks.$DOMAIN"
fi

echo ""
echo "CTSDeploy is running."
echo ""
echo "Next steps:"
echo "  1. Point *.$DOMAIN → this server's IP (wildcard A record)"
echo "  2. Run bootstrap_project.sh to register your first project"
echo "  3. Add a GitHub webhook pointing to: https://hooks.$DOMAIN/webhook"
echo "     Content type: application/json | Secret: (your WEBHOOK_SECRET)"
