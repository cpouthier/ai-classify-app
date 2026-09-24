# Template only, do not kubectl apply this file directly and do not commit it with real values.
# scripts/deploy-cluster1.sh creates the real Secret imperatively, building the URLs from the
# same postgres-credentials values you enter at deploy time.
apiVersion: v1
kind: Secret
metadata:
  name: webui-db-credentials
  namespace: ai-demo
type: Opaque
stringData:
  DATABASE_URL: postgresql://REPLACE_ME_USER:REPLACE_ME_PASSWORD@postgres.ai-demo.svc.cluster.local:5432/ai_demo
  PGVECTOR_DB_URL: postgresql://REPLACE_ME_USER:REPLACE_ME_PASSWORD@postgres.ai-demo.svc.cluster.local:5432/ai_demo
