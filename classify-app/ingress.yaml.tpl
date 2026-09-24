# Template only, the deploy script fills in ingressClassName/host and applies this, do not
# apply this file directly.
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: classify-app
  namespace: ai-demo
spec:
  ingressClassName: REPLACE_ME_CLASS
  rules:
    - host: REPLACE_ME_HOST
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: classify-app
                port:
                  number: 80
