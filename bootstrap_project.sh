#!/bin/bash
set -e

# Register a new project with CTSDeploy.
# Usage: sudo bash bootstrap_project.sh <github-repo-url>
# Example: sudo bash bootstrap_project.sh https://github.com/yourname/myapp

INSTALL_DIR="/opt/ctsdeploy"
SERVICE_USER="ctsdeploy"
REPO_URL="$1"

if [ -z "$REPO_URL" ]; then
    echo "Usage: sudo bash bootstrap_project.sh <github-repo-url>"
    exit 1
fi

# Load domain from the environment config file written by install.sh
ENV_FILE="/etc/ctsdeploy.env"
if [ -f "$ENV_FILE" ]; then
    # Fix #16: read DOMAIN from env file instead of hardcoding it
    # Fix #8 (audit): use -f2- so values containing = are not truncated
    DOMAIN=$(grep "^DOMAIN=" "$ENV_FILE" | cut -d= -f2-)
else
    echo "ERROR: $ENV_FILE not found — run install.sh first."
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

if [ -d "$PROJECT_DIR" ]; then
    echo "Project directory already exists at $PROJECT_DIR — skipping clone."
    echo "If you want to re-clone, remove the directory first."
else
    echo "==> Cloning $SSH_URL into $PROJECT_DIR..."
    # Fix #7: use the correct SSH key path at $INSTALL_DIR/.ssh (not /home/$SERVICE_USER/.ssh)
    sudo -u "$SERVICE_USER" \
        GIT_SSH_COMMAND="ssh -i $INSTALL_DIR/.ssh/id_ed25519 -o UserKnownHostsFile=$INSTALL_DIR/.ssh/known_hosts -o StrictHostKeyChecking=yes" \
        git clone "$SSH_URL" "$PROJECT_DIR"
    echo "    Cloned into $PROJECT_DIR"
fi

DEPLOY_YAML="$PROJECT_DIR/deploy.yaml"
if [ ! -f "$DEPLOY_YAML" ]; then
    echo ""
    echo "ERROR: deploy.yaml not found in the root of $REPO_NAME."
    echo "Add one with at minimum:"
    echo ""
    echo "  project_name: myapp"
    echo "  port: 8080"
    echo "  branch: main"
    echo ""
    echo "Then push a commit — CTSDeploy will handle the rest automatically."
    exit 1
fi

# Fix #2 / #6 (audit): use venv Python (PyYAML is only installed there, not system-wide)
# and handle missing/null project_name with a clear error message
VENV_PYTHON="$INSTALL_DIR/venv/bin/python3"
PROJECT_NAME=$("$VENV_PYTHON" -c "
import sys, yaml
try:
    c = yaml.safe_load(open('$DEPLOY_YAML'))
    name = c.get('project_name') if isinstance(c, dict) else None
    if not name:
        print('ERROR: project_name is missing or null in deploy.yaml', file=sys.stderr)
        sys.exit(1)
    print(str(name).lower())
except yaml.YAMLError as e:
    print(f'ERROR: deploy.yaml is not valid YAML: {e}', file=sys.stderr)
    sys.exit(1)
") || exit 1

# Fix #15: nginx config is now written exclusively by nginx_manager.py on first deploy.
# bootstrap_project.sh no longer writes its own conflicting template.
# The first push to the repo will trigger auto-deploy which sets up nginx + SSL.

echo ""
echo "Project '$PROJECT_NAME' registered."
echo ""
echo "  Repo      : $REPO_NAME"
echo "  Directory : $PROJECT_DIR"
echo "  Subdomain : $PROJECT_NAME.$DOMAIN (active after first deploy)"
echo ""
echo "Next steps:"
echo "  1. Add a GitHub webhook to the repo:"
echo "       URL    : https://hooks.$DOMAIN/webhook"
echo "       Secret : (your WEBHOOK_SECRET from /etc/ctsdeploy.env)"
echo "       Content: application/json"
echo "  2. Push to the deploy branch to trigger your first auto-deploy."
echo "     CTSDeploy will configure nginx and provision SSL automatically."
