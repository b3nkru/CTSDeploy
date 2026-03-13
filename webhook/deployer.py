import logging
import os
import subprocess
from pathlib import Path

import yaml

from nginx_manager import update_nginx_config

PROJECTS_DIR = os.environ.get("PROJECTS_DIR", "/opt/ctsdeploy/projects")
SSH_KEY = "/home/ctsdeploy/.ssh/id_ed25519"
KNOWN_HOSTS = "/home/ctsdeploy/.ssh/known_hosts"
GIT_SSH_COMMAND = f"ssh -i {SSH_KEY} -o UserKnownHostsFile={KNOWN_HOSTS} -o StrictHostKeyChecking=no"

LOG_DIR = Path("/var/log/ctsdeploy")
LOG_DIR.mkdir(parents=True, exist_ok=True)

logging.basicConfig(
    filename=str(LOG_DIR / "deploy.log"),
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(message)s",
)
log = logging.getLogger(__name__)


def run(cmd: list[str], cwd: str) -> tuple[int, str]:
    env = os.environ.copy()
    env["GIT_SSH_COMMAND"] = GIT_SSH_COMMAND
    result = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, env=env)
    return result.returncode, result.stdout + result.stderr


def deploy_project(repo_name: str, pushed_branch: str) -> dict:
    project_dir = os.path.join(PROJECTS_DIR, repo_name)
    log.info(f"Deploy triggered: repo={repo_name} branch={pushed_branch}")

    if not os.path.isdir(project_dir):
        msg = f"Project directory not found: {project_dir}"
        log.error(msg)
        return {"status": "error", "message": msg}

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

    log.info(f"Deploy complete: {project_name}.benkruseski.com")
    return {"status": "success", "project": project_name, "subdomain": f"{project_name}.benkruseski.com"}
