#!/bin/bash
set -e

# Add a new project to CTSDeploy.
# Usage: sudo bash bootstrap_project.sh <github-repo-url>
# Example: sudo bash bootstrap_project.sh https://github.com/b3nkru/herocal

INSTALL_DIR="/opt/ctsdeploy"
SERVICE_USER="ctsdeploy"
REPO_URL="$1"

if [ -z "$REPO_URL" ]; then
    echo "Usage: sudo bash bootstrap_project.sh <github-repo-url>"
    exit 1
fi

# Convert HTTPS GitHub URL to SSH
if [[ "$REPO_URL" == https://github.com/* ]]; then
    REPO_PATH="${REPO_URL#https://github.com/}"
    REPO_PATH="${REPO_PATH%.git}"
    SSH_URL="git@github.com:${REPO_PATH}.git"
else
    SSH_URL="$REPO_URL"
fi

REPO_NAME=$(basename "$SSH_URL" .git)
PROJECT_DIR="$INSTALL_DIR/projects/$REPO_NAME"

echo "==> Cloning $SSH_URL into $PROJECT_DIR..."
sudo -u "$SERVICE_USER" \
    GIT_SSH_COMMAND="ssh -i /home/$SERVICE_USER/.ssh/id_ed25519 -o UserKnownHostsFile=/home/$SERVICE_USER/.ssh/known_hosts -o StrictHostKeyChecking=no" \
    git clone "$SSH_URL" "$PROJECT_DIR"

DEPLOY_YAML="$PROJECT_DIR/deploy.yaml"
if [ ! -f "$DEPLOY_YAML" ]; then
    echo "ERROR: deploy.yaml not found in the root of $REPO_NAME."
    echo "Add one and re-run, or push a commit — CTSDeploy will handle the rest."
    exit 1
fi

PROJECT_NAME=$(python3 -c "import yaml; c=yaml.safe_load(open('$DEPLOY_YAML')); print(c['project_name'].lower())")
PORT=$(python3 -c "import yaml; c=yaml.safe_load(open('$DEPLOY_YAML')); print(c['port'])")

echo "==> Writing initial nginx config for $PROJECT_NAME.benkruseski.com -> port $PORT..."
cat > /etc/nginx/sites-enabled/"$PROJECT_NAME".conf <<EOF
server {
    listen 80;
    server_name $PROJECT_NAME.benkruseski.com;

    location / {
        proxy_pass http://localhost:$PORT;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_cache_bypass \$http_upgrade;
    }
}
EOF

/usr/sbin/nginx -t
/usr/sbin/nginx -s reload

echo ""
echo "Project '$PROJECT_NAME' registered."
echo "  Subdomain : $PROJECT_NAME.benkruseski.com"
echo "  Directory : $PROJECT_DIR"
echo ""
echo "Next steps:"
echo "  1. Run Certbot for SSL: certbot --nginx -d $PROJECT_NAME.benkruseski.com"
echo "  2. Add a GitHub webhook to the repo: http://hooks.benkruseski.com/webhook"
echo "  3. Push to the deploy branch to trigger your first auto-deploy"
