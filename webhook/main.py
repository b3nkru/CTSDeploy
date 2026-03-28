import hashlib
import hmac
import json
import logging
import os
import sys

from fastapi import BackgroundTasks, FastAPI, Header, HTTPException, Request

from deployer import deploy_project, get_deploy_status, log

WEBHOOK_SECRET = os.environ.get("WEBHOOK_SECRET", "")

# Fix #3: refuse to start if no secret is configured — open webhook is unacceptable
if not WEBHOOK_SECRET:
    logging.critical(
        "FATAL: WEBHOOK_SECRET is not set. "
        "Set it in /etc/ctsdeploy.env and restart the service."
    )
    sys.exit(1)

app = FastAPI()


def verify_signature(payload: bytes, signature: str) -> bool:
    expected = "sha256=" + hmac.new(
        WEBHOOK_SECRET.encode(), payload, hashlib.sha256
    ).hexdigest()
    return hmac.compare_digest(expected, signature)


@app.get("/health")
async def health():
    return {"status": "ok"}


# Fix #20: deploy status endpoint
@app.get("/status/{repo_name}")
async def status(repo_name: str):
    result = get_deploy_status(repo_name)
    if result is None:
        raise HTTPException(status_code=404, detail="No deploy history for this repo")
    return result


@app.post("/webhook")
async def webhook(
    request: Request,
    background_tasks: BackgroundTasks,
    x_hub_signature_256: str = Header(None),
    x_github_event: str = Header(None),
):
    payload = await request.body()

    # Fix #3 (continued): signature check is now always enforced
    if not x_hub_signature_256:
        raise HTTPException(status_code=401, detail="Missing signature")
    if not verify_signature(payload, x_hub_signature_256):
        raise HTTPException(status_code=401, detail="Invalid signature")

    if x_github_event != "push":
        log.info(f"Ignoring GitHub event: {x_github_event}")
        return {"status": "ignored", "event": x_github_event}

    # Fix #4: handle JSON parse errors and missing keys gracefully
    try:
        data = json.loads(payload)
        repo_name = data["repository"]["name"]
        branch = data["ref"].replace("refs/heads/", "")
        ssh_url = data["repository"]["ssh_url"]
    except json.JSONDecodeError as e:
        log.warning(f"Malformed webhook payload (invalid JSON): {e}")
        raise HTTPException(status_code=400, detail="Payload is not valid JSON")
    except KeyError as e:
        log.warning(f"Malformed webhook payload (missing key): {e}")
        raise HTTPException(status_code=400, detail=f"Missing required field: {e}")

    background_tasks.add_task(_safe_deploy, repo_name, branch, ssh_url)
    return {"status": "accepted", "repo": repo_name, "branch": branch}


def _safe_deploy(repo_name: str, branch: str, ssh_url: str):
    try:
        deploy_project(repo_name, branch, ssh_url)
    except Exception:
        log.exception(f"Unhandled exception deploying {repo_name}")
