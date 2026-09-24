# Template only, do not kubectl apply this file directly and do not commit it with real values.
# scripts/deploy-cluster1.sh creates the real Secret imperatively from values you enter at deploy time.
apiVersion: v1
kind: Secret
metadata:
  name: webui-admin-credentials
  namespace: ai-demo
type: Opaque
stringData:
  WEBUI_ADMIN_EMAIL: REPLACE_ME
  WEBUI_ADMIN_PASSWORD: REPLACE_ME
