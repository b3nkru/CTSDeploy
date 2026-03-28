#!/bin/bash
set -e

# CTSDeploy in-place updater — safe to run on a live server.
# Updates webhook code and security config without touching deployed projects,
# nginx site configs, SSL certs, or running Docker containers.
#
# Usage: sudo bash update.sh
# Run from the cloned CTSDeploy repo directory.

INSTALL_DIR="/opt/ctsdeploy"
SERVICE_USER="ctsdeploy"
ENV_FILE="/etc/ctsdeploy.env"
REPO_DIR="$(dirname "$0")"

echo "==> Updating CTSDeploy webhook code..."
cp -r "$REPO_DIR/webhook" "$INSTALL_DIR/"
chown -R "$SERVICE_USER:$SERVICE_USER" "$INSTALL_DIR/webhook"

echo "==> Updating helper scripts..."
cp "$REPO_DIR/bootstrap_project.sh" "$INSTALL_DIR/bootstrap_project.sh"
cp "$REPO_DIR/remove_project.sh"    "$INSTALL_DIR/remove_project.sh"
chmod +x "$INSTALL_DIR/bootstrap_project.sh" "$INSTALL_DIR/remove_project.sh"

echo "==> Reinstalling Python dependencies (pinned versions)..."
"$INSTALL_DIR/venv/bin/pip" install -q -r "$INSTALL_DIR/webhook/requirements.txt"

# Migrate WEBHOOK_SECRET out of the world-readable unit file into a protected env file
echo "==> Migrating secrets to $ENV_FILE..."
if [ ! -f "$ENV_FILE" ]; then
    # Extract current values from the existing systemd unit
    get_env() { grep "^Environment=${1}=" /etc/systemd/system/ctsdeploy.service | cut -d= -f3-; }
    cat > "$ENV_FILE" <<EOF
PROJECTS_DIR=$(get_env PROJECTS_DIR)
NGINX_SITES_DIR=$(get_env NGINX_SITES_DIR)
DOMAIN=$(get_env DOMAIN)
CERTBOT_EMAIL=$(get_env CERTBOT_EMAIL)
WEBHOOK_SECRET=$(get_env WEBHOOK_SECRET)
EOF
    chmod 600 "$ENV_FILE"
    chown root:root "$ENV_FILE"
    echo "    Created $ENV_FILE from existing unit file values"
else
    echo "    $ENV_FILE already exists — skipping migration"
fi

echo "==> Updating systemd unit to use EnvironmentFile..."
# Replace inline Environment= lines with a single EnvironmentFile= reference,
# and add TimeoutStopSec if missing.
UNIT_FILE="/etc/systemd/system/ctsdeploy.service"
# Only rewrite if still using old inline format
if grep -q "^Environment=WEBHOOK_SECRET" "$UNIT_FILE"; then
    # Preserve ExecStart line (has install-specific paths)
    EXECSTART=$(grep "^ExecStart=" "$UNIT_FILE")
    cat > "$UNIT_FILE" <<EOF
[Unit]
Description=CTSDeploy webhook listener
After=network.target

[Service]
User=$SERVICE_USER
WorkingDirectory=$INSTALL_DIR/webhook
$EXECSTART
Restart=on-failure
RestartSec=5

EnvironmentFile=$ENV_FILE

TimeoutStopSec=60
KillMode=mixed

[Install]
WantedBy=multi-user.target
EOF
    echo "    Unit file updated to use EnvironmentFile"
else
    # Unit already uses EnvironmentFile; just ensure TimeoutStopSec is present
    if ! grep -q "^TimeoutStopSec" "$UNIT_FILE"; then
        sed -i '/^KillMode\|^Restart=on-failure/a TimeoutStopSec=60' "$UNIT_FILE"
        echo "    Added TimeoutStopSec to existing unit file"
    else
        echo "    Unit file already up to date"
    fi
fi

echo "==> Updating certbot wrapper (blocks --arg=value hook injection)..."
cat > /usr/local/bin/ctsdeploy-certbot <<'SCRIPT'
#!/bin/bash
# Certbot wrapper for ctsdeploy — blocks hook injection and dangerous flags.
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

echo "==> Updating sudoers (restricts nginx to -t and -s reload only)..."
cat > /etc/sudoers.d/ctsdeploy <<EOF
$SERVICE_USER ALL=(ALL) NOPASSWD: /usr/sbin/nginx -t
$SERVICE_USER ALL=(ALL) NOPASSWD: /usr/sbin/nginx -s reload
$SERVICE_USER ALL=(ALL) NOPASSWD: /usr/bin/tee /etc/nginx/sites-enabled/*
$SERVICE_USER ALL=(ALL) NOPASSWD: /usr/bin/cat /etc/nginx/sites-enabled/*
$SERVICE_USER ALL=(ALL) NOPASSWD: /bin/rm -f /etc/nginx/sites-enabled/*
$SERVICE_USER ALL=(ALL) NOPASSWD: /usr/local/bin/ctsdeploy-certbot
EOF
chmod 440 /etc/sudoers.d/ctsdeploy

echo "==> Updating SSH config (StrictHostKeyChecking yes)..."
SSH_CONFIG="$INSTALL_DIR/.ssh/config"
if [ -f "$SSH_CONFIG" ]; then
    sed -i 's/StrictHostKeyChecking no/StrictHostKeyChecking yes/' "$SSH_CONFIG"
    echo "    SSH StrictHostKeyChecking set to yes"
fi

echo "==> Reloading systemd and restarting ctsdeploy..."
systemctl daemon-reload
systemctl restart ctsdeploy

# Brief wait then confirm the service came up
sleep 2
if systemctl is-active --quiet ctsdeploy; then
    echo ""
    echo "CTSDeploy updated and running."
    echo ""
    echo "Running projects and nginx configs are unchanged."
    echo "Check logs: journalctl -u ctsdeploy -f"
else
    echo ""
    echo "WARNING: ctsdeploy failed to start after update."
    echo "Check: journalctl -u ctsdeploy --no-pager -n 50"
    exit 1
fi
