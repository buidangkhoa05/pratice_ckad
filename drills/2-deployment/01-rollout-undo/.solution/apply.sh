#!/usr/bin/env bash
# The end state of this drill is a rollback, which only exists after a
# sequence of commands. NS is exported by selftest and by ckad.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"

kubectl -n "$NS" apply -f "$HERE/deployment.yaml"
kubectl -n "$NS" rollout status deployment/api --timeout=180s   # revision 1

kubectl -n "$NS" set image deployment/api api=nginx:1.28-alpine
kubectl -n "$NS" annotate deployment/api \
  kubernetes.io/change-cause="upgrade to nginx 1.28" --overwrite
kubectl -n "$NS" rollout status deployment/api --timeout=180s   # revision 2

kubectl -n "$NS" rollout undo deployment/api --to-revision=1
kubectl -n "$NS" rollout status deployment/api --timeout=180s   # revision 3
