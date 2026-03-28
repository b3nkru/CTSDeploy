#!/bin/bash
set -e

# Deregister and remove a project from CTSDeploy.
# Usage: sudo bash remove_project.sh <project-name>
# Example: sudo bash remove_project.sh myapp
#
# The project-name is the value of `project_name` in deploy.yaml (not the repo name).

INSTALL_DIR="/opt/ctsdeploy"
PROJECT_NAME="$1"

if [ -z "$PROJECT_NAME" ]; then
    echo "Usage: sudo bash remove_project.sh <project-name>"
    echo "Example: sudo bash remove_project.sh myapp"
    exit 1
fi

# Load domain from env file
ENV_FILE="/etc/ctsdeploy.env"
if [ -f "$ENV_FILE" ]; then
    # Fix #8 (audit): use -f2- so values containing = are not truncated
    DOMAIN=$(grep "^DOMAIN=" "$ENV_FILE" | cut -d= -f2-)
else
    DOMAIN="unknown"
fi

VENV_PYTHON="$INSTALL_DIR/venv/bin/python3"

PROJECTS_DIR="$INSTALL_DIR/projects"
NGINX_CONF="/etc/nginx/sites-enabled/$PROJECT_NAME.conf"

# Find the project directory by matching project_name in deploy.yaml
REPO_DIR=""
for d in "$PROJECTS_DIR"/*/; do
    if [ -f "$d/deploy.yaml" ]; then
        # Fix #2 (audit): use venv Python — PyYAML is only installed in the venv
        pn=$("$VENV_PYTHON" -c "
import yaml, sys
try:
    c = yaml.safe_load(open('${d}deploy.yaml'))
    print(c.get('project_name', '').lower() if isinstance(c, dict) else '')
except Exception:
    print('')
" 2>/dev/null)
        if [ "$pn" = "$PROJECT_NAME" ]; then
            REPO_DIR="$d"
            break
        fi
    fi
done

if [ -z "$REPO_DIR" ] && [ ! -f "$NGINX_CONF" ]; then
    echo "ERROR: Project '$PROJECT_NAME' not found in $PROJECTS_DIR and no nginx config at $NGINX_CONF"
    exit 1
fi

# Confirm before destructive action
echo "This will:"
[ -n "$REPO_DIR" ] && echo "  - Stop and remove Docker containers in $REPO_DIR"
[ -n "$REPO_DIR" ] && echo "  - Delete project directory: $REPO_DIR"
[ -f "$NGINX_CONF" ] && echo "  - Remove nginx config: $NGINX_CONF"
echo ""
echo "SSL certificate for $PROJECT_NAME.$DOMAIN will NOT be revoked (manual step)."
echo ""
read -rp "Type '$PROJECT_NAME' to confirm: " CONFIRM
if [ "$CONFIRM" != "$PROJECT_NAME" ]; then
    echo "Aborted."
    exit 1
fi

if [ -n "$REPO_DIR" ]; then
    echo "==> Stopping containers..."
    # Try both docker-compose.yml and compose.yaml naming conventions
    for compose_file in "docker-compose.yml" "docker-compose.yaml" "compose.yml" "compose.yaml"; do
        if [ -f "$REPO_DIR/$compose_file" ]; then
            docker compose -f "$REPO_DIR/$compose_file" down --remove-orphans 2>/dev/null || true
            break
        fi
    done

    echo "==> Removing project directory..."
    rm -rf "$REPO_DIR"
fi

if [ -f "$NGINX_CONF" ]; then
    echo "==> Removing nginx config..."
    rm -f "$NGINX_CONF"
    if /usr/sbin/nginx -t 2>/dev/null; then
        /usr/sbin/nginx -s reload
    else
        echo "WARNING: nginx config test failed after removal — check nginx manually."
    fi
fi

echo ""
echo "Project '$PROJECT_NAME' removed."
echo ""
echo "To also revoke the SSL certificate, run:"
echo "  certbot revoke --cert-name $PROJECT_NAME.$DOMAIN"
