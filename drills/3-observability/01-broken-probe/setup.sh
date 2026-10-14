#!/usr/bin/env bash
# Seeds a Deployment whose readiness probe targets a port nothing listens on.
# NS is exported by ckad start and by selftest.
set -euo pipefail

kubectl -n "$NS" apply -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: broken
spec:
  replicas: 2
  selector:
    matchLabels:
      app: broken
  template:
    metadata:
      labels:
        app: broken
    spec:
      containers:
        - name: broken
          image: nginx:1.27-alpine
          ports:
            - containerPort: 80
          readinessProbe:
            httpGet:
              path: /
              port: 8081
            periodSeconds: 5
EOF

kubectl -n "$NS" expose deployment broken --port=80 --name=broken >/dev/null
