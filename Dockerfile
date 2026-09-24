# Stage 1: export the pretrained MobileNetV3-Small (ImageNet) weights to ONNX, plus the
# exact category label order that model was trained with. Kept as a separate stage so the
# heavy torch/torchvision toolchain never ends up in the runtime image.
# Reverted from ResNet-50: even single-image on-demand ResNet-50 CPU inference correlated with
# the same unexplained host crashes seen earlier with LLM inference, on hardware this unstable
# smaller is safer, but the crashes are very likely a host-level issue, not really about model size.
FROM python:3.11-slim AS model-export

RUN pip install --no-cache-dir torch torchvision --index-url https://download.pytorch.org/whl/cpu
# torch's onnx.export() now goes through a compat layer that imports onnxscript unconditionally,
# even for the legacy (non-dynamo) exporter path, without it export() fails at runtime, not at
# pip-install time, so this is easy to miss.
RUN pip install --no-cache-dir onnxscript

RUN python - <<'PY'
import torch
from torchvision.models import mobilenet_v3_small, MobileNet_V3_Small_Weights

weights = MobileNet_V3_Small_Weights.IMAGENET1K_V1
model = mobilenet_v3_small(weights=weights)
model.eval()

dummy_input = torch.randn(1, 3, 224, 224)
torch.onnx.export(
    model,
    dummy_input,
    "/model.onnx",
    input_names=["input"],
    output_names=["output"],
    dynamic_axes={"input": {0: "batch"}, "output": {0: "batch"}},
    opset_version=17,
)

with open("/labels.txt", "w") as f:
    f.write("\n".join(weights.meta["categories"]))
PY

# Stage 2: slim runtime image, CPU-only inference via onnxruntime.
FROM python:3.11-slim

WORKDIR /app

COPY app/requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY --from=model-export /model.onnx /app/model.onnx
# torch's onnx exporter saves the weights as external data next to the graph file (even for a
# model this small), onnxruntime needs both files present, model.onnx.data is not optional.
COPY --from=model-export /model.onnx.data /app/model.onnx.data
COPY --from=model-export /labels.txt /app/labels.txt

COPY app/ /app/
COPY frontend/ /app/frontend/

EXPOSE 8000
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000"]
