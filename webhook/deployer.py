import logging
import os
import re
import shutil
import subprocess
import threading
import time
from pathlib import Path

import yaml

from nginx_manager import cert_exists, update_nginx_config

PROJECTS_DIR = os.environ.get("PROJECTS_DIR", "/opt/ctsdeploy/projects")
DOMAIN = os.environ.get("DOMAIN", "benkruseski.com")
CERTBOT_EMAIL = os.environ.get("CERTBOT_EMAIL", "rw2dm13@gmail.com")
SSH_KEY = "/opt/ctsdeploy/.ssh/id_ed25519"
KNOWN_HOSTS = "/opt/ctsdeploy/.ssh/known_hosts"
# Fix #11: use StrictHostKeyChecking=yes — known_hosts is pre-seeded for github.com
GIT_SSH_COMMAND = (
    f"ssh -i {SSH_KEY} -o UserKnownHostsFile={KNOWN_HOSTS} -o StrictHostKeyChecking=yes"
)

# Fix #1: defer log directory creation — don't crash at import time
_LOG_DIR = Path(os.environ.get("LOG_DIR", "/var/log/ctsdeploy"))


def _setup_logging() -> logging.Logger:
    logger = logging.getLogger("ctsdeploy")
    logger.setLevel(logging.INFO)
    if logger.handlers:
        return logger
    # Always add a stream handler so logs reach journald even if file setup fails
    sh = logging.StreamHandler()
    sh.setFormatter(logging.Formatter("%(asctime)s %(levelname)s %(message)s"))
    logger.addHandler(sh)
    try:
        _LOG_DIR.mkdir(parents=True, exist_ok=True)
        fh = logging.FileHandler(str(_LOG_DIR / "deploy.log"))
        fh.setFormatter(logging.Formatter("%(asctime)s %(levelname)s %(message)s"))
        logger.addHandler(fh)
    except PermissionError:
        logger.warning(f"Cannot write to {_LOG_DIR} — logging to stdout only")
    logger.propagate = False
    return logger


log = _setup_logging()

# Fix #12: per-project deploy locks prevent concurrent deploys corrupting state
_project_locks: dict[str, threading.Lock] = {}
_locks_mu = threading.Lock()

# Fix #20: in-memory deploy history for /status endpoint
_deploy_history: dict[str, dict] = {}


def _project_lock(repo_name: str) -> threading.Lock:
    with _locks_mu:
        if repo_name not in _project_locks:
            _project_locks[repo_name] = threading.Lock()
        return _project_locks[repo_name]


def get_deploy_status(repo_name: str) -> dict | None:
    return _deploy_history.get(repo_name)


# Fix #6: validate project_name to prevent path traversal
def _validate_project_name(name: str) -> str:
    if not re.match(r"^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$", name):
        raise ValueError(
            f"Invalid project_name '{name}': must be 1–63 lowercase alphanumeric "
            "characters or hyphens, starting and ending with alphanumeric"
        )
    return name


def _validate_port(port) -> int:
    try:
        p = int(port)
    except (TypeError, ValueError):
        raise ValueError(f"Invalid port '{port}': must be an integer")
    if not (1024 <= p <= 65535):
        raise ValueError(f"Invalid port {p}: must be between 1024 and 65535")
    return p


# Fix #7: validate branch name before passing to git to prevent flag injection
_BRANCH_RE = re.compile(r"^[a-zA-Z0-9][a-zA-Z0-9._/-]{0,254}$")

def _validate_branch(branch: str) -> str:
    if not _BRANCH_RE.match(branch):
        raise ValueError(
            f"Invalid branch name '{branch}': must start with alphanumeric and "
            "contain only alphanumeric characters, dots, underscores, hyphens, or slashes"
        )
    return branch


# Fix #14: validate deploy.yaml schema with clear error messages
# Returns (project_name, port) only — branch is validated separately at pre-pull time
def _validate_config(config: dict) -> tuple[str, int]:
    if not isinstance(config, dict):
        raise ValueError("deploy.yaml must be a YAML mapping")
    missing = [k for k in ("project_name", "port") if k not in config]
    if missing:
        raise ValueError(f"deploy.yaml missing required keys: {', '.join(missing)}")
    project_name = _validate_project_name(str(config["project_name"]).lower())
    port = _validate_port(config["port"])
    return project_name, port


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
    # Fix #10: use the restricted certbot wrapper installed by install.sh
    code, out = run([
        "sudo", "ctsdeploy-certbot", "--nginx",
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
    # Fix #12: acquire per-project lock; skip if a deploy is already running
    lock = _project_lock(repo_name)
    if not lock.acquire(blocking=False):
        msg = f"Deploy already in progress for {repo_name} — skipping concurrent deploy"
        log.warning(msg)
        return {"status": "skipped", "message": msg}
    try:
        result = _do_deploy(repo_name, pushed_branch, ssh_url)
        # Fix #3 (race): update history inside the lock so a concurrent deploy
        # for the same repo cannot overwrite a newer result with an older one
        _deploy_history[repo_name] = {**result, "timestamp": time.time()}
    finally:
        lock.release()
    return result


def _do_deploy(repo_name: str, pushed_branch: str, ssh_url: str) -> dict:
    project_dir = os.path.join(PROJECTS_DIR, repo_name)
    log.info(f"Deploy triggered: repo={repo_name} branch={pushed_branch}")

    # Auto-bootstrap: clone repo on first push if not already present
    if not os.path.isdir(project_dir):
        log.info(f"Project not found locally — cloning {ssh_url}...")
        code, out = run(["git", "clone", ssh_url, project_dir])
        if code != 0:
            log.error(f"git clone failed:\n{out}")
            # Fix #18: remove partial clone so next run retries cleanly
            if os.path.isdir(project_dir):
                shutil.rmtree(project_dir, ignore_errors=True)
                log.info(f"Removed partial clone directory at {project_dir}")
            return {"status": "error", "step": "git clone", "output": out}
        log.info(f"Cloned {repo_name} into {project_dir}")

    deploy_yaml_path = os.path.join(project_dir, "deploy.yaml")
    if not os.path.isfile(deploy_yaml_path):
        msg = f"deploy.yaml not found in {repo_name} project root"
        log.error(msg)
        return {"status": "error", "message": msg}

    # Fix #2: read deploy.yaml before pull only for branch check
    with open(deploy_yaml_path) as f:
        pre_pull_config = yaml.safe_load(f) or {}
    try:
        # Fix #7: validate branch before passing it to git pull
        deploy_branch = _validate_branch(str(pre_pull_config.get("branch", "main")))
    except ValueError as e:
        log.error(f"Invalid branch in deploy.yaml for {repo_name}: {e}")
        return {"status": "error", "step": "config validation", "message": str(e)}

    if pushed_branch != deploy_branch:
        msg = f"Push to '{pushed_branch}', deploy branch is '{deploy_branch}' — skipping"
        log.info(msg)
        return {"status": "skipped", "message": msg}

    log.info(f"Pulling latest code for {repo_name}...")
    code, out = run(["git", "pull", "origin", deploy_branch], cwd=project_dir)
    if code != 0:
        log.error(f"git pull failed:\n{out}")
        return {"status": "error", "step": "git pull", "output": out}

    # Fix #2 (continued): re-read deploy.yaml after pull to pick up any config changes
    with open(deploy_yaml_path) as f:
        config = yaml.safe_load(f)

    # Fix #14: validate config with clear error messages before using any values
    try:
        project_name, port = _validate_config(config)
    except ValueError as e:
        log.error(f"Invalid deploy.yaml in {repo_name}: {e}")
        return {"status": "error", "step": "config validation", "message": str(e)}

    log.info(f"Building and starting containers for {project_name}...")
    code, out = run(["docker", "compose", "up", "-d", "--build"], cwd=project_dir)
    if code != 0:
        log.error(f"docker compose failed:\n{out}")
        return {"status": "error", "step": "docker compose", "output": out}

    # Fix #8: update_nginx_config now rolls back on failure; catch its errors here
    try:
        update_nginx_config(project_name, port)
    except RuntimeError as e:
        log.error(f"nginx config update failed for {project_name}: {e}")
        return {"status": "error", "step": "nginx", "message": str(e)}

    issue_ssl_cert(project_name)

    log.info(f"Deploy complete: {project_name}.{DOMAIN}")
    return {
        "status": "success",
        "project": project_name,
        "subdomain": f"{project_name}.{DOMAIN}",
    }
