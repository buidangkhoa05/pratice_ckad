# Run as non-root, and say what you need

**Target time:** 12 min
**Namespace:** `ckad-4-2`

Create a Deployment named `secure`, 1 replica, Pod label `app=secure`, one
container named `secure`, that satisfies a hardened-cluster policy:

1. Pod-level `securityContext`: `runAsNonRoot: true`, `runAsUser: 101`.
2. Container-level `securityContext`: `allowPrivilegeEscalation: false`, and
   all capabilities dropped (`drop: ["ALL"]`).
3. Resource `requests` of `cpu: 100m` / `memory: 64Mi` and `limits` of
   `cpu: 200m` / `memory: 128Mi`.
4. The Pod must reach Ready.

Start from `nginx:1.27-alpine` and watch it fail: that image's entrypoint
binds port 80, which is privileged, and writes to paths only root can write.
Part of this task is recognising that the fix is a different image, not a
looser policy — use `nginxinc/nginx-unprivileged:1.27-alpine`, which listens
on 8080 as uid 101.

That substitution is the real lesson. "Make it run as non-root" usually means
"get an image built to run as non-root", not "add a securityContext and hope".
