# demo-puls8-Kasten

Image classification demo app deployed across two Kubernetes clusters, for a BC/DR webinar
pairing DataCore Puls8's replicated storage with Veeam Kasten's backup/restore workflow.
Cluster1 runs the live app on Puls8's production StorageClass, cluster2 is the DR target on
Puls8's replicated DR StorageClass, and Veeam Kasten backs up, exports, and restores the app
between them.

This replaces an earlier RAG chatbot version of this demo, dropped because CPU-bound LLM
inference turned out to be too heavy for the target hardware. Single-image CPU classification
with ResNet-50 still has a small, predictable resource footprint by comparison.

## What it deploys

Namespace `ai-demo` on cluster1:

| Component | Role | Storage |
|---|---|---|
| `classify-app` | FastAPI backend (ONNX Runtime, ResNet-50/ImageNet) + a one-page frontend | PVC `images-data`, 5Gi |
| PostgreSQL | Stores classification results | PVC `postgres-data`, 5Gi |

The ONNX model itself is split across two more PVCs instead of only living inside the image,
on purpose, to make the point during the demo that a trained model and its weights are just as
important to back up as the database:

| PVC | Holds | Size |
|---|---|---|
| `ai-model` | The ONNX model graph (`model.onnx`) | 100Mi |
| `ai-trained-weight` | The model's trained weights (`model.onnx.data`) | 300Mi |

An initContainer on `classify-app` seeds both from the copy baked into the image the first time
a pod starts (a no-op afterward), so they exist as real, backed-up cluster data rather than
something that just comes back for free whenever the image is pulled.

All four PVCs use `sc-prod` on cluster1 and `sc-dr` on cluster2 (the two Puls8 replicated
StorageClasses). Every pod tolerates `node.kubernetes.io/not-ready` and
`node.kubernetes.io/unreachable` for only 30 seconds, so a node failure gets pods rescheduled
quickly during the BC demo instead of waiting on Kubernetes' 5 minute default.

Resource requests/limits (single-image CPU inference is light, this is not tight like an LLM
workload, but nodes are still 8GB/4 vCPU and also run Puls8 and Veeam Kasten):

| Component | Requests | Limits |
|---|---|---|
| `classify-app` | 200m / 256Mi | 1 / 512Mi |
| PostgreSQL | 200m / 384Mi | 1 / 768Mi |

Veeam Kasten resources (namespace `kasten-io`):

- `ai-demo-s3` Location Profile, S3 bucket for backup and export
- `ai-demo-hourly` Policy, hourly backup + export of `ai-demo` (an on-demand run is always
  available too, via a RunAction or the Veeam Kasten dashboard's "Run Once" button)
- `ai-demo-postgres-blueprint` + `ai-demo-postgres-binding`, app-consistent PostgreSQL backup
  (`pg_dumpall` streamed to the S3 profile via kando, restored with `psql`). Verified directly
  against a live Kasten install's CRDs, not just written from the general schema docs.
- `sc-prod-to-sc-dr` TransformSet, rewrites the StorageClass on restore into cluster2 and
  patches the `cluster-config` ConfigMap's `CLUSTER_NAME` to cluster2's display name

## The app

- `POST /upload`: one or more images (multipart, field name `files`). Each is saved to
  `images-data`, classified, and inserted into PostgreSQL: `sequence_id` (serial), `uuid`,
  `filename`, `label` + `confidence` (top-1), a `top3` array, `created_at` (UTC), `pod_name`
  and `node_name` (both from the Downward API).
- `GET /results`: the stored rows, most recent first.
- `DELETE /results`: deletes every image (row + file).
- `GET /image/{uuid}`: serves the stored image file.
- `DELETE /image/{uuid}`: deletes one image (row + file).
- `GET /meta`: cluster name, current pod/node, total image count, last sequence id, everything
  the frontend's banner needs.
- `GET /healthz`: liveness/readiness target.
- `GET /`: the one-page frontend (no build step, plain HTML/CSS/JS), drag-and-drop multi-file
  upload, a card grid (thumbnail, label + confidence, `#sequence_id`, short uuid, timestamp,
  pod/node, a per-card delete button) and a "Delete all images" button, and a banner (cluster
  name, pod, node, total images, last sequence id). Polls `/meta` and `/results` every 3
  seconds, no manual refresh needed during the demo.

The model (ResNet-50, ImageNet-1000 classes) is exported to ONNX and baked into the
image at build time, the running container never depends on torch or the internet.

## Repository layout

| Path | Purpose |
|---|---|
| `app/` | FastAPI backend source (`main.py`, `db.py`, `inference.py`) |
| `frontend/` | The single-page frontend served at `/` |
| `Dockerfile` | Multi-stage build: exports the ONNX model, then a slim onnxruntime runtime image |
| `manifests/` | Namespace |
| `postgres/` | PostgreSQL Deployment, Service, PVC, credential Secret template |
| `classify-app/` | `classify-app` PVCs (images, model, weights), Deployment, Service, Ingress template |
| `kasten/` | Location Profile, Policy, PostgreSQL Blueprint/Binding, TransformSet |
| `scripts/` | `deploy-cluster1.sh`, `teardown-cluster1.sh`, `demo-bc.sh`, `demo-dr.sh`, `build-image.sh` |
| `samples/` | A few synthetic placeholder images for exercising the upload pipeline |
| `doc/` | Screenshots for this README's user guide |

No file named `*.yaml.tpl` should be applied directly or committed with real values, they are
templates documenting the Secret/config keys the other manifests expect. The deploy script
creates the actual Secrets and ConfigMaps imperatively from values you type in at deploy time,
so no credential ever lands in git.

The `classify-app` image is published on Docker Hub as `docker.io/cpouthier/ai-image-classify`.
`scripts/build-image.sh` rebuilds and pushes it (multi-arch, `docker buildx`) if you change the
app code, that script is the only place image-build details live.

## Deploying

Requires `kubectl` pointed at cluster1, and an S3 bucket (or S3-compatible endpoint) reachable
from both clusters for Kasten backup/export.

```bash
./scripts/deploy-cluster1.sh [kube-context]
```

This walks through, in order: listing the cluster's StorageClasses and asking which one to use
for the PVCs, creating the namespace, prompting for and creating the PostgreSQL credentials and
the cluster's display name (`cluster-config` ConfigMap) as Kubernetes Secrets/ConfigMaps,
deploying PostgreSQL, deploying `classify-app`, asking how to expose it (LoadBalancer, Ingress
via nginx, Ingress via Traefik, or none, whatever the cluster actually has, nothing is assumed),
then applying the hourly backup+export Policy. For the Location Profile, the PostgreSQL
Blueprint/Binding, and the TransformSet, the script asks separately whether to create each one
itself or leave it to you to apply manually, in case you'd rather set them up by hand or already
have them from a previous run.

At the end, the script prints the URL to open the app in a browser: the LoadBalancer address
once one is assigned, the Ingress hostname you gave it, or a `port-forward` command if you chose
to expose it yourself.

To tear it down: `./scripts/teardown-cluster1.sh [kube-context]` (keeps the S3 profile and
credentials, since cluster2 still needs them for DR import).

### Preparing cluster2 (DR side)

Cluster2 does not run its own copy of the app, it only needs Veeam Kasten with:

```bash
kubectl --context <cluster2-context> apply -f kasten/location-profile.yaml
kubectl --context <cluster2-context> apply -f kasten/transformset.yaml
```

using the same bucket/credentials as cluster1's profile, and the TransformSet's
`CLUSTER_NAME` value filled in for cluster2 (the deploy script does this substitution for you
if you choose to create the TransformSet through it).

## Demo runbook

### Pre-demo checklist

- [ ] Cluster1 `ai-demo` namespace healthy: `kubectl get pods -n ai-demo` all Running
- [ ] `ai-demo-hourly` Policy has run at least once (`kubectl get policyrun -n kasten-io`) so a
      restore point with an export exists
- [ ] App reachable, upload a sample from `samples/` and confirm a card appears in the grid
      within 3 seconds
- [ ] Cluster2 has `ai-demo-s3` profile and `sc-prod-to-sc-dr` TransformSet applied
- [ ] `sc-prod` and `sc-dr` StorageClasses exist and are healthy on their respective clusters
- [ ] Know which worker node on cluster1 you will fail for the BC step

### BC (business continuity) step, cluster1

```bash
./scripts/demo-bc.sh <node-name> [kube-context]
```

Shows current pod placement, cordons (and optionally drains) the chosen node, then watches
`ai-demo` pods until they reschedule onto a healthy node. Talking point: the 30 second
toleration is what makes the reschedule fast instead of the Kubernetes default 5 minute wait,
and uploads keep working (aside from a brief gap) throughout.

Uncordon the node after the demo: `kubectl uncordon <node-name>`.

### DR (disaster recovery) step, cluster2

```bash
./scripts/demo-dr.sh [kube-context]
```

Triggers a Kasten import from the `ai-demo-s3` profile, lists the available restore points for
`ai-demo`, then restores the chosen one with the `sc-prod-to-sc-dr` TransformSet applied so
every PVC lands on `sc-dr` and the banner's cluster name switches to cluster2's. Confirms with
you before actually restoring. Talking point: the PostgreSQL data (every classification result)
comes back through the Blueprint's `pg_dumpall`/`psql` cycle, an app-consistent logical restore,
not a raw disk snapshot, and the uploaded images come back from the PVC snapshot/export
alongside it.

## Notes and caveats

- Kasten's Policy/ImportAction/RestoreAction CRD field names can shift slightly between
  releases. `demo-dr.sh` calls out where to double check (`kubectl explain <kind>.spec
  --recursive`) before the first run against a new environment. The Blueprint/BlueprintBinding
  in `kasten/` were verified directly against a live cluster's installed CRDs, so those two are
  on firmer ground.
- The TransformSet's ConfigMap patch uses a JSON Patch `add` (not `replace`) on
  `/data/CLUSTER_NAME`, so it works whether or not that key survived the restore.
