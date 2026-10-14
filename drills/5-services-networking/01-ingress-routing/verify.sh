#!/usr/bin/env bash
source "${CKAD_ROOT:-$(cd "$(dirname "$0")/../../.." && pwd)}/lib/assert.sh"
ns ckad-5-1

CTRL='http://ingress-nginx-controller.ingress-nginx.svc.cluster.local'

for color in blue green; do
  assert_exists "deployment/$color"
  assert_exists "service/$color"
  assert_jsonpath "service/$color" '{.spec.type}'          'ClusterIP'
  assert_jsonpath "service/$color" '{.spec.ports[0].port}' '80'
  retry_until 150 assert_pod_ready -l "app=$color" --count 1
done

# Services reachable on their own, before involving the Ingress.
retry_until 60 assert_http http://blue  --status 200
retry_until 60 assert_http http://green --status 200

assert_exists ingress/routes
assert_jsonpath ingress/routes '{.spec.ingressClassName}' 'nginx'
assert_jsonpath ingress/routes \
  '{.spec.rules[0].http.paths[?(@.path=="/blue")].backend.service.name}'  'blue'
assert_jsonpath ingress/routes \
  '{.spec.rules[0].http.paths[?(@.path=="/green")].backend.service.name}' 'green'
assert_jsonpath ingress/routes \
  '{.spec.rules[0].http.paths[?(@.path=="/blue")].pathType}' 'Prefix'

# The assertions that actually prove routing works end to end.
retry_until 120 assert_http "$CTRL/blue"  --status 200
retry_until 120 assert_http "$CTRL/green" --status 200

finish
