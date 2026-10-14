# Sidecar sharing an emptyDir

**Target time:** 8 min
**Namespace:** `ckad-1-1`

A legacy app writes its log to a file instead of stdout, so `kubectl logs`
shows nothing. Fix that with a sidecar, without modifying the app's image.

Create a Pod named `logger` with:

1. A container named `app`, image `busybox:1.36`, that appends a line
   containing `app-heartbeat` to `/var/log/app.log` every 2 seconds, forever.
2. A container named `sidecar`, image `busybox:1.36`, that streams that same
   file to stdout so `kubectl logs logger -c sidecar` shows the lines.
3. A volume named `logs` of type `emptyDir`, mounted at `/var/log` in **both**
   containers.
4. The Pod must reach Ready.

Hints: `k run logger --image=busybox:1.36 $do -- sh -c 'sleep 1' > pod.yaml`
gives you a skeleton to edit. The sidecar must tolerate the file not existing
yet — `tail -f` on a missing file exits immediately.
