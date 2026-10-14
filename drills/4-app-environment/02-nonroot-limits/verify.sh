#!/usr/bin/env bash
source "${CKAD_ROOT:-$(cd "$(dirname "$0")/../../.." && pwd)}/lib/assert.sh"
ns ckad-4-2

T='{.spec.template.spec}'

assert_exists deployment/secure
assert_jsonpath deployment/secure "$T.securityContext.runAsNonRoot" 'true'
assert_jsonpath deployment/secure "$T.securityContext.runAsUser"    '101'

assert_jsonpath deployment/secure \
  "$T.containers[0].securityContext.allowPrivilegeEscalation" 'false'
assert_jsonpath deployment/secure \
  "$T.containers[0].securityContext.capabilities.drop[0]" 'ALL'

assert_jsonpath deployment/secure "$T.containers[0].resources.requests.cpu"    '100m'
assert_jsonpath deployment/secure "$T.containers[0].resources.requests.memory" '64Mi'
assert_jsonpath deployment/secure "$T.containers[0].resources.limits.cpu"      '200m'
assert_jsonpath deployment/secure "$T.containers[0].resources.limits.memory"   '128Mi'

retry_until 150 assert_pod_ready -l app=secure --count 1

# Ready is not enough on its own - prove the process is not root.
# Note what is NOT asserted: the image name. Any non-root-capable image that
# meets every requirement should pass; pinning it would grade the answer
# instead of the outcome.
assert_exec -l app=secure --contains '101' -- id -u

finish
