import os
import subprocess
from pathlib import Path

NGINX_SITES_DIR = os.environ.get("NGINX_SITES_DIR", "/etc/nginx/sites-enabled")
DOMAIN = os.environ.get("DOMAIN", "benkruseski.com")

NGINX_HTTP_TEMPLATE = """\
server {{
    listen 80;
    listen [::]:80;
    server_name {fqdn};

    location / {{
        proxy_pass http://localhost:{port};
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_cache_bypass $http_upgrade;
    }}
}}
"""

NGINX_SSL_TEMPLATE = """\
server {{
    listen 80;
    listen [::]:80;
    server_name {fqdn};
    return 301 https://$host$request_uri;
}}

server {{
    listen 443 ssl;
    listen [::]:443 ssl;
    server_name {fqdn};

    ssl_certificate /etc/letsencrypt/live/{fqdn}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/{fqdn}/privkey.pem;
    include /etc/letsencrypt/options-ssl-nginx.conf;
    ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem;

    location / {{
        proxy_pass http://localhost:{port};
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_cache_bypass $http_upgrade;
    }}
}}
"""


def cert_exists(fqdn: str) -> bool:
    """Check if a Let's Encrypt cert exists for the given FQDN."""
    try:
        return Path(f"/etc/letsencrypt/live/{fqdn}").exists()
    except PermissionError:
        # Fix #9: previous code re-raised the same PermissionError.
        # If we can't stat the directory, assume no cert — certbot will create one.
        return False


def update_nginx_config(project_name: str, port: int):
    fqdn = f"{project_name}.{DOMAIN}"
    if cert_exists(fqdn):
        config = NGINX_SSL_TEMPLATE.format(fqdn=fqdn, port=port)
    else:
        config = NGINX_HTTP_TEMPLATE.format(fqdn=fqdn, port=port)

    config_path = os.path.join(NGINX_SITES_DIR, f"{project_name}.conf")

    # Fix #8: read existing config so we can roll back if nginx -t fails
    backup_config = None
    backup_proc = subprocess.run(
        ["sudo", "cat", config_path], capture_output=True, text=True
    )
    if backup_proc.returncode == 0:
        backup_config = backup_proc.stdout

    # Write new config via tee (sites-enabled is root-owned)
    tee = subprocess.run(
        ["sudo", "tee", config_path],
        input=config,
        capture_output=True,
        text=True,
    )
    if tee.returncode != 0:
        raise RuntimeError(f"Failed to write nginx config: {tee.stderr}")

    # Test the new config; roll back and raise on failure
    test = subprocess.run(
        ["sudo", "/usr/sbin/nginx", "-t"], capture_output=True, text=True
    )
    if test.returncode != 0:
        # Fix #8 / fix #4: restore previous config (or remove if this was a new file),
        # and check rollback operation return codes so failures are visible in the error
        rollback_note = ""
        if backup_config is not None:
            rb_tee = subprocess.run(
                ["sudo", "tee", config_path],
                input=backup_config,
                capture_output=True,
                text=True,
            )
            if rb_tee.returncode != 0:
                rollback_note = f" [ROLLBACK WRITE FAILED: {rb_tee.stderr.strip()}]"
            else:
                rb_reload = subprocess.run(
                    ["sudo", "/usr/sbin/nginx", "-s", "reload"],
                    capture_output=True,
                    text=True,
                )
                if rb_reload.returncode != 0:
                    rollback_note = (
                        f" [ROLLBACK RELOAD FAILED: {rb_reload.stderr.strip()}]"
                    )
        else:
            rb_rm = subprocess.run(
                ["sudo", "rm", "-f", config_path], capture_output=True, text=True
            )
            if rb_rm.returncode != 0:
                rollback_note = f" [ROLLBACK REMOVE FAILED: {rb_rm.stderr.strip()}]"
        raise RuntimeError(
            f"nginx config test failed (rolled back{rollback_note}):\n"
            f"{test.stdout}{test.stderr}"
        )

    reload = subprocess.run(
        ["sudo", "/usr/sbin/nginx", "-s", "reload"], capture_output=True, text=True
    )
    if reload.returncode != 0:
        raise RuntimeError(
            f"nginx reload failed:\n{reload.stdout}{reload.stderr}"
        )
