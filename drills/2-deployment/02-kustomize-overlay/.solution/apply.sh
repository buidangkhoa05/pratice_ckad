#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
kubectl -n "$NS" apply -k "$HERE/overlays/prod"
kubectl -n "$NS" rollout status deployment/site --timeout=180s
