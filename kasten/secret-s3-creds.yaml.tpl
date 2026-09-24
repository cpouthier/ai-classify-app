# Template only, do not kubectl apply this file directly and do not commit it with real values.
# scripts/deploy-cluster1.sh (and its cluster2 counterpart) create the real Secret
# imperatively from values you enter at deploy time.
apiVersion: v1
kind: Secret
metadata:
  name: ai-demo-s3-creds
  namespace: kasten-io
type: Opaque
stringData:
  aws_access_key_id: REPLACE_ME
  aws_secret_access_key: REPLACE_ME
