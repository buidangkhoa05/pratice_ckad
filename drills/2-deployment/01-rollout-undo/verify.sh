#!/usr/bin/env bash
source "${CKAD_ROOT:-$(cd "$(dirname "$0")/../../.." && pwd)}/lib/assert.sh"
ns ckad-2-1

assert_exists deployment/api
assert_jsonpath deployment/api '{.spec.replicas}' '4'
assert_jsonpath deployment/api '{.spec.strategy.type}' 'RollingUpdate'
assert_jsonpath deployment/api '{.spec.strategy.rollingUpdate.maxSurge}' '1'
assert_jsonpath deployment/api '{.spec.strategy.rollingUpdate.maxUnavailable}' '0'

# Back on the original image...
assert_jsonpath deployment/api '{.spec.template.spec.containers[0].image}' 'nginx:1.27-alpine'
# ...but via a third revision, which is what proves a rollback rather than an
# edit. Dots inside the annotation key must be escaped in jsonpath.
assert_jsonpath deployment/api \
  '{.metadata.annotations.deployment\.kubernetes\.io/revision}' '3'

retry_until 180 assert_pod_ready -l app=api --count 4

finish
