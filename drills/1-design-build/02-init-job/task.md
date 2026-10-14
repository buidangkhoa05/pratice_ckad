# Init container ordering, and a Job that quits

**Target time:** 12 min
**Namespace:** `ckad-1-2`

Two independent pieces.

**A.** Create a Pod named `web`:

1. An init container named `seed`, image `busybox:1.36`, that writes an
   `index.html` containing the word `seeded` into a shared volume.
2. A container named `web`, image `nginx:1.27-alpine`, serving that file from
   `/usr/share/nginx/html`.
3. A volume named `content` of type `emptyDir`, mounted in both.
4. The Pod must reach Ready, and
   `k exec web -- cat /usr/share/nginx/html/index.html` must print `seeded`.

**B.** Create a Job named `migrate` that is *expected to fail*:

1. One container, image `busybox:1.36`, running a command that exits non-zero.
2. `restartPolicy: Never`.
3. `backoffLimit: 2`.
4. Leave it alone until the Job reports exactly **3** failed Pods.

Part B is about knowing what `backoffLimit` counts. Predict the number of
Pods before you look.
