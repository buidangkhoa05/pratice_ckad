# ConfigMap volume and Secret env vars

**Target time:** 12 min
**Namespace:** `ckad-4-1`

Both ways of injecting configuration, in one Pod.

1. A ConfigMap named `app-config` with one key `app.properties` whose content
   includes the line `mode=production`.
2. A Secret named `app-secret` with keys `DB_USER=appuser` and
   `DB_PASS=s3cr3t`.
3. A Deployment named `cfg`, 1 replica, Pod label `app=cfg`, one container
   named `cfg`, image `busybox:1.36`, command `sleep 3600`, where:
   - `app-config` is mounted as a volume named `config` at `/etc/app`, so
     `/etc/app/app.properties` exists inside the container;
   - every key of `app-secret` arrives as an environment variable, injected
     with `envFrom` rather than listed one at a time.

Check your work from inside the container:
`k exec deploy/cfg -- cat /etc/app/app.properties` and
`k exec deploy/cfg -- printenv DB_PASS`.

Generate the Secret with `k create secret generic` — writing base64 by hand
is a waste of exam time and an easy place to typo.
