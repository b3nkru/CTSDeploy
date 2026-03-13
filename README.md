# CTSDeploy

Auto-deploy web apps to `<project>.benkruseski.com` subdomains from GitHub pushes.

## How it works

1. You push to a project's GitHub repo
2. GitHub sends a webhook to `hooks.benkruseski.com/webhook`
3. CTSDeploy reads `deploy.yaml` from the repo root
4. Runs `git pull` + `docker compose up -d --build`
5. Writes/updates the nginx config for `<project_name>.benkruseski.com`

## Prerequisites

On the Raspberry Pi:
- nginx installed
- Docker + Docker Compose installed
- Python 3.10+
- A Cloudflare account managing `benkruseski.com`

## Setup

### 1. Cloudflare DNS

Add a wildcard A record pointing to your Pi's static IP:

| Type | Name | Value |
|------|------|-------|
| A | `*.benkruseski.com` | `<your Pi IP>` |
| A | `hooks.benkruseski.com` | `<your Pi IP>` |

### 2. Router

Forward ports `80` and `443` to your Pi.

### 3. Install CTSDeploy

```bash
git clone https://github.com/benkruseski/CTSDeploy
cd CTSDeploy
sudo bash install.sh
```

This will:
- Create a `ctsdeploy` system user
- Install the webhook listener as a systemd service on port 9000
- Configure nginx to proxy `hooks.benkruseski.com` → the listener
- Prompt you for a webhook secret

### 4. SSL (recommended)

```bash
sudo apt install certbot python3-certbot-nginx
sudo certbot --nginx -d hooks.benkruseski.com
```

## Adding a project

```bash
sudo bash bootstrap_project.sh https://github.com/benkruseski/<repo-name>
```

This clones the repo, reads `deploy.yaml`, writes the nginx config, and registers the subdomain.

Then add an SSL cert for it:

```bash
sudo certbot --nginx -d <project_name>.benkruseski.com
```

## deploy.yaml

Add this file to the root of any project you want to deploy:

```yaml
project_name: calendar   # becomes calendar.benkruseski.com
port: 8080               # port your Docker container exposes
branch: main             # branch that triggers deploys
```

## GitHub Webhook

In each project repo: **Settings → Webhooks → Add webhook**

| Field | Value |
|-------|-------|
| Payload URL | `https://hooks.benkruseski.com/webhook` |
| Content type | `application/json` |
| Secret | (the secret you set during `install.sh`) |
| Events | Just the `push` event |

## Project structure on Pi

```
/opt/ctsdeploy/
  projects/
    <repo-name>/        ← git clone of each project
      deploy.yaml
      docker-compose.yml
      ...
  webhook/              ← CTSDeploy listener source
  venv/                 ← Python virtualenv
```
