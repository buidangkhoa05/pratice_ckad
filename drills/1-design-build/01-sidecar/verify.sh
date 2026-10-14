#!/usr/bin/env bash
source "${CKAD_ROOT:-$(cd "$(dirname "$0")/../../.." && pwd)}/lib/assert.sh"
ns ckad-1-1

assert_exists pod/logger

# Container names, checked individually so manifest order does not matter.
assert_jsonpath pod/logger '{.spec.containers[?(@.name=="app")].name}' 'app'
assert_jsonpath pod/logger '{.spec.containers[?(@.name=="sidecar")].name}' 'sidecar'

# kubectl (v1.34) renders an empty JSON object as {} in jsonpath output, so
# that is what an `emptyDir: {}` volume compares against. Older kubectl
# printed Go's map[] here - check with `k get pod logger -o jsonpath=...`
# before assuming either.
assert_jsonpath pod/logger '{.spec.volumes[?(@.name=="logs")].emptyDir}' '{}'

assert_jsonpath pod/logger \
  '{.spec.containers[?(@.name=="app")].volumeMounts[?(@.name=="logs")].mountPath}' '/var/log'
assert_jsonpath pod/logger \
  '{.spec.containers[?(@.name=="sidecar")].volumeMounts[?(@.name=="logs")].mountPath}' '/var/log'

retry_until 90 assert_pod_ready --pod logger
retry_until 60 assert_logs --pod logger -c sidecar --contains 'app-heartbeat'

finish
