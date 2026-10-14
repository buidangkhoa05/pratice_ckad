# Three probes for a slow-starting app

**Target time:** 12 min
**Namespace:** `ckad-3-2`

Create a Deployment named `web`: 2 replicas, Pod label `app=web`, one
container named `web`, image `nginx:1.27-alpine`, overridden to take about 20
seconds before it serves anything:

    command: ["sh", "-c", "sleep 20; nginx -g 'daemon off;'"]

Give it all three probes, all `httpGet` on path `/` port `80`:

1. A `startupProbe` with `periodSeconds: 3` and `failureThreshold: 10`.
2. A `readinessProbe` with `periodSeconds: 5`.
3. A `livenessProbe` with `periodSeconds: 10`.

Both Pods must reach Ready.

The point: with a startupProbe, the liveness probe does not run until startup
succeeds, so a slow boot no longer gets the container killed. Try it without
the startupProbe and watch the restart count climb — that is the failure this
drill exists to make memorable.
