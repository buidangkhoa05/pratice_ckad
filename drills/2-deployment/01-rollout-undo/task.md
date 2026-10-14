# Rollout, then undo it

**Target time:** 10 min
**Namespace:** `ckad-2-1`

Create a Deployment named `api`:

1. 4 replicas, label `app=api` on the Pods, one container named `api`,
   image `nginx:1.27-alpine`.
2. A `RollingUpdate` strategy with `maxSurge: 1` and `maxUnavailable: 0`
   — the Service must never lose capacity during an update.
3. Roll it out, then update the image to `nginx:1.28-alpine` and record the
   reason in the `kubernetes.io/change-cause` annotation.
4. Then roll back to the original image using revision 1.
5. End state: 4 Ready Pods on `nginx:1.27-alpine`, and the Deployment is on
   revision **3**.

Why 3: creating, updating, and undoing each produce a revision. `k rollout
history deploy/api` shows them. Do not reach 1.27 by editing the image back
by hand — use `rollout undo`, and note that it creates a new revision rather
than deleting one.
