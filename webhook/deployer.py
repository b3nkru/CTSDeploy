import os
import subprocess

import yaml

from nginx_manager import update_nginx_config

PROJECTS_DIR = os.environ.get("PROJECTS_DIR", "/opt/ctsdeploy/projects")


def run(cmd: list[str], cwd: str) -> tuple[int, str]:
    result = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True)
    return result.returncode, result.stdout + result.stderr


def deploy_project(repo_name: str, pushed_branch: str) -> dict:
    project_dir = os.path.join(PROJECTS_DIR, repo_name)

    if not os.path.isdir(project_dir):
        return {"status": "error", "message": f"Project directory not found: {project_dir}"}

    deploy_yaml_path = os.path.join(project_dir, "deploy.yaml")
    if not os.path.isfile(deploy_yaml_path):
        return {"status": "error", "message": "deploy.yaml not found in project root"}

    with open(deploy_yaml_path) as f:
        config = yaml.safe_load(f)

    project_name = config["project_name"]
    port = config["port"]
    deploy_branch = config.get("branch", "main")

    if pushed_branch != deploy_branch:
        return {
            "status": "skipped",
            "message": f"Push to '{pushed_branch}', deploy branch is '{deploy_branch}'",
        }

    code, out = run(["git", "pull", "origin", deploy_branch], cwd=project_dir)
    if code != 0:
        return {"status": "error", "step": "git pull", "output": out}

    code, out = run(["docker", "compose", "up", "-d", "--build"], cwd=project_dir)
    if code != 0:
        return {"status": "error", "step": "docker compose", "output": out}

    update_nginx_config(project_name, port)

    return {"status": "success", "project": project_name, "subdomain": f"{project_name}.benkruseski.com"}
