import hashlib
import hmac
import json
import os

from fastapi import BackgroundTasks, FastAPI, Header, HTTPException, Request

from deployer import deploy_project

app = FastAPI()

WEBHOOK_SECRET = os.environ.get("WEBHOOK_SECRET", "")


def verify_signature(payload: bytes, signature: str) -> bool:
    expected = "sha256=" + hmac.new(
        WEBHOOK_SECRET.encode(), payload, hashlib.sha256
    ).hexdigest()
    return hmac.compare_digest(expected, signature)


@app.get("/health")
async def health():
    return {"status": "ok"}


@app.post("/webhook")
async def webhook(
    request: Request,
    background_tasks: BackgroundTasks,
    x_hub_signature_256: str = Header(None),
    x_github_event: str = Header(None),
):
    payload = await request.body()

    if WEBHOOK_SECRET:
        if not x_hub_signature_256:
            raise HTTPException(status_code=401, detail="Missing signature")
        if not verify_signature(payload, x_hub_signature_256):
            raise HTTPException(status_code=401, detail="Invalid signature")

    if x_github_event != "push":
        return {"status": "ignored", "event": x_github_event}

    data = json.loads(payload)
    repo_name = data["repository"]["name"]
    branch = data["ref"].replace("refs/heads/", "")

    background_tasks.add_task(deploy_project, repo_name, branch)
    return {"status": "accepted", "repo": repo_name, "branch": branch}
