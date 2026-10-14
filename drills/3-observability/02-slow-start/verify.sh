#!/usr/bin/env bash
source "${CKAD_ROOT:-$(cd "$(dirname "$0")/../../.." && pwd)}/lib/assert.sh"
ns ckad-3-2

C='{.spec.template.spec.containers[0]}'

assert_exists deployment/web
assert_jsonpath deployment/web '{.spec.replicas}' '2'

assert_jsonpath deployment/web "$C.startupProbe.httpGet.path"      '/'
assert_jsonpath deployment/web "$C.startupProbe.httpGet.port"      '80'
assert_jsonpath deployment/web "$C.startupProbe.periodSeconds"     '3'
assert_jsonpath deployment/web "$C.startupProbe.failureThreshold"  '10'

assert_jsonpath deployment/web "$C.readinessProbe.httpGet.port"    '80'
assert_jsonpath deployment/web "$C.readinessProbe.periodSeconds"   '5'

assert_jsonpath deployment/web "$C.livenessProbe.httpGet.port"     '80'
assert_jsonpath deployment/web "$C.livenessProbe.periodSeconds"    '10'

retry_until 180 assert_pod_ready -l app=web --count 2

# Ready is not enough on its own - the Deployment must report both replicas
# ready, which fails if the liveness probe killed a container during startup.
assert_jsonpath deployment/web '{.status.readyReplicas}' '2'

finish
