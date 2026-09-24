# demo-puls8-Kasten

RAG demo app deployed across two Kubernetes clusters to demonstrate Puls8's replicated
storage and Veeam Kasten's BC/DR workflow together. Cluster1 runs the live app on Puls8's
production StorageClass, cluster2 is the DR target on Puls8's replicated DR StorageClass,
and Veeam Kasten backs up, exports, and restores the app between them.

## What it deploys

Namespace `ai-demo` on cluster1:

| Component | Role | Storage |
|---|---|---|
| Ollama | Serves a small local model (`qwen2.5:1.5b` or `llama3.2:1b`, CPU only) | PVC `ollama-models`, 5Gi |
| Open WebUI | Chat UI, RAG frontend, backed by pgvector | PVC `webui-data`, 2Gi |
| PostgreSQL + pgvector | Vector store and Open WebUI's database | PVC `postgres-data`, 5Gi |

All three PVCs use `sc-prod` on cluster1 and `sc-dr` on cluster2 (the two Puls8 replicated
StorageClasses). Every pod tolerates `node.kubernetes.io/not-ready` and
`node.kubernetes.io/unreachable` for only 30 seconds, so a node failure gets pods rescheduled
quickly during the BC demo instead of waiting on Kubernetes' 5 minute default.

Resource requests/limits are kept deliberately tight since nodes are 8GB/4 vCPU and also run
Puls8 and Veeam Kasten:

| Component | Requests | Limits |
|---|---|---|
| Ollama | 500m / 1.5Gi | 2 / 3Gi |
| Open WebUI | 200m / 384Mi | 1 / 768Mi |
| PostgreSQL | 200m / 384Mi | 1 / 768Mi |

Veeam Kasten resources (namespace `kasten-io`):

- `ai-demo-s3` Location Profile, S3 bucket for backup and export
- `ai-demo-hourly` Policy, hourly backup + export of `ai-demo`
- `ai-demo-postgres-blueprint` + `ai-demo-postgres-binding`, app-consistent PostgreSQL backup
  (`pg_dumpall` streamed to the S3 profile via kando, restored with `psql`)
- `sc-prod-to-sc-dr` TransformSet, rewrites the StorageClass on restore into cluster2

## Repository layout

| Path | Purpose |
|---|---|
| `manifests/` | Namespace |
| `postgres/` | PostgreSQL + pgvector Deployment, Service, PVC, credential Secret templates |
| `charts/` | Helm values for the `open-webui` chart (bundles the `ollama` sub-chart) |
| `init/` | Init Job: pulls the Ollama model and uploads `kb/` into Open WebUI via its API |
| `kb/` | Knowledge base source documents uploaded by the init Job |
| `kasten/` | Location Profile, Policy, PostgreSQL Blueprint/Binding, TransformSet |
| `scripts/` | `deploy-cluster1.sh`, `teardown-cluster1.sh`, `demo-bc.sh`, `demo-dr.sh` |
| `doc/` | Screenshots for this README's user guide |

No file under `postgres/`, `init/`, or `kasten/` named `*.yaml.tpl` should be applied
directly or committed with real values, they are templates documenting the Secret keys the
other manifests expect. The deploy script creates the actual Secrets imperatively from values
you type in at deploy time, so no credential ever lands in git.

## Deploying

Requires `kubectl` and `helm` pointed at cluster1, and an S3 bucket (or S3-compatible
endpoint) reachable from both clusters for Kasten backup/export.

```bash
./scripts/deploy-cluster1.sh [kube-context]
```

This walks through, in order: creating the namespace, prompting for and creating the
PostgreSQL/Open WebUI/S3 credentials as Kubernetes Secrets, deploying PostgreSQL, installing
the `open-webui` Helm chart (with the `ollama` sub-chart) from `charts/values-open-webui-cluster1.yaml`,
running the init Job to pull the model and load `kb/`, then creating the Kasten Location
Profile, hourly Policy, and PostgreSQL Blueprint/Binding.

To tear it down: `./scripts/teardown-cluster1.sh [kube-context]` (keeps the S3 profile and
credentials, since cluster2 still needs them for DR import).

### Preparing cluster2 (DR side)

Cluster2 does not run its own copy of the app, it only needs Veeam Kasten with:

```bash
kubectl --context <cluster2-context> apply -f kasten/location-profile.yaml
kubectl --context <cluster2-context> apply -f kasten/transformset.yaml
```

using the same bucket/credentials as cluster1's profile, so it can see the exports Kasten
produces from the hourly policy.

## Demo runbook

### Pre-demo checklist

- [ ] Cluster1 `ai-demo` namespace healthy: `kubectl get pods -n ai-demo` all Running
- [ ] `ai-demo-hourly` Policy has run at least once (`kubectl get policyrun -n kasten-io`) so a
      restore point with an export exists
- [ ] Open WebUI reachable and the `puls8-demo-kb` knowledge collection has the expected
      documents (chat once to confirm answers cite the knowledge base)
- [ ] Cluster2 has `ai-demo-s3` profile and `sc-prod-to-sc-dr` TransformSet applied
- [ ] `sc-prod` and `sc-dr` StorageClasses exist and are healthy on their respective clusters
- [ ] Know which worker node on cluster1 you will fail for the BC step

### BC (business continuity) step, cluster1

```bash
./scripts/demo-bc.sh <node-name> [kube-context]
```

Shows current pod placement, cordons (and optionally drains) the chosen node, then watches
`ai-demo` pods until they reschedule onto a healthy node. Talking point: the 30 second
toleration is what makes the reschedule fast instead of the Kubernetes default 5 minute wait.

Uncordon the node after the demo: `kubectl uncordon <node-name>`.

### DR (disaster recovery) step, cluster2

```bash
./scripts/demo-dr.sh [kube-context]
```

Triggers a Kasten import from the `ai-demo-s3` profile, lists the available restore points for
`ai-demo`, then restores the chosen one with the `sc-prod-to-sc-dr` TransformSet applied so
every PVC lands on `sc-dr`. Confirms with you before actually restoring. Talking point: the
PostgreSQL data comes back through the Blueprint's `pg_dumpall`/`psql` cycle, an
app-consistent logical restore, not a raw disk snapshot.

## Notes and caveats

- Open WebUI's REST API paths (used by `init/init.py`) and Kasten's Policy/ImportAction/
  RestoreAction CRD field names can shift slightly between releases. Both scripts call out
  where to double check (`/docs` Swagger UI for Open WebUI, `kubectl explain <kind>.spec
  --recursive` for Kasten) before the first run against a new environment.
- The init Job's knowledge base upload is sized for a small demo corpus (ConfigMap backed,
  well under 1 MiB total). For a larger corpus, upload documents through the Open WebUI UI
  after the stack is up instead.
