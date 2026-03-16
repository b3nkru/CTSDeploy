import logging
import os
import subprocess
from pathlib import Path  # used for LOG_DIR

import yaml

from nginx_manager import cert_exists, update_nginx_config

PROJECTS_DIR = os.environ.get("PROJECTS_DIR", "/opt/ctsdeploy/projects")
DOMAIN = os.environ.get("DOMAIN", "benkruseski.com")
CERTBOT_EMAIL = os.environ.get("CERTBOT_EMAIL", "rw2dm13@gmail.com")
SSH_KEY = "/opt/ctsdeploy/.ssh/id_ed25519"
KNOWN_HOSTS = "/opt/ctsdeploy/.ssh/known_hosts"
GIT_SSH_COMMAND = f"ssh -i {SSH_KEY} -o UserKnownHostsFile={KNOWN_HOSTS} -o StrictHostKeyChecking=no"

LOG_DIR = Path("/var/log/ctsdeploy")
LOG_DIR.mkdir(parents=True, exist_ok=True)

log = logging.getLogger("ctsdeploy")
log.setLevel(logging.INFO)
if not log.handlers:
    _fh = logging.FileHandler(str(LOG_DIR / "deploy.log"))
    _fh.setFormatter(logging.Formatter("%(asctime)s %(levelname)s %(message)s"))
    log.addHandler(_fh)
    log.propagate = False


def run(cmd: list[str], cwd: str = None) -> tuple[int, str]:
    env = os.environ.copy()
    env["GIT_SSH_COMMAND"] = GIT_SSH_COMMAND
    result = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, env=env)
    return result.returncode, result.stdout + result.stderr


def issue_ssl_cert(subdomain: str) -> bool:
    fqdn = f"{subdomain}.{DOMAIN}"
    if cert_exists(fqdn):
        log.info(f"SSL cert already exists for {fqdn} — skipping certbot")
        return True

    log.info(f"Issuing SSL cert for {fqdn}...")
    code, out = run([
        "sudo", "certbot", "--nginx",
        "-d", fqdn,
        "--non-interactive",
        "--agree-tos",
        "-m", CERTBOT_EMAIL,
    ])
    if code != 0:
        log.error(f"certbot failed for {fqdn}:\n{out}")
        return False

    log.info(f"SSL cert issued for {fqdn}")
    return True


def deploy_project(repo_name: str, pushed_branch: str, ssh_url: str) -> dict:
    project_dir = os.path.join(PROJECTS_DIR, repo_name)
    log.info(f"Deploy triggered: repo={repo_name} branch={pushed_branch}")

    # Auto-bootstrap: clone repo on first push if not already present
    if not os.path.isdir(project_dir):
        log.info(f"Project not found locally — cloning {ssh_url}...")
        code, out = run(["git", "clone", ssh_url, project_dir])
        if code != 0:
            log.error(f"git clone failed:\n{out}")
            return {"status": "error", "step": "git clone", "output": out}
        log.info(f"Cloned {repo_name} into {project_dir}")

    deploy_yaml_path = os.path.join(project_dir, "deploy.yaml")
    if not os.path.isfile(deploy_yaml_path):
        msg = "deploy.yaml not found in project root"
        log.error(msg)
        return {"status": "error", "message": msg}

    with open(deploy_yaml_path) as f:
        config = yaml.safe_load(f)

    project_name = config["project_name"].lower()
    port = config["port"]
    deploy_branch = config.get("branch", "main")

    if pushed_branch != deploy_branch:
        msg = f"Push to '{pushed_branch}', deploy branch is '{deploy_branch}' — skipping"
        log.info(msg)
        return {"status": "skipped", "message": msg}

    log.info(f"Pulling latest code for {project_name}...")
    code, out = run(["git", "pull", "origin", deploy_branch], cwd=project_dir)
    if code != 0:
        log.error(f"git pull failed:\n{out}")
        return {"status": "error", "step": "git pull", "output": out}

    log.info(f"Building and starting containers for {project_name}...")
    code, out = run(["docker", "compose", "up", "-d", "--build"], cwd=project_dir)
    if code != 0:
        log.error(f"docker compose failed:\n{out}")
        return {"status": "error", "step": "docker compose", "output": out}

    update_nginx_config(project_name, port)
    issue_ssl_cert(project_name)

    log.info(f"Deploy complete: {project_name}.{DOMAIN}")
    return {"status": "success", "project": project_name, "subdomain": f"{project_name}.{DOMAIN}"}
