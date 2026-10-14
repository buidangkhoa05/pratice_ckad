# Path-based Ingress in front of two Services

**Target time:** 14 min
**Namespace:** `ckad-5-1`

1. Two Deployments, `blue` and `green`: 1 replica each, image
   `nginx:1.27-alpine`, Pod labels `app=blue` and `app=green`.
2. A ClusterIP Service for each, named `blue` and `green`, port 80 to
   container port 80.
3. An Ingress named `routes`, ingress class `nginx`, with no host, routing:
   - `/blue`  (pathType `Prefix`) to Service `blue` port 80
   - `/green` (pathType `Prefix`) to Service `green` port 80

Both paths must return HTTP 200 through the ingress controller.

The trap: nginx has no `/blue` directory, so a naive Ingress gives you a 404
from the backend rather than from the controller. You need the
`nginx.ingress.kubernetes.io/rewrite-target: /` annotation so the path is
stripped before the request reaches the Service. Diagnosing 404-from-backend
versus 404-from-controller is the skill here.

Check a Service directly without leaving the cluster:
`k run tmp --rm -it --image=curlimages/curl:8.10.1 --restart=Never -- curl -s http://blue`
