import os

import numpy as np
import onnxruntime
from PIL import Image

# The model graph and its trained weights live on their own PVCs (ai-model, ai-trained-weight),
# not baked into the image, an initContainer seeds them from the image on first boot. This is
# meant to be visible in the demo: these files are as important to back up as the database.
MODEL_DIR = os.environ.get("MODEL_DIR", "/models/model")
MODEL_PATH = f"{MODEL_DIR}/model.onnx"
LABELS_PATH = "/app/labels.txt"

_IMAGENET_MEAN = np.array([0.485, 0.456, 0.406], dtype=np.float32)
_IMAGENET_STD = np.array([0.229, 0.224, 0.225], dtype=np.float32)

with open(LABELS_PATH) as f:
    LABELS = [line.strip() for line in f if line.strip()]

_session = onnxruntime.InferenceSession(MODEL_PATH, providers=["CPUExecutionProvider"])
_input_name = _session.get_inputs()[0].name


def _preprocess(image: Image.Image) -> np.ndarray:
    image = image.convert("RGB").resize((224, 224))
    array = np.asarray(image, dtype=np.float32) / 255.0
    array = (array - _IMAGENET_MEAN) / _IMAGENET_STD
    array = array.transpose(2, 0, 1)  # HWC -> CHW
    return np.expand_dims(array, axis=0)


def _softmax(logits: np.ndarray) -> np.ndarray:
    exp = np.exp(logits - np.max(logits))
    return exp / exp.sum()


def classify(image: Image.Image, top_k: int = 3):
    input_array = _preprocess(image)
    (logits,) = _session.run(None, {_input_name: input_array})
    probabilities = _softmax(logits[0])
    top_indices = np.argsort(probabilities)[::-1][:top_k]
    top = [
        {"label": LABELS[i], "confidence": float(probabilities[i])}
        for i in top_indices
    ]
    return top
