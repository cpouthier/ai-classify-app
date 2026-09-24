# Knowledge base

Drop the demo's source documents here (Markdown, text, PDF, etc, whatever Open WebUI's
document loader accepts). The init Job uploads every file in this folder into the
`puls8-demo-kb` knowledge collection at startup.

This folder is packaged into the `ai-demo-init-script`/`ai-demo-kb-files` ConfigMap by
`scripts/deploy-cluster1.sh`, so keep the total size well under 1 MiB (the Kubernetes
ConfigMap size limit). For a larger corpus, upload documents directly through the Open
WebUI UI after the demo stack is up instead of via this folder.

`example-doc.md` is a placeholder, replace it with real Puls8 demo content.
