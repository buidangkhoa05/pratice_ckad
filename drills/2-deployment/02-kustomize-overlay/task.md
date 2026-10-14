# A kustomize overlay for production

**Target time:** 12 min
**Namespace:** `ckad-2-2`

Build a kustomize base and one overlay. No Helm, and no standalone
`kustomize` binary — `kubectl apply -k` has it built in.

**Base** (`base/`): a Deployment named `site`, 1 replica, container `site`,
image `nginx:1.27-alpine`, Pod label `app=site`.

**Overlay** (`overlays/prod/`) referencing that base and changing only:

1. replicas to 3
2. image to `nginx:1.28-alpine`
3. a label `env=prod` applied to the Deployment *and* its Pods

Apply the overlay with `k apply -k overlays/prod`. The base must remain
deployable on its own — if your base only works through the overlay, the
split is wrong.

End state: Deployment `site` with 3 Ready Pods on `nginx:1.28-alpine`,
carrying `env=prod`.
