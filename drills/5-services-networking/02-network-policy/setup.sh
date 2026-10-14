#!/usr/bin/env bash
# Seeds an api Deployment plus two differently-labelled clients, with no
# NetworkPolicy in place, so both clients can reach the api to begin with.
set -euo pipefail

kubectl -n "$NS" apply -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: api
spec:
  replicas: 1
  selector:
    matchLabels:
      app: api
  template:
    metadata:
      labels:
        app: api
    spec:
      containers:
        - name: api
          image: nginx:1.27-alpine
          ports:
            - containerPort: 80
---
apiVersion: v1
kind: Service
metadata:
  name: api
spec:
  selector:
    app: api
  ports:
    - port: 80
      targetPort: 80
---
apiVersion: v1
kind: Pod
metadata:
  name: client-allowed
  labels:
    role: frontend
spec:
  containers:
    - name: client
      image: busybox:1.36
      command: ["sleep", "3600"]
---
apiVersion: v1
kind: Pod
metadata:
  name: client-denied
  labels:
    role: batch
spec:
  containers:
    - name: client
      image: busybox:1.36
      command: ["sleep", "3600"]
EOF

kubectl -n "$NS" wait --for=condition=Ready pod/client-allowed pod/client-denied --timeout=120s >/dev/null
kubectl -n "$NS" rollout status deployment/api --timeout=120s >/dev/null
