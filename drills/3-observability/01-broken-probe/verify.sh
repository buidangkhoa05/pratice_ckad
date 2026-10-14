#!/usr/bin/env bash
source "${CKAD_ROOT:-$(cd "$(dirname "$0")/../../.." && pwd)}/lib/assert.sh"
ns ckad-3-1

assert_exists deployment/broken
# The image must not have been swapped out to dodge the problem.
assert_jsonpath deployment/broken '{.spec.template.spec.containers[0].image}' 'nginx:1.27-alpine'
assert_jsonpath deployment/broken '{.spec.replicas}' '2'
assert_jsonpath deployment/broken \
  '{.spec.template.spec.containers[0].readinessProbe.httpGet.port}' '80'

retry_until 180 assert_pod_ready -l app=broken --count 2

# The symptom this drill is really about: a Service with no ready endpoints
# cannot route. readyReplicas is the order-independent way to assert it -
# comparing endpoint IPs positionally is flaky, since Pod ordering is not
# guaranteed.
assert_exists endpoints/broken
retry_until 60 assert_jsonpath deployment/broken '{.status.readyReplicas}' '2'

assert_exists configmap/diagnosis
assert_jsonpath configmap/diagnosis '{.data.cause}' 'readiness-probe-port'

finish
