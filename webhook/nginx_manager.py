import os
import subprocess

NGINX_SITES_DIR = os.environ.get("NGINX_SITES_DIR", "/etc/nginx/sites-enabled")
DOMAIN = os.environ.get("DOMAIN", "benkruseski.com")

NGINX_TEMPLATE = """\
server {{
    listen 80;
    server_name {project_name}.{domain};

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


def update_nginx_config(project_name: str, port: int):
    config = NGINX_TEMPLATE.format(project_name=project_name, domain=DOMAIN, port=port)
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
