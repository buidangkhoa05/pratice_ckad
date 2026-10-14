#!/usr/bin/env bash
source "${CKAD_ROOT:-$(cd "$(dirname "$0")/../../.." && pwd)}/lib/assert.sh"
ns ckad-4-1

T='{.spec.template.spec}'

assert_exists configmap/app-config
assert_exists secret/app-secret
# Secret values are base64 in the API; s3cr3t encodes to czNjcjN0.
assert_jsonpath secret/app-secret '{.data.DB_PASS}' 'czNjcjN0'
assert_jsonpath secret/app-secret '{.data.DB_USER}' 'YXBwdXNlcg=='

assert_exists deployment/cfg
assert_jsonpath deployment/cfg "$T.volumes[?(@.name==\"config\")].configMap.name" 'app-config'
assert_jsonpath deployment/cfg \
  "$T.containers[0].volumeMounts[?(@.name==\"config\")].mountPath" '/etc/app'
# envFrom, not a hand-listed env block.
assert_jsonpath deployment/cfg "$T.containers[0].envFrom[0].secretRef.name" 'app-secret'

retry_until 120 assert_pod_ready -l app=cfg --count 1

# The checks that matter: the file and the variable as the process sees them.
assert_exec -l app=cfg --contains 'mode=production' -- cat /etc/app/app.properties
assert_exec -l app=cfg --contains 's3cr3t'          -- printenv DB_PASS
assert_exec -l app=cfg --contains 'appuser'         -- printenv DB_USER

finish
