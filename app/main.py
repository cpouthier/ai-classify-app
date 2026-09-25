import os
import uuid as uuid_lib
from pathlib import Path

from fastapi import FastAPI, UploadFile
from fastapi.responses import FileResponse, HTMLResponse, JSONResponse
from PIL import Image

import db
from inference import classify

IMAGES_DIR = Path(os.environ.get("IMAGES_DIR", "/data/images"))
IMAGES_DIR.mkdir(parents=True, exist_ok=True)

CLUSTER_NAME = os.environ.get("CLUSTER_NAME", "unknown-cluster")
POD_NAME = os.environ.get("POD_NAME", "unknown-pod")
NODE_NAME = os.environ.get("NODE_NAME", "unknown-node")

FRONTEND_PATH = Path(__file__).parent / "frontend" / "index.html"

app = FastAPI(title="AI Image Classifier")


@app.on_event("startup")
def on_startup():
    db.init_schema()


@app.get("/healthz")
def healthz():
    return {"status": "ok"}


@app.get("/meta")
def meta():
    stats = db.get_stats()
    return {
        "cluster_name": CLUSTER_NAME,
        "pod_name": POD_NAME,
        "node_name": NODE_NAME,
        **stats,
    }


@app.get("/results")
def results(limit: int = 200):
    return db.list_images(limit=limit)


@app.get("/image/{image_uuid}")
def get_image(image_uuid: str):
    row = db.get_image_row(image_uuid)
    if not row:
        return JSONResponse({"detail": "not found"}, status_code=404)
    return FileResponse(IMAGES_DIR / row["filename"])


@app.delete("/image/{image_uuid}")
def delete_image(image_uuid: str):
    row = db.delete_image(image_uuid)
    if not row:
        return JSONResponse({"detail": "not found"}, status_code=404)
    (IMAGES_DIR / row["filename"]).unlink(missing_ok=True)
    return {"status": "deleted", "uuid": image_uuid}


@app.delete("/results")
def delete_all_results():
    rows = db.delete_all_images()
    for row in rows:
        (IMAGES_DIR / row["filename"]).unlink(missing_ok=True)
    return {"status": "deleted", "count": len(rows)}


@app.post("/upload")
async def upload(files: list[UploadFile]):
    results_out = []
    for file in files:
        image_uuid = str(uuid_lib.uuid4())
        extension = Path(file.filename or "image").suffix or ".jpg"
        stored_filename = f"{image_uuid}{extension}"
        stored_path = IMAGES_DIR / stored_filename

        content = await file.read()
        with open(stored_path, "wb") as fh:
            fh.write(content)

        with Image.open(stored_path) as image:
            top3 = classify(image)

        row = db.insert_image(
            uuid=image_uuid,
            filename=stored_filename,
            label=top3[0]["label"],
            confidence=top3[0]["confidence"],
            top3=top3,
            pod_name=POD_NAME,
            node_name=NODE_NAME,
        )
        results_out.append(row)

    return results_out


@app.get("/", response_class=HTMLResponse)
def index():
    return FRONTEND_PATH.read_text()
