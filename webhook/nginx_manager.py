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
        # Directory exists but we can't stat it — check for the cert file directly
        return Path(f"/etc/letsencrypt/live/{fqdn}/fullchain.pem").exists()


def update_nginx_config(project_name: str, port: int):
    fqdn = f"{project_name}.{DOMAIN}"
    if cert_exists(fqdn):
        config = NGINX_SSL_TEMPLATE.format(fqdn=fqdn, port=port)
    else:
        config = NGINX_HTTP_TEMPLATE.format(fqdn=fqdn, port=port)

    config_path = os.path.join(NGINX_SITES_DIR, f"{project_name}.conf")

    # Write via tee with sudo since sites-enabled is root-owned
    tee = subprocess.run(
        ["sudo", "tee", config_path],
        input=config,
        capture_output=True,
        text=True,
    )
    if tee.returncode != 0:
        raise RuntimeError(f"Failed to write nginx config: {tee.stderr}")

    subprocess.run(["sudo", "/usr/sbin/nginx", "-t"], check=True)
    subprocess.run(["sudo", "/usr/sbin/nginx", "-s", "reload"], check=True)
