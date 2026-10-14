# Diagnose a readiness probe that never passes

**Target time:** 10 min
**Namespace:** `ckad-3-1`

A Deployment named `broken` has been deployed for you. Its Pods are Running
but never Ready, so the Service in front of it has no endpoints.

1. Find out why. Do not change the image, the replica count, or the
   container port the app actually listens on.
2. Fix it so both Pods reach Ready.
3. Record what was wrong: create a ConfigMap named `diagnosis` with a key
   `cause` whose value is exactly `readiness-probe-port`.

Start with `k describe pod` and read the Events, then compare what the probe
asks for against what the container exposes. `k get events --sort-by=.lastTimestamp`
is worth the muscle memory.
