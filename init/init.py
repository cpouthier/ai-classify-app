#!/usr/bin/env python3
"""Init job for the Puls8 RAG demo: pulls the Ollama model, then creates a knowledge
collection in Open WebUI and uploads every file found under /kb into it.

Uses only the Python standard library (urllib) on purpose, so the Job can run on the plain
python:3-alpine multi-arch image with no custom image build required.

Open WebUI's REST API has changed shape across releases (file upload used to live at
/api/v1/documents/doc/upload, it is now plain POST /api/v1/files/, for example). The paths
below were verified against the routers actually installed in open-webui:16.6.0 / app 0.11.4
(`kubectl exec <pod> -- grep -rn '@router' open_webui/routers/{files,knowledge,auths}.py`).
If you're on a different version, re-check the same way before trusting these paths again.
"""

import json
import mimetypes
import os
import sys
import time
import urllib.error
import urllib.request
import uuid

OLLAMA_URL = os.environ.get("OLLAMA_URL", "http://ollama:11434").rstrip("/")
OPENWEBUI_URL = os.environ.get("OPENWEBUI_URL", "http://open-webui:80").rstrip("/")
MODEL_NAME = os.environ.get("MODEL_NAME", "qwen2.5:1.5b")
ADMIN_NAME = os.environ.get("WEBUI_ADMIN_NAME", "Demo Admin")
ADMIN_EMAIL = os.environ["WEBUI_ADMIN_EMAIL"]
ADMIN_PASSWORD = os.environ["WEBUI_ADMIN_PASSWORD"]
KB_NAME = os.environ.get("KB_NAME", "puls8-demo-kb")
KB_DIR = os.environ.get("KB_DIR", "/kb")
WAIT_TIMEOUT = int(os.environ.get("WAIT_TIMEOUT_SECONDS", "300"))


def wait_for(url, timeout):
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            urllib.request.urlopen(url, timeout=5)
            return
        except Exception:
            time.sleep(5)
    raise SystemExit(f"Timed out waiting for {url}")


def http_json(method, url, payload=None, token=None):
    data = json.dumps(payload).encode() if payload is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("Content-Type", "application/json")
    if token:
        req.add_header("Authorization", f"Bearer {token}")
    with urllib.request.urlopen(req, timeout=60) as resp:
        body = resp.read()
        return json.loads(body) if body else {}


def pull_model():
    print(f"Pulling Ollama model {MODEL_NAME} ...")
    req = urllib.request.Request(
        f"{OLLAMA_URL}/api/pull",
        data=json.dumps({"name": MODEL_NAME}).encode(),
        method="POST",
    )
    req.add_header("Content-Type", "application/json")
    with urllib.request.urlopen(req, timeout=1800) as resp:
        for raw_line in resp:
            if not raw_line.strip():
                continue
            line = json.loads(raw_line)
            status = line.get("status", "")
            print(f"  ollama: {status}")
            if line.get("error"):
                raise SystemExit(f"ollama pull failed: {line['error']}")
    print("Model pull complete.")


def get_webui_token():
    signup_payload = {"name": ADMIN_NAME, "email": ADMIN_EMAIL, "password": ADMIN_PASSWORD}
    try:
        result = http_json("POST", f"{OPENWEBUI_URL}/api/v1/auths/signup", signup_payload)
        print("Created Open WebUI admin account.")
        return result["token"]
    except urllib.error.HTTPError as exc:
        # Any signup failure (account already exists -> 400/409, or public signup closed
        # because an admin already exists -> 403) means there's already a user to log into
        # instead. If WEBUI_ADMIN_EMAIL/PASSWORD don't match that existing account, the
        # signin call below raises its own clear error (401).
        print(f"Signup unavailable ({exc.code}), trying sign-in with the configured admin credentials instead.")
        result = http_json(
            "POST",
            f"{OPENWEBUI_URL}/api/v1/auths/signin",
            {"email": ADMIN_EMAIL, "password": ADMIN_PASSWORD},
        )
        return result["token"]


def create_knowledge_collection(token):
    try:
        result = http_json(
            "POST",
            f"{OPENWEBUI_URL}/api/v1/knowledge/create",
            {"name": KB_NAME, "description": "Puls8 BC/DR demo knowledge base"},
            token=token,
        )
        print(f"Created knowledge collection {KB_NAME} ({result['id']}).")
        return result["id"]
    except urllib.error.HTTPError as exc:
        if exc.code != 400:
            raise
        print("Knowledge collection already exists, listing to find its id.")
        collections = http_json("GET", f"{OPENWEBUI_URL}/api/v1/knowledge/", token=token)
        for coll in collections["items"]:
            if coll["name"] == KB_NAME:
                return coll["id"]
        raise SystemExit(f"Could not find or create knowledge collection {KB_NAME}")


def encode_multipart(field_name, filename, content, content_type):
    boundary = uuid.uuid4().hex
    body = (
        f"--{boundary}\r\n"
        f'Content-Disposition: form-data; name="{field_name}"; filename="{filename}"\r\n'
        f"Content-Type: {content_type}\r\n\r\n"
    ).encode() + content + f"\r\n--{boundary}--\r\n".encode()
    return body, boundary


def upload_document(token, path):
    filename = os.path.basename(path)
    content_type = mimetypes.guess_type(filename)[0] or "application/octet-stream"
    with open(path, "rb") as fh:
        content = fh.read()
    body, boundary = encode_multipart("file", filename, content, content_type)
    req = urllib.request.Request(
        f"{OPENWEBUI_URL}/api/v1/files/", data=body, method="POST"
    )
    req.add_header("Authorization", f"Bearer {token}")
    req.add_header("Content-Type", f"multipart/form-data; boundary={boundary}")
    with urllib.request.urlopen(req, timeout=120) as resp:
        return json.loads(resp.read())


def wait_for_file_processed(token, file_id, timeout=120):
    # Upload queues text extraction as a background task and returns immediately (status:
    # pending -> completed). Adding the file to a knowledge collection before that finishes
    # fails with a "content is empty" 400, so wait for it here.
    deadline = time.time() + timeout
    while time.time() < deadline:
        result = http_json("GET", f"{OPENWEBUI_URL}/api/v1/files/{file_id}", token=token)
        status = (result.get("data") or {}).get("status")
        if status == "completed":
            return
        if status == "failed":
            raise SystemExit(f"Open WebUI failed to process file {file_id}")
        time.sleep(2)
    raise SystemExit(f"Timed out waiting for Open WebUI to finish processing file {file_id}")


def add_file_to_collection(token, collection_id, file_id):
    http_json(
        "POST",
        f"{OPENWEBUI_URL}/api/v1/knowledge/{collection_id}/file/add",
        {"file_id": file_id},
        token=token,
    )


def load_knowledge_base(token, collection_id):
    if not os.path.isdir(KB_DIR):
        print(f"No {KB_DIR} directory found, skipping knowledge base upload.")
        return
    files = sorted(
        os.path.join(KB_DIR, f)
        for f in os.listdir(KB_DIR)
        if os.path.isfile(os.path.join(KB_DIR, f))
    )
    if not files:
        print(f"{KB_DIR} is empty, nothing to upload.")
        return
    for path in files:
        print(f"Uploading {path} ...")
        doc = upload_document(token, path)
        wait_for_file_processed(token, doc["id"])
        add_file_to_collection(token, collection_id, doc["id"])
        print(f"  added to collection {collection_id} as {doc['id']}")


def main():
    print(f"Waiting for Ollama at {OLLAMA_URL} ...")
    wait_for(f"{OLLAMA_URL}/api/tags", WAIT_TIMEOUT)
    print(f"Waiting for Open WebUI at {OPENWEBUI_URL} ...")
    wait_for(f"{OPENWEBUI_URL}/health", WAIT_TIMEOUT)

    pull_model()
    token = get_webui_token()
    collection_id = create_knowledge_collection(token)
    load_knowledge_base(token, collection_id)
    print("Init job complete.")


if __name__ == "__main__":
    try:
        main()
    except urllib.error.HTTPError as exc:
        print(f"Init job failed: {exc}: {exc.read().decode(errors='replace')}", file=sys.stderr)
        sys.exit(1)
    except Exception as exc:  # noqa: BLE001
        print(f"Init job failed: {exc}", file=sys.stderr)
        sys.exit(1)
