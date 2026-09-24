# Template only, do not kubectl apply this file directly and do not commit it with real values.
# scripts/deploy-cluster1.sh creates the real Secret imperatively from values you enter at deploy time.
# Kept here so the expected keys are documented and the Blueprint in kasten/blueprint-postgres.yaml
# and the classify-app Deployment can reference them.
apiVersion: v1
kind: Secret
metadata:
  name: postgres-credentials
  namespace: ai-demo
type: Opaque
stringData:
  POSTGRES_USER: REPLACE_ME
  POSTGRES_PASSWORD: REPLACE_ME
  POSTGRES_DB: classify
