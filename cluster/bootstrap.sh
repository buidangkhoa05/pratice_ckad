#!/usr/bin/env bash
# Creates the ckad practice cluster. Idempotent: re-running is a no-op unless
# --recreate is passed.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLUSTER=ckad
RECREATE=0
[[ "${1:-}" == "--recreate" ]] && RECREATE=1

die() { printf '\nbootstrap: %s\n' "$1" >&2; exit 1; }
step() { printf '\n==> %s\n' "$1"; }

# --- preflight: every failure names its own fix -----------------------------
step "preflight"
command -v kubectl >/dev/null || die "kubectl not found on PATH"
command -v kind    >/dev/null || die "kind not found - run: winget install Kubernetes.kind"
docker info >/dev/null 2>&1 \
  || die "cannot reach the Docker daemon - start Docker Desktop and wait for it to say Running"

mem_bytes="$(docker info --format '{{.MemTotal}}' 2>/dev/null || echo 0)"
if (( mem_bytes > 0 && mem_bytes < 4000000000 )); then
  printf 'warning: Docker reports %s GiB of memory. Three nodes plus Calico\n' \
    "$(( mem_bytes / 1073741824 ))"
  printf '         needs about 4 GiB; raise it in Docker Desktop > Settings > Resources.\n'
fi
printf 'ok\n'

# --- cluster ----------------------------------------------------------------
if kind get clusters 2>/dev/null | grep -qx "$CLUSTER"; then
  if (( RECREATE )); then
    step "deleting existing cluster"
    kind delete cluster --name "$CLUSTER"
  else
    printf '\ncluster %s already exists. Use --recreate to rebuild it.\n' "$CLUSTER"
    kubectl config use-context "kind-$CLUSTER" >/dev/null
    exit 0
  fi
fi

step "creating cluster (1 control-plane, 2 workers)"
kind create cluster --name "$CLUSTER" --config "$HERE/kind-config.yaml" \
  || die "kind create failed - see the output above"

# --- CNI --------------------------------------------------------------------
step "installing Calico (NetworkPolicy enforcement)"
kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.28.2/manifests/calico.yaml \
  || die "Calico apply failed - check internet access"
kubectl -n kube-system rollout status daemonset/calico-node --timeout=300s \
  || die "Calico did not become ready"
kubectl wait --for=condition=Ready nodes --all --timeout=180s \
  || die "nodes did not become Ready after Calico"

# --- ingress ----------------------------------------------------------------
step "installing ingress-nginx"
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.11.3/deploy/static/provider/kind/deploy.yaml \
  || die "ingress-nginx apply failed"
# Waiting on the admission webhook is not optional: without it the first
# Ingress you apply is rejected for reasons unrelated to your YAML.
kubectl -n ingress-nginx wait --for=condition=Ready pod \
  -l app.kubernetes.io/component=controller --timeout=300s \
  || die "ingress-nginx controller did not become ready"

# --- metrics ----------------------------------------------------------------
step "installing metrics-server"
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/download/v0.7.2/components.yaml \
  || die "metrics-server apply failed"
# kind's kubelet serving certs are self-signed, so metrics-server must be told
# to skip verification or `kubectl top` and every HPA drill silently report
# nothing forever.
kubectl -n kube-system patch deployment metrics-server --type=json \
  -p '[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]' \
  || die "could not patch metrics-server"
kubectl -n kube-system rollout status deployment/metrics-server --timeout=180s \
  || die "metrics-server did not become ready"

step "done"
kubectl get nodes -o wide
cat <<'EOF'

next:
  source bin/setup-shell.sh    # aliases and $do/$now
  ckad list                    # pick a drill
EOF
